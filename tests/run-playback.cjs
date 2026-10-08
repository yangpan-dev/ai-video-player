const { mkdtempSync, readFileSync, rmSync } = require('node:fs')
const { tmpdir } = require('node:os')
const { join, resolve } = require('node:path')
const { spawnSync } = require('node:child_process')
const work = mkdtempSync(join(tmpdir(), 'video-playback-suite-'))
const manifest = join(work, 'manifest.json')
const env = { ...process.env, MEDIA_TEST_MANIFEST: manifest }
try {
  const fixtures = spawnSync(process.execPath, ['--test', 'tests/media.test.cjs'], { env, stdio: 'inherit' })
  if (fixtures.status !== 0) process.exitCode = 1
  else {
    const playback = spawnSync(require('electron'), [resolve('tests/playback-smoke.cjs')], { env, stdio: 'inherit' })
    process.exitCode = playback.status ?? 1
  }
} finally {
  try {
    const { dir } = JSON.parse(readFileSync(manifest, 'utf8'))
    rmSync(dir, { recursive: true, force: true })
  } catch { /* fixture setup failed */ }
  rmSync(work, { recursive: true, force: true })
}
