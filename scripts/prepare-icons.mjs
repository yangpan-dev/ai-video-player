// Native macOS and Electron derive every icon from the same generated PNG.
import { execFileSync } from 'node:child_process'
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
const root = resolve(import.meta.dirname, '..')
const native = join(root, 'native-macos')
const iconset = join(native, 'build', 'AppIcon.iconset')
mkdirSync(join(native, 'build'), { recursive: true })
mkdirSync(join(native, '.build', 'clang-cache'), { recursive: true })
execFileSync('swift', ['-module-cache-path', join(native, '.build', 'clang-cache'), 'scripts/make-icon.swift', iconset], { cwd: native, stdio: 'inherit' })
execFileSync('iconutil', ['-c', 'icns', iconset, '-o', join(root, 'build', 'icon.icns')], { stdio: 'inherit' })
const png = readFileSync(join(native, 'Resources', 'PandaPlayer-icon.png'))
for (const path of ['build/icon.png', 'src/renderer/public/app-icon.png', 'src/renderer/src/assets/app-icon.png']) writeFileSync(join(root, path), png)
// ICO supports embedded PNGs, preserving transparency at every Windows size.
const sizes = [16, 32, 48, 64, 128, 256]
const images = sizes.map(size => {
  const path = join(native, 'build', `icon-${size}.png`)
  execFileSync('sips', ['-z', String(size), String(size), join(root, 'build/icon.png'), '--out', path], { stdio: 'pipe' })
  return readFileSync(path)
})
const header = Buffer.alloc(6 + sizes.length * 16)
header.writeUInt16LE(1, 2); header.writeUInt16LE(sizes.length, 4)
let offset = header.length
images.forEach((bytes, i) => {
  const pos = 6 + i * 16
  header[pos] = header[pos + 1] = sizes[i] === 256 ? 0 : sizes[i]
  header.writeUInt16LE(1, pos + 4); header.writeUInt16LE(32, pos + 6)
  header.writeUInt32LE(bytes.length, pos + 8); header.writeUInt32LE(offset, pos + 12)
  offset += bytes.length
})
writeFileSync(join(root, 'build/icon.ico'), Buffer.concat([header, ...images]))
copyFileSync(join(root, 'build/icon.icns'), join(native, 'build', 'AppIcon.icns'))
console.log('Updated shared PNG, ICNS and Windows ICO icons.')
