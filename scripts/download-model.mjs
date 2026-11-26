/**
 * 下载 whisper ggml 模型到 resources/models/。
 * 用法：node scripts/download-model.mjs [tiny|base|small|medium|large-v3-turbo|large-v3]
 * 多源优先：hf-mirror → aifasthub → huggingface；支持 HF_ENDPOINT 覆盖与断点续传。
 */
import { existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { downloadResumable, hfEndpoints } from './lib/download.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const modelsDir = join(root, 'resources', 'models')
const name = process.argv[2] || 'small'
const dest = join(modelsDir, `ggml-${name}.bin`)

mkdirSync(modelsDir, { recursive: true })
if (existsSync(dest)) {
  console.log('已存在：', dest)
  process.exit(0)
}

const urls = hfEndpoints().map(
  (base) => `${base}/ggerganov/whisper.cpp/resolve/main/ggml-${name}.bin`
)
console.log('开始下载 whisper 模型：', name)
try {
  await downloadResumable(urls, dest)
  console.log('\n✅ 完成：', dest)
} catch (e) {
  console.error('\n❌', e.message)
  console.error('可设置镜像：HF_ENDPOINT=https://hf-mirror.com,https://aifasthub.com')
  process.exit(1)
}
