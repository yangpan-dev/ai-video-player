/**
 * 下载本地 LLM 翻译模型（Qwen2.5-7B-Instruct Q4_K_M，约 4.4GB）到 resources/models/。
 * 用法：node scripts/download-llm.mjs
 * 多源优先：hf-mirror → aifasthub → huggingface；支持 HF_ENDPOINT 覆盖与断点续传。
 */
import { existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { downloadResumable, hfEndpoints } from './lib/download.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const modelsDir = join(root, 'resources', 'models')
const FILE = 'Qwen2.5-7B-Instruct-Q4_K_M.gguf'
const dest = join(modelsDir, FILE)

mkdirSync(modelsDir, { recursive: true })
if (existsSync(dest)) {
  console.log('已存在：', dest)
  process.exit(0)
}

const urls = hfEndpoints().map(
  (base) => `${base}/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/${FILE}`
)
console.log('开始下载翻译模型：Qwen2.5-7B-Instruct-Q4_K_M（约 4.4GB）')
try {
  await downloadResumable(urls, dest)
  console.log('\n✅ 完成：', dest)
} catch (e) {
  console.error('\n❌', e.message)
  console.error('可设置镜像：HF_ENDPOINT=https://hf-mirror.com,https://aifasthub.com')
  process.exit(1)
}
