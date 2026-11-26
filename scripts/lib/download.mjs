/**
 * CLI 模型下载公共工具：多源轮换 + 断点续传 + 停滞检测 + 自动重试。
 * 与 src/main/services/models.ts 保持一致的行为。
 */
import { createWriteStream, existsSync, renameSync, statSync } from 'node:fs'

/** 国内镜像优先，官方站兜底；HF_ENDPOINT / HF_MIRROR 可覆盖（逗号分隔多个源） */
export function hfEndpoints() {
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

const STALL_TIMEOUT_MS = 20_000
const MAX_ATTEMPTS = 12
const RETRY_DELAY_MS = 1_500
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function progress(received, total) {
  if (!total) return
  const pct = Math.min(100, Math.round((received / total) * 100))
  process.stdout.write(
    `\r  ${pct}% · ${(received / 1024 / 1024).toFixed(1)} / ${(total / 1024 / 1024).toFixed(1)} MB`
  )
}

/** 下载到 dest，自动处理 .part 续传与多源切换 */
export async function downloadResumable(urls, dest) {
  const tmp = dest + '.part'

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const url = urls[attempt % urls.length]
    const host = new URL(url).host
    const existingSize = existsSync(tmp) ? statSync(tmp).size : 0
    const headers = existingSize > 0 ? { Range: `bytes=${existingSize}-` } : {}

    const controller = new AbortController()
    let stalled = false
    let timer
    const resetTimer = () => {
      if (timer) clearTimeout(timer)
      timer = setTimeout(() => {
        stalled = true
        controller.abort()
      }, STALL_TIMEOUT_MS)
    }
    resetTimer()

    try {
      console.log(`  连接 ${host}${existingSize > 0 ? ` · 续传 ${(existingSize / 1024 / 1024).toFixed(1)} MB` : ''} …`)
      const res = await fetch(url, { headers, signal: controller.signal })

      if (existingSize > 0 && res.status === 416) {
        console.log('\n  已完整')
        break
      }
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status} ${res.statusText}`)

      // 服务器忽略 Range 时从头写，避免追加导致文件损坏
      const append = existingSize > 0 && res.status === 206
      const start = append ? existingSize : 0
      const contentLength = Number(res.headers.get('content-length') ?? 0)
      const total = start + contentLength

      const sink = createWriteStream(tmp, append ? { flags: 'a' } : {})
      let received = start
      const reader = res.body.getReader()
      await new Promise((resolve, reject) => {
        let settled = false
        const pump = async () => {
          try {
            for (;;) {
              const { done, value } = await reader.read()
              if (done) break
              resetTimer()
              received += value.byteLength
              if (!sink.write(Buffer.from(value))) {
                await new Promise((r) => sink.once('drain', () => r()))
              }
              progress(received, total)
            }
            sink.end()
            resolve()
          } catch (err) {
            sink.destroy()
            if (!settled) {
              settled = true
              reject(err)
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
      break
    } catch (err) {
      if (attempt === MAX_ATTEMPTS - 1) {
        throw new Error(
          `下载失败（${stalled ? `连接停滞 ${STALL_TIMEOUT_MS / 1000} 秒` : err.message}）`
        )
      }
      const doneMb = (existsSync(tmp) ? statSync(tmp).size / 1024 / 1024 : 0).toFixed(1)
      console.log(
        `\n  ${stalled ? '连接停滞' : '网络中断'}（已下 ${doneMb} MB），切换源重试（第 ${attempt + 1}/${MAX_ATTEMPTS} 次）…`
      )
      if (stalled) controller.abort()
      await sleep(RETRY_DELAY_MS)
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  if (!existsSync(tmp)) throw new Error('下载未完成：临时文件不存在')
  renameSync(tmp, dest)
}
