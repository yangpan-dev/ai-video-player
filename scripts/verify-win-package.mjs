// 对真正从安装程序解出的应用做检查，避免只验证开发机上的源目录。
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const app = resolve(process.argv[2])
const installer = resolve(process.argv[3])
const expectedVersion = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version
const archive = readFileSync(join(app, 'resources', 'app.asar'))
const headerSize = archive.readUInt32LE(4)
const header = JSON.parse(archive.subarray(16, 16 + archive.readUInt32LE(12)).toString())
const entry = header.files['package.json']
const start = 8 + headerSize + Number(entry.offset)
const packaged = JSON.parse(archive.subarray(start, start + entry.size).toString())
if (packaged.version !== expectedVersion) throw new Error(`包内版本不符：${packaged.version}，预期 ${expectedVersion}`)

const native = join(app, 'resources', 'bin', 'win32-x64')
const engines = ['whisper-cli.exe', 'whisper-server.exe', 'llama-server.exe']
for (const name of [...engines, 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'vcomp140.dll', 'libssl-3-x64.dll', 'libcrypto-3-x64.dll']) {
  if (!existsSync(join(native, name))) throw new Error(`安装包缺少 ${name}`)
}
const binaries = [join(app, 'PandaPlayer.exe'),
  join(app, 'resources', 'app.asar.unpacked', 'node_modules', 'ffmpeg-static', 'ffmpeg.exe'),
  ...readdirSync(native).filter(name => /\.(exe|dll)$/i.test(name)).map(name => join(native, name))]
for (const path of binaries) {
  const bytes = readFileSync(path)
  const offset = bytes.readUInt32LE(0x3c)
  if (bytes.toString('ascii', offset, offset + 4) !== 'PE\0\0' || bytes.readUInt16LE(offset + 4) !== 0x8664) {
    throw new Error(`不是 Windows x64 程序：${path}`)
  }
}
if (process.platform !== 'win32') throw new Error('引擎启动验证必须在 Windows 执行')
const systemRoot = process.env.SystemRoot || 'C:\\Windows'
const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => name.toLowerCase() !== 'path'))
env.PATH = [native, join(systemRoot, 'System32'), systemRoot].join(';')
for (const name of engines) {
  const result = spawnSync(join(native, name), ['--help'], { cwd: native, env, encoding: 'utf8', timeout: 30000, windowsHide: true })
  if (result.error || result.status !== 0 || result.signal) throw new Error(`包内 ${name} 无法启动：${result.error?.message || result.status}`)
  console.log(`PASS packaged ${name}: clean PATH startup`)
}
const sha256 = createHash('sha256').update(readFileSync(installer)).digest('hex')
writeFileSync(installer + '.sha256', `${sha256}  ${installer.split(/[\\/]/).pop()}\n`)
writeFileSync(installer + '.verification.json', JSON.stringify({ version: packaged.version, sha256, binaries: binaries.length, engines: engines.length }, null, 2))
console.log(JSON.stringify({ version: packaged.version, sha256, binaries: binaries.length }))
