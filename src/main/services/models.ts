import { createWriteStream, existsSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { ReadableStream as WebReadableStream } from 'node:stream/web'
import type { ModelProgress, WhisperModelInfo } from '@shared/types'
import { WHISPER_MODELS } from '@shared/types'
import { getModelsDir } from './paths'

/**
 * HuggingFace 端点列表（国内镜像优先，失败自动轮换到下一个源）。
 * 默认顺序：hf-mirror → aifasthub → huggingface 官方站。
 * 可通过环境变量 HF_ENDPOINT / HF_MIRROR 覆盖，支持逗号分隔多个自定义源，如：
 *   HF_ENDPOINT=https://hf-mirror.com,https://aifasthub.com pnpm dev
 */
function hfEndpoints(): string[] {
  const custom = (process.env.HF_ENDPOINT ?? process.env.HF_MIRROR ?? '').trim()
  if (custom) {
    const list = custom
      .split(',')
      .map((s) => s.trim().replace(/\/+$/, ''))
      .filter(Boolean)
    if (list.length) return list
  }
  return ['https://hf-mirror.com', 'https://aifasthub.com', 'https://huggingface.co']
}

function modelUrl(base: string, name: string): string {
  return `${base}/ggerganov/whisper.cpp/resolve/main/ggml-${name}.bin`
}

const VAD_MODEL_FILE = 'ggml-silero-v6.2.0.bin'
const LLM_MODEL_FILE = 'Qwen2.5-7B-Instruct-Q4_K_M.gguf'

/** 连续多少毫秒收不到数据就判定连接停滞，主动断开并切换源重试 */
const STALL_TIMEOUT_MS = 20_000
/** 总重试次数（在所有源之间轮换） */
const MAX_ATTEMPTS = 12
/** 切换源前的短暂等待 */
const RETRY_DELAY_MS = 1_500

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

export function vadModelFile(): string {
  return join(getModelsDir(), VAD_MODEL_FILE)
}

export function vadModelExists(): boolean {
  return existsSync(vadModelFile())
}

/** 确保 Silero VAD 模型已下载（约 864KB），失败自动轮换国内镜像 */
export async function ensureVadModel(): Promise<string> {
  const dest = vadModelFile()
  if (existsSync(dest)) return dest
  for (const base of hfEndpoints()) {
    try {
      const url = `${base}/ggml-org/whisper-vad/resolve/main/${VAD_MODEL_FILE}`
      const res = await fetch(url)
      if (res.ok) {
        writeFileSync(dest, Buffer.from(await res.arrayBuffer()))
        return dest
      }
    } catch {
      /* 尝试下一个源 */
    }
  }
  throw new Error('Silero VAD 模型下载失败，请检查网络或设置 HF_ENDPOINT 镜像')
}

export function whisperModelFile(name: string): string {
  return join(getModelsDir(), `ggml-${name}.bin`)
}

export function modelExists(name: string): boolean {
  return existsSync(whisperModelFile(name))
}

/** 列出可选模型及本地安装状态 */
export function listModels(): WhisperModelInfo[] {
  return WHISPER_MODELS.map((m) => ({
    name: m.name,
    label: m.label,
    sizeMb: m.sizeMb,
    installed: modelExists(m.name)
  }))
}

export function llmModelFile(): string {
  return join(getModelsDir(), LLM_MODEL_FILE)
}

export function llmModelExists(): boolean {
  return existsSync(llmModelFile())
}

/** 流式写文件（支持追加续传），实时回传进度；每次收到数据会重置停滞计时器 */
async function streamToFile(
  res: Response,
  sink: ReturnType<typeof createWriteStream>,
  received: number,
  total: number,
  name: string,
  resetTimer: () => void,
  onProgress?: (p: ModelProgress) => void
): Promise<void> {
  const reader = (res.body as WebReadableStream<Uint8Array>).getReader()
  await new Promise<void>((resolve, reject) => {
    let settled = false
    const pump = async (): Promise<void> => {
      try {
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          resetTimer()
          received += value.byteLength
          if (!sink.write(Buffer.from(value))) {
            await new Promise<void>((r) => sink.once('drain', () => r()))
          }
          if (total > 0) {
            onProgress?.({
              name,
              percent: Math.min(100, Math.round((received / total) * 100)),
              message: `${(received / 1024 / 1024).toFixed(1)} / ${(total / 1024 / 1024).toFixed(1)} MB`
            })
          }
        }
        sink.end()
        resolve()
      } catch (err) {
        sink.destroy()
        if (!settled) {
          settled = true
          reject(err instanceof Error ? err : new Error(String(err)))
        }
      }
    }
    sink.on('error', (err) => {
      if (!settled) {
        settled = true
        reject(err)
      }
    })
    sink.on('finish', () => {
      if (!settled) {
        settled = true
        resolve()
      }
    })
    void pump()
  })
}

/**
 * 带断点续传 + 多源轮换 + 停滞检测 + 自动重试的下载：
 * - 下载到 .part，中断后下次从已下载字节继续（HTTP Range）。
 * - 连续 20 秒无数据（网络假死/限速暂停）主动断开，切换源重试。
 * - 重试时保留已下载进度百分比，不会把进度条打回 0%。
 */
async function downloadFileResumable(
  urls: string[],
  dest: string,
  name: string,
  onProgress?: (p: ModelProgress) => void
): Promise<void> {
  const tmp = dest + '.part'
  let lastPercent = 0
  let lastError: unknown = null

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const url = urls[attempt % urls.length]
    const host = new URL(url).host
    const existingSize = existsSync(tmp) ? statSync(tmp).size : 0
    const headers: Record<string, string> = {}
    if (existingSize > 0) headers['Range'] = `bytes=${existingSize}-`

    const controller = new AbortController()
    let stalled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const resetTimer = (): void => {
      if (timer) clearTimeout(timer)
      timer = setTimeout(() => {
        stalled = true
        controller.abort()
      }, STALL_TIMEOUT_MS)
    }
    resetTimer()
    const report = (p: ModelProgress): void => {
      lastPercent = p.percent
      onProgress?.(p)
    }

    try {
      report({
        name,
        percent: lastPercent,
        message:
          attempt === 0
            ? `连接 ${host} …`
            : `切换 ${host}${existingSize > 0 ? ` · 续传 ${(existingSize / 1024 / 1024).toFixed(1)} MB` : ''} …`
      })

      const res = await fetch(url, { headers, signal: controller.signal })

      // .part 已完整：Range 请求返回 416
      if (existingSize > 0 && res.status === 416) {
        onProgress?.({ name, percent: 100, message: '已完整' })
        break
      }
      if (!res.ok || !res.body) {
        throw new Error(`HTTP ${res.status} ${res.statusText}`)
      }

      // 服务器忽略 Range（返回 200 而非 206）时必须从头写，否则追加会损坏文件
      const append = existingSize > 0 && res.status === 206
      const start = append ? existingSize : 0
      const contentLength = Number(res.headers.get('content-length') ?? 0)
      const total = start + contentLength

      const sink = createWriteStream(tmp, append ? { flags: 'a' } : {})
      await streamToFile(res, sink, start, total, name, resetTimer, report)
      break
    } catch (err) {
      lastError = err
      if (attempt === MAX_ATTEMPTS - 1) {
        throw new Error(
          `下载失败（${stalled ? `连接停滞 ${STALL_TIMEOUT_MS / 1000} 秒` : err instanceof Error ? err.message : String(err)}）`
        )
      }
      const doneMb = (existsSync(tmp) ? statSync(tmp).size / 1024 / 1024 : 0).toFixed(1)
      report({
        name,
        percent: lastPercent,
        message: `${stalled ? '连接停滞' : '网络中断'}（已下 ${doneMb} MB），切换源重试（第 ${attempt + 1}/${MAX_ATTEMPTS} 次）…`
      })
      if (stalled) {
        // 停滞往往是当前源限速/挂起，短暂等待后换下一个源
        controller.abort()
      }
      await sleep(RETRY_DELAY_MS)
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  if (!existsSync(tmp)) throw new Error('下载未完成：临时文件不存在')
  renameSync(tmp, dest)
  onProgress?.({ name, percent: 100, message: '完成' })
}

/** 下载 whisper ggml 模型，实时回传进度（多源 + 断点续传 + 停滞检测） */
export async function downloadModel(
  name: string,
  onProgress?: (p: ModelProgress) => void
): Promise<string> {
  const dest = whisperModelFile(name)

  if (existsSync(dest)) {
    onProgress?.({ name, percent: 100, message: '已存在' })
    return dest
  }

  const urls = hfEndpoints().map((base) => modelUrl(base, name))
  await downloadFileResumable(urls, dest, name, onProgress)
  return dest
}

/** 下载本地 LLM 翻译模型（Qwen2.5-7B，约 4.4GB），实时回传进度（多源 + 断点续传） */
export async function downloadLlmModel(onProgress?: (p: ModelProgress) => void): Promise<string> {
  const dest = llmModelFile()
  const name = 'qwen2.5-7b'

  if (existsSync(dest)) {
    onProgress?.({ name, percent: 100, message: '已存在' })
    return dest
  }

  const urls = hfEndpoints().map(
    (base) => `${base}/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/${LLM_MODEL_FILE}`
  )
  await downloadFileResumable(urls, dest, name, onProgress)
  return dest
}
