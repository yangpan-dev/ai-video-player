import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
const app = join(root, 'dist', 'mac-arm64', '熊猫播放器.app')
const output = join(root, 'dist', `PandaPlayer-Electron-${version}-arm64-mac.zip`)
execFileSync('codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' })
execFileSync('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, output], { stdio: 'inherit' })
console.log(`已生成 ${output}`)
