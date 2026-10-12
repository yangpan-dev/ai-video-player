// Uses the existing Git credential helper; credentials stay in memory and are never printed.
// --check is read-only. Publishing requires a pushed commit and explicit asset paths.
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createReadStream, readFileSync, statSync } from 'node:fs'
import { basename, resolve } from 'node:path'

const repo = 'yangpan-dev/ai-video-player'
const root = resolve(import.meta.dirname, '..')
const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim()
if (git('remote', 'get-url', 'origin') !== `https://github.com/${repo}.git`) throw new Error('Unexpected origin repository')
const credentials = execFileSync('git', ['credential', 'fill'], {
  cwd: root, input: 'protocol=https\nhost=github.com\n\n', encoding: 'utf8',
  env: { ...process.env, GIT_TERMINAL_PROMPT: '0' }, stdio: ['pipe', 'pipe', 'pipe']
})
const token = credentials.split('\n').find(line => line.startsWith('password='))?.slice(9)
if (!token) throw new Error('No GitHub credential available in Git credential helper')
async function api(url, options = {}) {
  const u = new URL(url)
  if (u.protocol !== 'https:' || !['api.github.com', 'uploads.github.com'].includes(u.hostname)) throw new Error('Unexpected API host')
  const response = await fetch(u, {
    ...options, redirect: 'error', signal: AbortSignal.timeout(15 * 60 * 1000),
    headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`,
      'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'AIVideoPlayer-release', ...options.headers }
  })
  if (response.status === 404 && options.allow404) return null
  if (!response.ok) throw new Error(`GitHub API ${response.status}: ${(await response.json()).message ?? 'request failed'}`)
  return response.json()
}
const base = `https://api.github.com/repos/${repo}`
const info = await api(base)
console.log(`Repository: ${info.full_name}; push access: ${info.permissions?.push === true}`)
if (process.argv.includes('--check')) {
  const releases = await api(`${base}/releases?per_page=5`)
  console.log(JSON.stringify(releases.map(r => ({ tag: r.tag_name, draft: r.draft, url: r.html_url })), null, 2))
  process.exit(0)
}
if (!info.permissions?.push) throw new Error('Missing repository push permission')
const { version } = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8'))
const tag = `v${version}`
const commit = git('rev-parse', 'HEAD')
if (!git('ls-remote', 'origin', 'refs/heads/main').startsWith(commit + '\t')) throw new Error('Push this commit to origin/main before publishing')
const paths = process.argv.slice(2).map(path => resolve(path))
if (!paths.length) throw new Error('Provide release asset paths')
for (const path of paths) if (!statSync(path).isFile() || !statSync(path).size) throw new Error(`Empty/missing asset ${path}`)
const body = readFileSync(resolve(root, 'releases', `${tag}.md`), 'utf8')
let release = await api(`${base}/releases/tags/${tag}`, { allow404: true })
if (!release) {
  // Drafts are uploaded and verified before the release becomes public.
  const drafts = await api(`${base}/releases?per_page=100`)
  release = drafts.find(r => r.tag_name === tag)
}
if (release && !release.draft) throw new Error('This version is already published; do not overwrite it')
if (!release) release = await api(`${base}/releases`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ tag_name: tag, target_commitish: commit, name: `AIVideoPlayer ${tag}`, body, draft: true, prerelease: false })
})
const hash = async (path) => {
  const h = createHash('sha256')
  for await (const chunk of createReadStream(path)) h.update(chunk)
  return h.digest('hex')
}
for (const path of paths) {
  const name = basename(path)
  const digest = `sha256:${await hash(path)}`
  const existing = release.assets.find(asset => asset.name === name)
  if (existing) {
    if (existing.state !== 'uploaded' || existing.size !== statSync(path).size || existing.digest !== digest) {
      throw new Error(`Existing asset differs: ${name}; preserving it for review`)
    }
    console.log(`Already uploaded and verified: ${name}`)
    continue
  }
  console.log(`Uploading ${name} (${Math.round(statSync(path).size / 1024 / 1024)} MB)`)
  const url = new URL(release.upload_url.split('{')[0])
  url.searchParams.set('name', name)
  const uploaded = await api(url.toString(), {
    method: 'POST', headers: { 'Content-Type': 'application/octet-stream', 'Content-Length': String(statSync(path).size) },
    body: createReadStream(path), duplex: 'half'
  })
  if (uploaded.state !== 'uploaded' || uploaded.size !== statSync(path).size || uploaded.digest !== digest) {
    throw new Error(`Uploaded asset verification failed: ${name}`)
  }
  console.log(`Verified SHA-256: ${name}`)
}
release = await api(`${base}/releases/${release.id}`, {
  method: 'PATCH', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ draft: false, body, make_latest: 'true' })
})
console.log(`Published: ${release.html_url}`)
