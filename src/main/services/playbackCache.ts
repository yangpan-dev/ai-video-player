import { createHash, randomUUID } from 'node:crypto'
import { existsSync, readFileSync, readdirSync, renameSync, statSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { ConversionMode, MediaProbe } from '../../shared/media'
import { convertMedia, probeVideo, type FfmpegLog } from './ffmpeg'
import { getTranscodeCacheDir } from './paths'

const LIMIT = 20 * 1024 ** 3
// 升级版本使旧的 10bit 输出、全流重封装缓存失效。
const VERSION = 2
let generation = 0
let active: AbortController | undefined
let queue: Promise<unknown> = Promise.resolve()
let protectedPath: string | undefined

export function cancelConvert(): void {
  generation++
  active?.abort()
}

export function releasePlaybackCache(): void {
  protectedPath = undefined
}

// 探测和转换共用队列；取消必须等旧 FFmpeg 退出，新任务才能启动。
function runLatest<T>(run: (signal: AbortSignal, check: () => void) => Promise<T>): Promise<T> {
  cancelConvert()
  const ticket = generation
  const job = queue.catch(() => {}).then(async () => {
    const check = (): void => { if (ticket !== generation) throw new Error('已取消') }
    check()
    const controller = new AbortController()
    active = controller
    try {
      const result = await run(controller.signal, check)
      check()
      return result
    } finally {
      if (active === controller) active = undefined
    }
  })
  queue = job
  return job
}

export function probePlayback(sourcePath: string): Promise<MediaProbe> {
  return runLatest((signal) => probeVideo(sourcePath, signal))
}

function remove(path: string): void {
  try { unlinkSync(path) } catch { /* 文件可能已被清理或正在使用 */ }
}

function entries(): Array<{ path: string; size: number; time: number }> {
  return readdirSync(getTranscodeCacheDir()).flatMap((name) => {
    const path = join(getTranscodeCacheDir(), name)
    try {
      const stat = statSync(path)
      return stat.isFile() ? [{ path, size: stat.size, time: stat.mtimeMs }] : []
    } catch { return [] }
  })
}

function trimCache(): void {
  const files = entries().filter((f) => f.path.endsWith('.mp4') && !f.path.includes('.partial.'))
  let total = files.reduce((sum, f) => sum + f.size, 0)
  for (const file of files.sort((a, b) => a.time - b.time)) {
    if (total <= LIMIT) break
    if (file.path === protectedPath) continue
    remove(file.path)
    if (!existsSync(file.path)) {
      remove(file.path + '.json')
      total -= file.size
    }
  }
}

export function cacheStats(): { fileCount: number; totalBytes: number; dir: string } {
  const files = entries()
  return { fileCount: files.filter((f) => f.path.endsWith('.mp4')).length,
    totalBytes: files.reduce((sum, f) => sum + f.size, 0), dir: getTranscodeCacheDir() }
}

export function clearCache(): Promise<ReturnType<typeof cacheStats>> {
  cancelConvert()
  const job = queue.catch(() => {}).then(() => {
    // 和转换共用队列，清理期间新提交的转换必须等待，避免删除它的临时文件。
    for (const file of entries()) {
      if (file.path !== protectedPath && file.path !== protectedPath + '.json') remove(file.path)
    }
    return cacheStats()
  })
  queue = job
  return job
}

export function prepareConversion(
  sourcePath: string, mode: ConversionMode, onLog?: (log: FfmpegLog) => void
): Promise<{ outputPath: string; cached: boolean }> {
  return runLatest(async (signal, check) => {
    const source = statSync(sourcePath)
    const fingerprint = JSON.stringify({ version: VERSION, sourcePath, mode, size: source.size, mtime: source.mtimeMs })
    const key = createHash('sha256').update(fingerprint).digest('hex')
    const outputPath = join(getTranscodeCacheDir(), `${key}.${mode}.mp4`)
    const sidecar = outputPath + '.json'
    let valid = false
    try {
      const meta = JSON.parse(readFileSync(sidecar, 'utf8')) as { fingerprint: string; outputSize: number }
      valid = meta.fingerprint === fingerprint && meta.outputSize > 0 && statSync(outputPath).size === meta.outputSize
    } catch { /* 缓存丢失、损坏或被截断时重新生成 */ }
    if (valid) {
      protectedPath = outputPath
      utimesSync(outputPath, new Date(), new Date())
      return { outputPath, cached: true }
    }
    const temporary = join(getTranscodeCacheDir(), `${key}.${randomUUID()}.partial.mp4`)
    try {
      const probe = await probeVideo(sourcePath, signal)
      check()
      await convertMedia(sourcePath, temporary, mode, probe, signal, onLog)
      check()
      const current = statSync(sourcePath)
      if (current.size !== source.size || current.mtimeMs !== source.mtimeMs) throw new Error('源文件在转换期间发生了变化，请重新打开。')
      const outputSize = statSync(temporary).size
      if (outputSize === 0) throw new Error('转换结果为空')
      // 只有完整成功的产物可进入缓存；不同模式绝不互相冒充。
      renameSync(temporary, outputPath)
      writeFileSync(sidecar, JSON.stringify({ fingerprint, outputSize }))
      protectedPath = outputPath
      trimCache()
      return { outputPath, cached: false }
    } finally {
      remove(temporary)
    }
  })
}
