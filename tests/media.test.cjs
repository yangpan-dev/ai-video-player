const { test, after } = require('node:test')
const assert = require('node:assert/strict')
const { mkdtempSync, writeFileSync, copyFileSync, readdirSync, existsSync, rmSync, utimesSync, openSync, ftruncateSync, closeSync } = require('node:fs')
const { tmpdir } = require('node:os')
const { join, resolve } = require('node:path')
const { spawnSync } = require('node:child_process')
const { createServer } = require('node:http')
const { once } = require('node:events')
const dir = mkdtempSync(join(tmpdir(), 'video-compat-test-'))
const load = require('./load-ts.cjs')({ app: { isPackaged: false, getAppPath: () => resolve('.'), getPath: () => dir } })
const { probeVideo } = load('src/main/services/ffmpeg.ts')
const { parseMediaProbe } = load('src/main/services/mediaProbe.ts')
const { playbackMode } = load('src/shared/media.ts')
const { mediaHandler } = load('src/main/services/mediaProtocol.ts')
const cache = load('src/main/services/playbackCache.ts')
const ffmpeg = require('ffmpeg-static')
const outputs = []
after(() => {
  cache.cancelConvert()
  if (process.env.MEDIA_TEST_MANIFEST) {
    writeFileSync(process.env.MEDIA_TEST_MANIFEST, JSON.stringify({ dir, outputs }))
  } else rmSync(dir, { recursive: true, force: true })
})
function run(args) {
  const result = spawnSync(ffmpeg, ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', ...args], { encoding: 'utf8', timeout: 30000 })
  assert.equal(result.status, 0, result.stderr || String(result.error))
  return result
}
function fixture(name, codecs, audio = true, size = '160x90') {
  const path = join(dir, name)
  const args = ['-f', 'lavfi', '-i', `testsrc2=size=${size}:rate=12`]
  if (audio) args.push('-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000')
  run([...args, '-t', '1.2', ...codecs, path])
  return path
}

test('probe skips cover art and selects default streams, including transport stream IDs', () => {
  const probe = parseMediaProbe(`Duration: 00:02:03.45, start: 0.0
  Stream #0:0: Video: mjpeg, yuvj420p(pc), 100x100 (attached pic)
  Stream #0:1[0x100](und): Video: h264 (High 10), yuv420p10le(tv, bt709), 1920x1080 (default)
  Stream #0:2(eng): Audio: dts (DTS), 48000 Hz
  Stream #0:3(jpn): Audio: aac (LC), 48000 Hz (default)`)
  assert.equal(probe.videoStream, 1)
  assert.equal(probe.audioStream, 3)
  assert.equal(probe.pixelFormat, 'yuv420p10le')
  assert.equal(probe.duration, 123.45)
  assert.equal(playbackMode('movie.mp4', probe), 'transcode')
  assert.throws(() => parseMediaProbe('invalid data'), /没有找到/)
})

const cases = [
  ['normal.mp4', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac'], 'direct'],
  ['ac3.mp4', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'ac3'], 'audio'],
  ['vp9.mkv', ['-c:v', 'libvpx-vp9', '-c:a', 'aac'], 'remux'],
  ['av1.mp4', ['-c:v', 'libaom-av1', '-cpu-used', '8', '-c:a', 'aac'], 'direct'],
  ['hevc.mp4', ['-c:v', 'libx265', '-preset', 'ultrafast', '-x265-params', 'pools=1', '-c:a', 'aac'], 'transcode'],
  ['prores.mov', ['-c:v', 'prores_ks', '-profile:v', '0', '-pix_fmt', 'yuv422p10le', '-c:a', 'pcm_s16le'], 'transcode'],
  ['high10.mp4', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p10le', '-c:a', 'aac'], 'transcode'],
  ['hevc10.mkv', ['-c:v', 'libx265', '-preset', 'ultrafast', '-x265-params', 'pools=1', '-pix_fmt', 'yuv420p10le', '-c:a', 'aac'], 'transcode'],
  ['legacy.avi', ['-c:v', 'mpeg4', '-c:a', 'pcm_s16le'], 'transcode'],
  ['broadcast.ts', ['-c:v', 'mpeg2video', '-c:a', 'ac3'], 'transcode'],
  ['windows.wmv', ['-c:v', 'wmv2', '-c:a', 'wmav2'], 'transcode'],
  ['browser.webm', ['-c:v', 'libvpx', '-c:a', 'libvorbis'], 'direct'],
  ['copy.mkv', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac'], 'remux'],
  ['surround.mkv', ['-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'dca', '-strict', '-2'], 'audio']
]
for (const [name, codecs, expected] of cases) {
  test(`real FFmpeg: ${name} → ${expected}`, async () => {
    const source = fixture(name, codecs)
    const probe = await probeVideo(source)
    assert.equal(playbackMode(source, probe), expected)
    let output = source
    if (expected !== 'direct') {
      const converted = await cache.prepareConversion(source, expected)
      assert.equal(converted.cached, false)
      output = converted.outputPath
      const result = await probeVideo(output)
      assert.equal(result.videoCodec, expected === 'transcode' ? 'h264' : probe.videoCodec)
      assert.equal(result.pixelFormat, 'yuv420p')
      assert.equal(result.audioCodec, 'aac')
      assert.equal((await cache.prepareConversion(source, expected)).cached, true)
    }
    run(['-i', output, '-f', 'null', '-'])
    outputs.push({ name, source, path: output, mode: expected })
  })
}

test('MKV with embedded subtitles and attachment remuxes only audio/video', async () => {
  const subtitles = join(dir, 'subtitle.srt')
  writeFileSync(subtitles, '1\n00:00:00,000 --> 00:00:01,000\nTest\n')
  const source = join(dir, 'attachments.mkv')
  run(['-i', join(dir, 'copy.mkv'), '-i', subtitles, '-map', '0', '-map', '1', '-c', 'copy', '-c:s', 'ass',
    '-attach', subtitles, '-metadata:s:t', 'mimetype=text/plain', source])
  const result = await cache.prepareConversion(source, 'remux')
  assert.equal((await probeVideo(result.outputPath)).videoCodec, 'h264')
  const info = spawnSync(ffmpeg, ['-hide_banner', '-i', result.outputPath], { encoding: 'utf8' }).stderr
  assert.doesNotMatch(info, /Subtitle:|Attachment:/)
})

test('odd dimensions and video without audio produce 8-bit even-dimension H.264', async () => {
  const source = join(dir, 'odd.mkv')
  run(['-f', 'lavfi', '-i', 'testsrc=size=161x91:rate=12', '-t', '1.2', '-c:v', 'ffv1', '-pix_fmt', 'yuv444p', source])
  const result = await cache.prepareConversion(source, 'transcode')
  const probe = await probeVideo(result.outputPath)
  assert.equal(probe.pixelFormat, 'yuv420p')
  assert.equal(probe.audioCodec, '')
  outputs.push({ name: 'odd-no-audio', source, path: result.outputPath })
})

test('audio-only input remains audio-only', async () => {
  const source = join(dir, 'audio.m4a')
  run(['-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '1.2', '-c:a', 'alac', source])
  const probe = await probeVideo(source)
  assert.equal(playbackMode(source, probe), 'audio')
  const result = await cache.prepareConversion(source, 'audio')
  assert.equal((await probeVideo(result.outputPath)).audioCodec, 'aac')
})

test('remux cache cannot masquerade as transcoded output; fingerprint invalidates changed sources', async () => {
  const source = join(dir, 'high10.mp4')
  const remux = await cache.prepareConversion(source, 'remux')
  assert.equal((await probeVideo(remux.outputPath)).pixelFormat, 'yuv420p10le')
  const encoded = await cache.prepareConversion(source, 'transcode')
  assert.notEqual(remux.outputPath, encoded.outputPath)
  assert.equal((await probeVideo(encoded.outputPath)).pixelFormat, 'yuv420p')
  const future = new Date(Date.now() + 2000)
  utimesSync(source, future, future)
  assert.equal((await cache.prepareConversion(source, 'transcode')).cached, false)
})

test('cancelled and superseded jobs leave no partial cache and can be retried', async () => {
  const source = join(dir, 'legacy.avi')
  const first = cache.prepareConversion(source, 'remux')
  const second = cache.prepareConversion(source, 'audio')
  await assert.rejects(first, /已取消/)
  await second
  // Cancel when ffmpeg has actually started producing log output.
  const cancelled = cache.prepareConversion(join(dir, 'browser.webm'), 'transcode', () => cache.cancelConvert())
  await assert.rejects(cancelled, /已取消/)
  assert.ok(!readdirSync(cache.cacheStats().dir).some((name) => name.includes('.partial.')))
  assert.equal((await cache.prepareConversion(join(dir, 'browser.webm'), 'transcode')).cached, false)
})

test('cancelling a stalled media probe stops FFmpeg and releases its input', { timeout: 10000 }, async (t) => {
  const controller = new AbortController()
  const server = createServer(() => { /* 模拟尚未返回媒体数据的输入。 */ })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  try {
    const request = once(server, 'request', { signal: t.signal })
    const cancelled = assert.rejects(probeVideo(`http://127.0.0.1:${server.address().port}/slow`, controller.signal), /已取消/)
    const [incoming] = await request
    incoming.on('error', () => { /* FFmpeg 取消时会重置连接。 */ })
    const closed = new Promise(resolve => incoming.once('close', resolve))
    controller.abort()
    await cancelled
    await closed
    await assert.rejects(probeVideo('unused.mp4', controller.signal), /已取消/)
  } finally {
    controller.abort()
    server.closeAllConnections()
    server.close()
  }
})

test('rapid switching serializes probes, cancels active input and skips superseded requests', { timeout: 10000 }, async (t) => {
  const opened = []
  let liveInputs = 0
  let maxInputs = 0
  const server = createServer((request) => {
    opened.push(request.url)
    maxInputs = Math.max(maxInputs, ++liveInputs)
    request.on('error', () => { /* 取消会重置连接。 */ })
    request.on('close', () => liveInputs--)
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const url = `http://127.0.0.1:${server.address().port}`
  try {
    const firstStarted = once(server, 'request', { signal: t.signal })
    const first = assert.rejects(cache.probePlayback(url + '/first'), /已取消/)
    await firstStarted
    const latestStarted = once(server, 'request', { signal: t.signal })
    const skipped = assert.rejects(cache.probePlayback(url + '/skipped'), /已取消/)
    const latest = assert.rejects(cache.probePlayback(url + '/latest'), /已取消/)
    await latestStarted
    cache.cancelConvert()
    await Promise.all([first, skipped, latest])
    assert.deepEqual(opened, ['/first', '/latest'])
    assert.equal(maxInputs, 1)
    assert.equal((await cache.probePlayback(join(dir, 'normal.mp4'))).videoCodec, 'h264')
  } finally {
    cache.cancelConvert()
    server.closeAllConnections()
    server.close()
  }
})

test('opening a new video stops an active conversion before probing and removes partial output', async () => {
  const source = join(dir, 'interrupted.ts')
  copyFileSync(join(dir, 'broadcast.ts'), source)
  let next
  const interrupted = cache.prepareConversion(source, 'transcode', () => {
    next ??= cache.probePlayback(join(dir, 'normal.mp4'))
  })
  await assert.rejects(interrupted, /已取消/)
  assert.ok(next)
  assert.equal((await next).videoCodec, 'h264')
  assert.ok(!readdirSync(cache.cacheStats().dir).some((name) => name.includes('.partial.')))
})

test('truncated cache is rebuilt; cleanup is serialized before a new conversion', async () => {
  const source = join(dir, 'copy.mkv')
  const first = await cache.prepareConversion(source, 'remux')
  writeFileSync(first.outputPath, 'truncated')
  const rebuilt = await cache.prepareConversion(source, 'remux')
  assert.equal(rebuilt.cached, false)
  const cleanup = cache.clearCache()
  const next = cache.prepareConversion(join(dir, 'hevc10.mkv'), 'transcode')
  await cleanup
  const result = await next
  assert.equal((await probeVideo(result.outputPath)).pixelFormat, 'yuv420p')
})

test('corrupt/missing input rejects; failures never create a valid cache', async () => {
  const source = join(dir, 'broken.mp4')
  writeFileSync(source, 'not video data')
  await assert.rejects(probeVideo(source), /没有找到/)
  await assert.rejects(probeVideo(join(dir, 'missing.mp4')), /没有找到/)
  await assert.rejects(cache.prepareConversion(source, 'transcode'))
  assert.ok(!readdirSync(cache.cacheStats().dir).some((name) => name.includes('.partial.')))
})

test('streaming protocol handles normal, open, suffix, invalid ranges and HEAD', async () => {
  const source = join(dir, '字 幕 # %.mp4')
  writeFileSync(source, '0123456789')
  const url = 'media://f/' + encodeURIComponent(source)
  const request = (range, method = 'GET') => mediaHandler(new Request(url, { method, headers: range ? { range } : {} }))
  for (const [range, expected, status] of [[null, '0123456789', 200], ['bytes=2-4', '234', 206], ['bytes=7-', '789', 206], ['bytes=-3', '789', 206], ['bytes=8-99', '89', 206]]) {
    const response = await request(range)
    assert.equal(response.status, status)
    assert.equal(await response.text(), expected)
  }
  for (const range of ['bytes=99-', 'bytes=4-2', 'bytes=-0', 'bytes=-', 'bytes=0-1,3-4', 'garbage']) {
    assert.equal((await request(range)).status, 416)
  }
  const head = await request('bytes=2-4', 'HEAD')
  assert.equal(head.headers.get('content-length'), '3')
  assert.equal(await head.text(), '')
  const sparse = join(dir, 'large.mp4')
  const fd = openSync(sparse, 'w'); ftruncateSync(fd, 5 * 1024 ** 3); closeSync(fd)
  const large = await mediaHandler(new Request('media://f/' + encodeURIComponent(sparse), { headers: { range: 'bytes=0-' } }))
  const reader = large.body.getReader()
  assert.ok((await reader.read()).value.length <= 256 * 1024)
  await reader.cancel()
})

test('cache cleanup protects the file currently playing', async () => {
  const current = await cache.prepareConversion(join(dir, 'copy.mkv'), 'remux')
  cache.cancelConvert()
  await cache.clearCache()
  assert.ok(existsSync(current.outputPath))
  assert.equal(cache.cacheStats().fileCount, 1)
  cache.releasePlaybackCache()
  await cache.clearCache()
  assert.equal(cache.cacheStats().fileCount, 0)
})
