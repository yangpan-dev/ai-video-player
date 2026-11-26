import { spawn } from 'node:child_process'
import type { StreamProgress, SubtitleSegment } from '@shared/types'
import { resolveFfmpeg } from './ffmpeg'
import { ensureVadModel, modelExists, whisperModelFile } from './models'
import { WhisperServer } from './whisperServer'
import {
  createCheckpoint,
  discardCheckpoint,
  readCheckpoint,
  writeCheckpoint,
  type TranscribeCheckpoint
} from './checkpoint'

/** 窗口时长（秒）：每窗口送给 whisper-server，由其内置 Silero VAD 做精确分段 */
const WINDOW_SEC = 15
/** 步进（秒）：窗口间保留 3 秒重叠，跨窗口句子在下一窗口完整识别 */
const STRIDE_SEC = 12
/** 每识别几个窗口落一次断点（约 48 秒音频） */
const SAVE_EVERY_WINDOWS = 4

export interface StreamingCallbacks {
  onSegment: (segment: SubtitleSegment) => void
  onProgress: (p: StreamProgress) => void
  onLog: (line: string) => void
}

let activeCancel: (() => void) | undefined
/** 立即把当前进度写到断点（退出应用前调用，保证不丢） */
let activeFlush: (() => void) | undefined

export function cancelStreaming(): void {
  activeCancel?.()
}

/**
 * 同步落盘当前识别进度。应用退出时主进程可能来不及等异步清理，
 * 这里提供一个同步入口，避免「关掉应用后进度白做」。
 */
export function flushStreamingCheckpoint(): void {
  activeFlush?.()
}

/** s16le 字节 -> Float32（-1..1），处理可能的字节对齐问题 */
function s16ToFloat32(chunk: Buffer): Float32Array {
  const n = Math.floor(chunk.length / 2)
  const copy = Buffer.allocUnsafe(n * 2)
  chunk.copy(copy, 0, 0, n * 2)
  const int16 = new Int16Array(copy.buffer, copy.byteOffset, n)
  const f32 = new Float32Array(n)
  for (let i = 0; i < n; i++) f32[i] = int16[i] / 32768
  return f32
}

/** Float32 采样 -> 16-bit PCM WAV buffer（whisper-server 输入） */
function float32ToWav(samples: Float32Array, sampleRate = 16000): Buffer {
  const data = Buffer.alloc(samples.length * 2)
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]))
    data.writeInt16LE(s < 0 ? s * 0x8000 : s * 0x7fff, i * 2)
  }
  const header = Buffer.alloc(44)
  header.write('RIFF', 0)
  header.writeUInt32LE(36 + data.length, 4)
  header.write('WAVE', 8)
  header.write('fmt ', 12)
  header.writeUInt32LE(16, 16)
  header.writeUInt16LE(1, 20)
  header.writeUInt16LE(1, 22)
  header.writeUInt32LE(sampleRate, 24)
  header.writeUInt32LE(sampleRate * 2, 28)
  header.writeUInt16LE(2, 32)
  header.writeUInt16LE(16, 34)
  header.write('data', 36)
  header.writeUInt32LE(data.length, 40)
  return Buffer.concat([header, data])
}

/**
 * 流式识别：ffmpeg 持续解码音频 → 固定窗口 → whisper-server 内置 Silero VAD 精确分段。
 * Silero VAD 能区分人声与背景音乐，显著优于纯能量 VAD，减少漏识别。
 *
 * 每若干个窗口把已识别结果写入断点；下次带 resume 启动时先回放已有段落，
 * 再让 ffmpeg 从断点位置续流，避免整段重跑。
 */
export async function startStreaming(
  videoPath: string,
  options: { model: string; language: string; resume?: boolean },
  cb: StreamingCallbacks
): Promise<{ detectedLanguage: string; segmentCount: number }> {
  cancelStreaming()
  let cancelled = false
  const modelName = options.model ?? 'large-v3-turbo'
  if (!modelExists(modelName)) {
    throw new Error(`模型 ggml-${modelName}.bin 尚未下载。请先在界面点击「下载模型」。`)
  }
  const modelPath = whisperModelFile(modelName)
  const language = options.language === 'auto' ? 'auto' : options.language

  // 续做：读取上次的断点；非续做或有断点但要求重来则丢弃
  const resumed = options.resume ? readCheckpoint(videoPath) : null
  if (!resumed) discardCheckpoint(videoPath)

  const segments: SubtitleSegment[] = resumed ? [...resumed.segments] : []
  const resumeSec = resumed?.processedSec ?? 0
  let detectedLanguage = resumed?.detectedLanguage ?? ''
  let durationSec = resumed?.durationSec ?? 0
  let windowStartSample = Math.round(resumeSec * 16000)
  let completed = false

  let cp: TranscribeCheckpoint | null = resumed
  const checkpointRecord = (): TranscribeCheckpoint =>
    (cp ??= createCheckpoint(videoPath, {
      model: modelName,
      language,
      durationSec
    }))
  const saveCheckpoint = (): void => {
    if (!segments.length && windowStartSample === 0) return
    try {
      const record = checkpointRecord()
      record.segments = segments
      record.processedSec = windowStartSample / 16000
      if (durationSec > 0) record.durationSec = durationSec
      if (detectedLanguage) record.detectedLanguage = detectedLanguage
      writeCheckpoint(record)
    } catch {
      /* 源文件被删除等情况：断点写不进去就算了 */
    }
  }

  const server = new WhisperServer()
  let ffmpegProc: ReturnType<typeof spawn> | null = null
  const cancel = (): void => {
    cancelled = true
    ffmpegProc?.kill()
    server.stop()
  }
  activeCancel = cancel
  activeFlush = saveCheckpoint

  let lastPercent = 0

  const emitProgress = (percent: number, message = '实时识别中'): void => {
    lastPercent = percent
    cb.onProgress({
      status: 'listening',
      message,
      percent,
      segmentCount: segments.length,
      detectedLanguage: detectedLanguage || undefined
    })
  }

  try {
    // 续做时先把上次的段落回放给界面，列表不会从空开始
    if (segments.length) {
      for (const s of segments) cb.onSegment(s)
      const pct = durationSec > 0 ? Math.round((resumeSec / durationSec) * 100) : 0
      emitProgress(Math.min(99, pct), `已载入上次进度（${segments.length} 句），继续识别`)
    }

    // 1. 确保 Silero VAD 模型（~864KB）
    cb.onProgress({ status: 'starting', message: '准备 VAD 模型', percent: lastPercent })
    const vadModel = await ensureVadModel()
    if (cancelled) throw new Error('已取消')

    // 2. 启动 whisper-server（带 Silero VAD）
    cb.onProgress({ status: 'starting', message: '正在加载语音模型', percent: lastPercent })
    await server.start(modelPath, {
      vad: true,
      vadModel,
      onLog: (l) => cb.onLog(l)
    })
    if (cancelled) throw new Error('已取消')

    // 3. 启动 ffmpeg PCM 流（续做时从断点位置开始解码）
    emitProgress(lastPercent)
    const ffmpegArgs = ['-hide_banner']
    if (resumeSec > 0.05) ffmpegArgs.push('-ss', resumeSec.toFixed(3))
    ffmpegArgs.push('-i', videoPath, '-vn', '-ac', '1', '-ar', '16000', '-f', 's16le', 'pipe:1')
    ffmpegProc = spawn(resolveFfmpeg(), ffmpegArgs)

    ffmpegProc.stderr?.on('data', (d: Buffer) => {
      const text = d.toString()
      cb.onLog(text)
      const dm = /Duration:\s*(\d+):(\d+):(\d+\.?\d*)/.exec(text)
      if (dm && durationSec === 0) {
        durationSec = +dm[1] * 3600 + +dm[2] * 60 + +dm[3]
      }
      const tm = /time=\s*(\d+):(\d+):(\d+\.?\d*)/.exec(text)
      if (tm && durationSec > 0) {
        const cur = +tm[1] * 3600 + +tm[2] * 60 + +tm[3]
        // -ss 之前 ffmpeg 的 time 从 0 开始，个别版本则沿用原始时间轴，这里都兼容
        const absCur = resumeSec > 1 && cur + 1 < resumeSec ? cur + resumeSec : cur
        emitProgress(Math.min(99, Math.round((absCur / durationSec) * 100)))
      }
    })

    let ffmpegError = ''
    ffmpegProc.on('error', (err) => {
      ffmpegError = err.message
    })

    // 4. 固定窗口 + Silero VAD
    let windowBuffer = new Float32Array(0)
    let windowsSinceSave = 0

    const transcribeWindow = async (samples: Float32Array, startSample: number): Promise<void> => {
      const wav = float32ToWav(samples)
      let result
      try {
        result = await server.transcribe(wav, language)
      } catch (err) {
        // 取消时 whisper-server 会被直接杀掉，正在进行的请求会以 fetch failed 结束，
        // 这里统一转成「已取消」，避免界面把它当成真错误弹出来
        if (cancelled) throw new Error('已取消')
        throw err
      }
      if (cancelled) throw new Error('已取消')
      if (result.language && !detectedLanguage) {
        detectedLanguage = result.language
        emitProgress(lastPercent)
      }
      const baseSec = startSample / 16000
      for (const s of result.segments) {
        if (!s.text) continue
        const absEnd = baseSec + s.end
        // 只跳过窗口最末尾（可能被截断）的片段，交给下一窗口完整识别
        if (absEnd > baseSec + WINDOW_SEC - 0.5) continue
        const segment: SubtitleSegment = {
          index: segments.length,
          start: baseSec + s.start,
          end: absEnd,
          text: s.text
        }
        segments.push(segment)
        cb.onSegment(segment)
      }
    }

    if (ffmpegProc.stdout) {
      const windowSamples = WINDOW_SEC * 16000
      const strideSamples = STRIDE_SEC * 16000
      for await (const chunk of ffmpegProc.stdout) {
        if (cancelled) break
        const f32 = s16ToFloat32(chunk as Buffer)

        const merged = new Float32Array(windowBuffer.length + f32.length)
        merged.set(windowBuffer, 0)
        merged.set(f32, windowBuffer.length)
        windowBuffer = merged

        while (!cancelled && windowBuffer.length >= windowSamples) {
          const window = windowBuffer.subarray(0, windowSamples)
          await transcribeWindow(window, windowStartSample)
          windowBuffer = windowBuffer.subarray(strideSamples)
          windowStartSample += strideSamples
          // 定期落盘：即使应用被强制关闭，也只会丢失最近几十秒
          if (++windowsSinceSave >= SAVE_EVERY_WINDOWS) {
            windowsSinceSave = 0
            saveCheckpoint()
          }
        }
      }
    }

    // 5. 处理最后一个不满窗口的片段
    if (!cancelled && windowBuffer.length > 0) {
      await transcribeWindow(windowBuffer, windowStartSample)
      windowStartSample += windowBuffer.length
    }

    if (ffmpegError && !cancelled) {
      throw new Error(`ffmpeg 音频流错误：${ffmpegError}`)
    }
    if (cancelled) throw new Error('已取消')

    // 识别完成：断点不再需要
    completed = true
    discardCheckpoint(videoPath)
    cb.onProgress({
      status: 'done',
      message: '识别完成',
      percent: 100,
      segmentCount: segments.length,
      detectedLanguage
    })
    return { detectedLanguage, segmentCount: segments.length }
  } finally {
    // 取消/异常退出：把当前进度存下来，下次可以继续
    if (!completed) saveCheckpoint()
    if (activeCancel === cancel) activeCancel = undefined
    if (activeFlush === saveCheckpoint) activeFlush = undefined
    ffmpegProc?.kill()
    server.stop()
  }
}
