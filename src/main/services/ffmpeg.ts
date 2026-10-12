import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { app } from 'electron'
import ffmpegStatic from 'ffmpeg-static'
import { getBinDir, platformArch } from './paths'
import type { ConversionMode, MediaProbe } from '../../shared/media'
import { parseMediaProbe } from './mediaProbe'

export interface FfmpegLog {
  type: 'stderr' | 'stdout'
  data: string
}

/** 不依赖额外的 ffprobe 安装；限制日志大小和探测时间。 */
export function probeVideo(videoPath: string): Promise<MediaProbe> {
  return new Promise((resolve, reject) => {
    const proc = spawn(resolveFfmpeg(), ['-nostdin', '-hide_banner', '-i', videoPath], { windowsHide: true })
    let output = ''
    const timer = setTimeout(() => {
      proc.kill('SIGKILL')
      reject(new Error('读取媒体信息超时'))
    }, 30000)
    proc.stderr.on('data', (d: Buffer) => { output = (output + d.toString()).slice(-256 * 1024) })
    proc.on('error', (err) => {
      clearTimeout(timer)
      reject(new Error(`无法启动 ffmpeg：${err.message}`))
    })
    proc.on('close', () => {
      clearTimeout(timer)
      try { resolve(parseMediaProbe(output)) } catch (err) { reject(err) }
    })
  })
}

export function resolveFfmpeg(): string {
  if (process.env.FFMPEG_BIN) return process.env.FFMPEG_BIN
  // 优先用随 app 打包的平台特定 ffmpeg 二进制（Windows 用 ffmpeg.exe）
  const name = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg'
  const local = join(getBinDir(), platformArch(), name)
  if (existsSync(local)) return local
  const inBin = join(getBinDir(), name)
  if (existsSync(inBin)) return inBin
  // 回退到 ffmpeg-static（打包后需修正 asar.unpacked 路径）
  if (!ffmpegStatic) {
    throw new Error('未找到 ffmpeg 二进制（ffmpeg-static 未就绪）')
  }
  return app.isPackaged ? ffmpegStatic.replace('app.asar', 'app.asar.unpacked') : ffmpegStatic
}

/** 从视频抽取 16kHz 单声道 WAV（whisper.cpp 所需格式） */
export function extractAudio(
  videoPath: string,
  outWavPath: string,
  onLog?: (log: FfmpegLog) => void,
  signal?: AbortSignal
): Promise<void> {
  return new Promise((resolve, reject) => {
    const ffmpeg = resolveFfmpeg()
    const args = [
      '-y',
      '-hide_banner',
      '-i',
      videoPath,
      '-vn',
      '-ac',
      '1',
      '-ar',
      '16000',
      '-c:a',
      'pcm_s16le',
      outWavPath
    ]
    const proc = spawn(ffmpeg, args, { signal, windowsHide: true })
    proc.stderr.on('data', (d: Buffer) => onLog?.({ type: 'stderr', data: d.toString() }))
    proc.on('error', (err) => {
      // AbortError 后仍有 close 事件；等进程关闭再让上层清理临时 WAV。
      if (!signal?.aborted) reject(new Error(`无法启动 ffmpeg：${err.message}`))
    })
    proc.on('close', (code) => {
      if (signal?.aborted) reject(new Error('已取消'))
      else if (code === 0) resolve()
      else reject(new Error(`ffmpeg 抽取音频失败（退出码 ${code}）`))
    })
  })
}

/** 明确选择默认音视频流，排除封面、附件、字幕和数据流。 */
export function conversionArgs(
  videoPath: string, outPath: string, mode: ConversionMode, probe: MediaProbe
): string[] {
  const args = ['-nostdin', '-y', '-hide_banner', '-i', videoPath]
  if (probe.videoStream != null) args.push('-map', `0:${probe.videoStream}`)
  if (probe.audioStream != null) args.push('-map', `0:${probe.audioStream}`)
  args.push('-sn', '-dn')
  if (mode === 'transcode') {
    args.push('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
      '-vf', 'scale=ceil(iw/2)*2:ceil(ih/2)*2', '-pix_fmt', 'yuv420p')
  } else {
    args.push('-c:v', 'copy')
  }
  if (mode === 'remux') args.push('-c:a', 'copy')
  else args.push('-c:a', 'aac', '-b:a', '192k', '-ac', '2', '-ar', '48000')
  args.push('-max_muxing_queue_size', '4096', '-movflags', '+faststart', outPath)
  return args
}

/** 取消后等待进程退出才结束，避免旧进程仍在写文件。 */
export function convertMedia(
  videoPath: string,
  outPath: string,
  mode: ConversionMode,
  probe: MediaProbe,
  signal: AbortSignal,
  onLog?: (log: FfmpegLog) => void
): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(new Error('已取消'))
    const proc = spawn(resolveFfmpeg(), conversionArgs(videoPath, outPath, mode, probe), { windowsHide: true })
    let tail = ''
    let killTimer: ReturnType<typeof setTimeout> | undefined
    const abort = (): void => {
      proc.kill()
      killTimer = setTimeout(() => proc.kill('SIGKILL'), 2000)
    }
    signal.addEventListener('abort', abort, { once: true })
    proc.stderr.on('data', (d: Buffer) => {
      const data = d.toString()
      tail = (tail + data).slice(-4096)
      if (!signal.aborted) onLog?.({ type: 'stderr', data })
    })
    const cleanup = (): void => {
      signal.removeEventListener('abort', abort)
      if (killTimer) clearTimeout(killTimer)
    }
    proc.on('error', (err) => {
      cleanup()
      reject(new Error(`无法启动 ffmpeg：${err.message}`))
    })
    proc.on('close', (code) => {
      cleanup()
      if (signal.aborted) reject(new Error('已取消'))
      else if (code === 0) resolve()
      else reject(new Error(`视频转换失败（退出码 ${code}）：${tail.trim().slice(-1500)}`))
    })
  })
}
