// 把 AI 引擎引用的 Homebrew 等外部动态库一起打包，避免换一台 Mac 后无法启动。
import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, lstatSync, mkdirSync, openSync, closeSync, readSync, readdirSync, realpathSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'

if (process.platform !== 'darwin') throw new Error('此脚本仅用于 macOS 打包')
const dir = resolve(import.meta.dirname, '..', 'resources', 'bin', `darwin-${process.arch}`)
for (const name of ['whisper-cli', 'whisper-server', 'llama-server']) {
  if (!existsSync(join(dir, name))) throw new Error(`缺少 AI 引擎：${name}，请先运行 build:whisper 和 build:llama`)
}

const visited = new Set()
const copied = new Map()
function bundle(file) {
  file = realpathSync(file)
  if (visited.has(file)) return
  visited.add(file)
  const fd = openSync(file, 'r')
  const header = Buffer.alloc(4)
  try { readSync(fd, header, 0, 4, 0) } finally { closeSync(fd) }
  if (!['cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca'].includes(header.toString('hex'))) return
  const lines = execFileSync('otool', ['-L', file], { encoding: 'utf8' }).trim().split('\n').slice(1)
  // 动态库的第一行是自身的 install name，不是依赖。
  if (file.endsWith('.dylib')) lines.shift()
  for (const line of lines) {
    const dependency = line.trim().split(' (compatibility version ')[0]
    if (dependency.startsWith('/usr/lib/') || dependency.startsWith('/System/Library/')) continue
    const target = join(dir, basename(dependency))
    if (dependency.startsWith('/')) {
      const source = realpathSync(dependency)
      const previous = copied.get(target)
      if (previous && previous !== source) throw new Error(`动态库重名：${dependency} 和 ${previous}`)
      if (!previous) {
        copyFileSync(source, target)
        copied.set(target, source)
        const packageDir = dirname(dirname(source))
        const license = join(packageDir, 'LICENSE.txt')
        if (existsSync(license)) {
          mkdirSync(join(dir, 'licenses'), { recursive: true })
          copyFileSync(license, join(dir, 'licenses', `${basename(dirname(packageDir))}-${basename(packageDir)}.txt`))
        }
      }
      bundle(target)
      execFileSync('install_name_tool', ['-change', dependency, `@loader_path/${basename(target)}`, file])
    } else if (dependency.startsWith('@rpath/') || dependency.startsWith('@loader_path/')) {
      if (!existsSync(target)) throw new Error(`${file} 缺少动态库：${dependency}`)
    } else {
      throw new Error(`${file} 包含无法打包的动态库路径：${dependency}`)
    }
  }
}
for (const name of readdirSync(dir)) {
  const file = join(dir, name)
  if (lstatSync(file).isFile()) bundle(file)
}
console.log(`macOS 引擎依赖检查完成，补齐 ${copied.size} 个外部动态库；后续统一 ad-hoc 签名。`)
