import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { rm } from 'node:fs/promises'
import type { PipelineProgress, RunPipelineOptions, SubtitleSegment, TranscribeResult } from '@shared/types'
import { cutAudio, detectSilences, extractAudio, probeVideo } from './ffmpeg'
import { transcribe } from './whisper'
import { modelExists, whisperModelFile } from './models'
import { getTempDir } from './paths'
import {
  createCheckpoint,
  discardCheckpoint,
  readCheckpoint,
  writeCheckpoint,
  type TranscribeCheckpoint
} from './checkpoint'

let active: AbortController | undefined

export function cancelPipeline(): void {
  active?.abort()
}

/** 解析 ffmpeg stderr 里的 `time=HH:MM:SS` 与 `Duration:` 用于估算进度 */
function createFfmpegProgress(onProgress: (p: PipelineProgress) => void) {
  let durationSec = 0
  return (data: string): void => {
    const dm = /Duration:\s*(\d+):(\d+):(\d+\.?\d*)/.exec(data)
    if (dm && durationSec === 0) {
      durationSec = +dm[1] * 3600 + +dm[2] * 60 + +dm[3]
    }
    const tm = /time=\s*(\d+):(\d+):(\d+\.?\d*)/.exec(data)
    if (tm && durationSec > 0) {
      const cur = +tm[1] * 3600 + +tm[2] * 60 + +tm[3]
      onProgress({
        stage: 'extract',
        message: '抽取音频中',
        percent: Math.min(100, Math.round((cur / durationSec) * 100))
      })
    }
  }
}

/** 目标分片时长：短文件不分片（省掉重复加载模型的开销），长文件约切 15 段 */
function targetChunkSec(durationSec: number): number {
  if (durationSec <= 240) return durationSec
  return Math.max(180, Math.min(480, Math.round(durationSec / 15)))
}

function fmtSec(sec: number): string {
  const s = Math.max(0, Math.round(sec))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const ss = s % 60
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(ss).padStart(2, '0')}`
  return `${m}:${String(ss).padStart(2, '0')}`
}

/**
 * 计算分片边界：在目标位置附近找一段静音，把切点放进去。
 * 切在句子中间会让 whisper 在截断处重复上一句或编造内容，切在静音处则没有这个问题。
 */
async function buildBoundaries(
  wavPath: string,
  durationSec: number,
  target: number,
  signal: AbortSignal,
  onProgress: (p: PipelineProgress) => void
): Promise<number[]> {
  if (durationSec <= 240 || target >= durationSec - 5) return [0, durationSec]

  onProgress({ stage: 'transcribe', message: '正在分析语音停顿（用于分段）', percent: 0 })
  const silences = await detectSilences(wavPath, signal)
  if (signal.aborted) throw new Error('已取消')

  const picks: number[] = [0]
  const tolerance = Math.max(15, target * 0.3)

  for (let t = target; t < durationSec - 5; t += target) {
    let best: number | null = null
    let bestDist = Number.POSITIVE_INFINITY
    for (const s of silences) {
      if (s.start > t + tolerance) break
      const end = Math.min(s.end, durationSec)
      if (end <= s.start) continue
      const mid = (s.start + end) / 2
      const dist = Math.abs(mid - t)
      if (dist <= tolerance && dist < bestDist && mid > picks[picks.length - 1] + 20) {
        best = mid
        bestDist = dist
      }
    }
    const boundary = best ?? t
    if (boundary > picks[picks.length - 1] + 20) picks.push(boundary)
  }

  picks.push(durationSec)
  return picks
}

/**
 * 主进程流水线：抽取音频 -> 按句子间隙分片 -> whisper.cpp 逐片识别（带断点）-> 合并。
 * 翻译由渲染进程调用本地 Qwen 服务完成。
 *
 * 分片 + 断点的意义：每识别完一片就把结果写进断点文件。用户中途关闭应用，
 * 下次对同一文件可以从断点继续，而不是从头再跑一遍。
 */
export async function runPipeline(
  videoPath: string,
  options: RunPipelineOptions,
  onProgress: (p: PipelineProgress) => void
): Promise<TranscribeResult> {
  cancelPipeline()
  const controller = new AbortController()
  const modelName = options.model ?? 'small'

  if (!modelExists(modelName)) {
    throw new Error(
      `模型 ggml-${modelName}.bin 尚未下载。请先在界面中点击「下载模型」，或运行 pnpm run download:model。`
    )
  }
  const modelPath = whisperModelFile(modelName)

  const wavPath = join(getTempDir(), `audio-${randomUUID()}.wav`)
  active = controller
  // 非续做模式：丢弃旧断点，避免和本次结果混在一起
  if (!options.resume) discardCheckpoint(videoPath)

  try {
    onProgress({ stage: 'extract', message: '正在抽取音频', percent: 0 })
    const ffmpegProgress = createFfmpegProgress(onProgress)
    await extractAudio(videoPath, wavPath, ({ data }) => ffmpegProgress(data), controller.signal)
    if (controller.signal.aborted) throw new Error('已取消')

    // 读取音频时长，用于分片与进度百分比（失败则整段识别）
    let durationSec = 0
    try {
      durationSec = (await probeVideo(videoPath, controller.signal)).duration
    } catch {
      /* 探测失败时退化处理 */
    }
    if (controller.signal.aborted) throw new Error('已取消')

    if (durationSec <= 0.5) {
      onProgress({ stage: 'transcribe', message: '正在识别语音（Whisper）', percent: 0 })
      const single = await transcribe(wavPath, modelPath, {
        signal: controller.signal,
        language: options.language === 'auto' ? 'auto' : options.language,
        onProgress: (percent) =>
          onProgress({ stage: 'transcribe', message: '正在识别语音（Whisper）', percent })
      })
      if (controller.signal.aborted) throw new Error('已取消')
      onProgress({ stage: 'done', message: '识别完成', percent: 100, detectedLanguage: single.detectedLanguage })
      return { segments: single.segments, detectedLanguage: single.detectedLanguage }
    }

    // 续做：复用上次的分片边界，保证切点与已完成部分完全对齐
    // （流式模式留下的断点没有分片边界，批量模式无法直接沿用，只能重来）
    const resumed = options.resume ? readCheckpoint(videoPath) : null
    const reusable = resumed && Math.abs(resumed.durationSec - durationSec) <= 2 && resumed.boundaries?.length
      ? resumed
      : null
    const boundaries = reusable?.boundaries && reusable.boundaries.length >= 2
      ? reusable.boundaries
      : await buildBoundaries(wavPath, durationSec, targetChunkSec(durationSec), controller.signal, onProgress)
    if (controller.signal.aborted) throw new Error('已取消')

    let cp: TranscribeCheckpoint
    if (reusable) {
      cp = reusable
    } else {
      discardCheckpoint(videoPath)
      cp = createCheckpoint(videoPath, {
        model: modelName,
        language: options.language,
        durationSec,
        boundaries
      })
    }

    const totalChunks = boundaries.length - 1
    // 找到第一个「还没做完」的分片
    let startChunk = 0
    while (startChunk < totalChunks && boundaries[startChunk + 1] <= cp.processedSec + 0.5) {
      startChunk++
    }
    const resumeLabel = cp.processedSec > 1 ? `（从 ${fmtSec(cp.processedSec)} 继续）` : ''

    for (let k = startChunk; k < totalChunks; k++) {
      if (controller.signal.aborted) throw new Error('已取消')
      const start = boundaries[k]
      const end = boundaries[k + 1]
      const dur = end - start
      if (dur <= 0.2) continue

      const message = totalChunks > 1
        ? `正在识别语音（Whisper）第 ${k + 1}/${totalChunks} 段${resumeLabel}`
        : '正在识别语音（Whisper）'

      // 切出这一片音频，whisper 只看到本片内容，不会重复识别下一段
      // （短文件只有一个分片，直接识别原音频，省一次无谓的拷贝）
      const direct = boundaries.length === 2 && start <= 0.01
      const chunkWav = join(getTempDir(), `chunk-${randomUUID()}.wav`)
      try {
        if (!direct) await cutAudio(wavPath, chunkWav, start, dur, controller.signal)
        const part = await transcribe(direct ? wavPath : chunkWav, modelPath, {
          signal: controller.signal,
          language: options.language === 'auto' ? 'auto' : options.language,
          timeOffsetSec: start,
          onProgress: (percent) => {
            onProgress({
              stage: 'transcribe',
              message,
              percent: Math.min(99, Math.round(((start + (dur * percent) / 100) / durationSec) * 100))
            })
          }
        })
        if (controller.signal.aborted) throw new Error('已取消')

        const baseIndex = cp.segments.length
        cp.segments.push(...part.segments.map((s, i) => ({ ...s, index: baseIndex + i })))
        if (part.detectedLanguage && !cp.detectedLanguage) cp.detectedLanguage = part.detectedLanguage
      } finally {
        await rm(chunkWav, { force: true }).catch(() => {})
      }

      cp.processedSec = end
      // 每片结束立刻落盘：此时关闭应用，下次从这一片之后继续
      writeCheckpoint(cp)

      onProgress({
        stage: 'transcribe',
        message,
        percent: Math.min(99, Math.round((cp.processedSec / durationSec) * 100)),
        detectedLanguage: cp.detectedLanguage
      })
    }

    // 全部分片完成：断点已无用，清掉
    discardCheckpoint(videoPath)
    const segments: SubtitleSegment[] = cp.segments.map((s, i) => ({ ...s, index: i }))
    const detectedLanguage = cp.detectedLanguage ?? (options.language === 'auto' ? 'auto' : options.language)

    onProgress({ stage: 'done', message: '识别完成', percent: 100, detectedLanguage })
    return { segments, detectedLanguage }
  } finally {
    if (active === controller) active = undefined
    await rm(wavPath, { force: true }).catch(() => {})
  }
}
