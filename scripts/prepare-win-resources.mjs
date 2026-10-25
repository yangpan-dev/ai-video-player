// 随 Windows AI 引擎打包运行库，并在不依赖开发工具 PATH 的环境中检查启动。
import { execFileSync, spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const bin = join(root, 'resources', 'bin', 'win32-x64')
const engines = ['whisper-cli.exe', 'whisper-server.exe', 'llama-server.exe']
for (const name of engines) {
  if (!existsSync(join(bin, name))) throw new Error(`缺少 Windows 引擎 ${name}，请先编译 AI 引擎。`)
}
if (process.platform !== 'win32') {
  console.log('交叉打包：复用已准备的 Windows 引擎及运行库；启动检查需在 Windows 执行。')
  process.exit(0)
}

const programFiles = process.env.ProgramFiles || 'C:\\Program Files'
const vswhere = join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
const vs = execFileSync(vswhere, ['-latest', '-products', '*', '-property', 'installationPath'], { encoding: 'utf8' }).trim()
const redist = join(vs, 'VC', 'Redist', 'MSVC')
const versions = readdirSync(redist, { withFileTypes: true })
  .filter(entry => entry.isDirectory()).map(entry => entry.name)
  .sort((a, b) => b.localeCompare(a, 'en', { numeric: true }))
let copied = 0
for (const version of versions) {
  const x64 = join(redist, version, 'x64')
  if (!existsSync(x64)) continue
  const groups = readdirSync(x64).filter(name => /^Microsoft\.VC\d+\.(CRT|OpenMP)$/i.test(name))
  if (!groups.length) continue
  for (const group of groups) {
    const dir = join(x64, group)
    for (const name of readdirSync(dir).filter(name => /\.dll$/i.test(name))) {
      copyFileSync(join(dir, name), join(bin, name))
      copied++
    }
  }
  break
}
for (const name of ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'vcomp140.dll']) {
  if (!existsSync(join(bin, name))) throw new Error(`缺少可分发运行库 ${name}，请安装 Visual Studio C++ 构建工具。`)
}

const sslNames = ['libssl-3-x64.dll', 'libcrypto-3-x64.dll']
const sslRoots = [process.env.OPENSSL_ROOT_DIR, process.env.OPENSSL_DIR,
  join(programFiles, 'OpenSSL'), join(programFiles, 'OpenSSL-Win64')].filter(Boolean)
const ssl = sslRoots.find(dir => sslNames.every(name => existsSync(join(dir, 'bin', name))))
if (!ssl) throw new Error('缺少 OpenSSL x64 运行库，请安装与 llama-server 编译时一致的 OpenSSL 3。')
for (const name of sslNames) {
  copyFileSync(join(ssl, 'bin', name), join(bin, name))
  copied++
}
const licenses = join(bin, 'licenses')
mkdirSync(licenses, { recursive: true })
const sslLicense = ['LICENSE.txt', 'LICENSE', 'LICENSE.md'].map(name => join(ssl, name)).find(existsSync)
copyFileSync(sslLicense || join(root, 'build', 'licenses', 'OpenSSL.txt'), join(licenses, 'OpenSSL.txt'))

const systemRoot = process.env.SystemRoot || 'C:\\Windows'
const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => name.toLowerCase() !== 'path'))
env.PATH = [bin, join(systemRoot, 'System32'), systemRoot].join(';')
for (const name of engines) {
  const result = spawnSync(join(bin, name), ['--help'], {
    cwd: bin, env, encoding: 'utf8', timeout: 30000, windowsHide: true
  })
  if (result.error || result.status !== 0 || result.signal) {
    throw new Error(`${name} 启动检查失败：${result.error?.message || result.status}\n${(result.stderr || '').slice(-1600)}`)
  }
  console.log(`PASS ${name}: 在精简 PATH 下可启动`)
}
console.log(`Windows 运行库准备完成，拷贝 ${copied} 个 DLL。`)
