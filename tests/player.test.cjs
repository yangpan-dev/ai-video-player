const { test, after } = require('node:test')
const assert = require('node:assert/strict')
const { mkdtempSync, writeFileSync, rmSync } = require('node:fs')
const { tmpdir } = require('node:os')
const { join, resolve } = require('node:path')
const dir = mkdtempSync(join(tmpdir(), 'player-features-'))
const load = require('./load-ts.cjs')({ app: { isPackaged: false, getPath: () => dir, getAppPath: () => resolve('.') } })
const { parseSrt, readSubtitleFile, loadSavedSubtitles, buildSrt } = load('src/main/services/subtitle.ts')
const { normalizePreferences } = load('src/shared/playerPreferences.ts')
const { isUsableTranslation, parseTranslations } = load('src/shared/translationQuality.ts')
const { LlmServer } = load('src/main/services/llm.ts')
after(() => rmSync(dir, { recursive: true, force: true }))

test('translation commentary is rejected while literal dialogue is preserved', () => {
  for (const item of require('./fixtures/translation-quality.json')) {
    assert.equal(isUsableTranslation(item.translation, item.source), item.usable, item.translation)
  }
  assert.deepEqual(parseTranslations('{"translations":{"b":"再见","a":"用户提供了一些额外的信息"}}', [{ id: 'a', text: 'Hello' }, { id: 'b', text: 'Goodbye' }]), { b: '再见' })
})

test('Vue translator retries only commentary and never returns it as a subtitle', async (t) => {
  const server = new LlmServer()
  server.proc = { exitCode: null }
  const requests = []
  t.mock.method(globalThis, 'fetch', async (_url, init) => {
    const payload = JSON.parse(init.body)
    const request = JSON.parse(payload.messages[1].content)
    requests.push(request)
    assert.deepEqual(payload.response_format.schema.properties.translations.required, request.lines.map(line => line.id))
    const translations = Object.fromEntries(request.lines.map(line => [line.id,
      line.id === '1' ? '再见' : requests.length < 3 ? '用户提供了一些额外的信息，我将根据这些信息进行翻译。' : '你好']))
    return { ok: true, json: async () => ({ choices: [{ message: { content: JSON.stringify({ translations }) } }] }) }
  })
  assert.deepEqual(await server.translate(['Hello', 'Goodbye'], { srcLang: 'eng_Latn', context: ['Earlier dialogue'] }), ['你好', '再见'])
  assert.deepEqual(requests.map(row => row.lines.map(line => line.id)), [['0', '1'], ['0'], ['0']])
  assert.ok(requests.slice(1).every(row => row.context.length === 0))
})

test('persistent commentary remains untranslated after bounded retries', async (t) => {
  const server = new LlmServer()
  server.proc = { exitCode: null }
  let calls = 0
  t.mock.method(globalThis, 'fetch', async (_url, init) => {
    calls++
    const request = JSON.parse(JSON.parse(init.body).messages[1].content)
    return { ok: true, json: async () => ({ choices: [{ message: { content: JSON.stringify({ translations: { [request.lines[0].id]: '以下是翻译结果：你好。' } }) } }] }) }
  })
  assert.deepEqual(await server.translate(['Hello'], { srcLang: 'eng_Latn' }), [''])
  assert.equal(calls, 3)
})

test('saved AI subtitles hide old commentary and retain originals', () => {
  writeFileSync(join(dir, 'commentary.zh.srt'), '1\n00:00:00,000 --> 00:00:02,000\nHello\n用户提供了一些额外的信息，我将根据这些信息进行翻译。')
  const saved = loadSavedSubtitles(join(dir, 'commentary.mp4'))
  assert.equal(saved[0].text, 'Hello')
  assert.equal(saved[0].translation, undefined)
})

test('SRT import preserves all text lines, normalizes CRLF/BOM and sorts cues', () => {
  const result = parseSrt('\uFEFF2\r\n00:00:03,000 --> 00:00:04,000\r\n<b>Later</b>\r\n\r\n1\r\n00:00:00,500 --> 00:00:02,000\r\nLine one\r\nLine two\r\nLine three', false)
  assert.equal(result.length, 2)
  assert.equal(result[0].text, 'Line one\nLine two\nLine three')
  assert.equal(result[1].text, 'Later')
  assert.equal(result[0].start, 0.5)
  assert.equal(result[0].translation, undefined)
})

test('WebVTT accepts short timestamps, cue identifiers, settings and ignores notes', () => {
  const result = parseSrt('WEBVTT\n\nNOTE comment\n00:00.000 --> 00:01.000\nignore\n\ncue-id\n00:01.500 --> 00:02.750 align:start\n<v Speaker>Hello &amp; goodbye</v>\n\n00:03.000 --> 00:02.000\nbad range', false)
  assert.equal(result.length, 1)
  assert.equal(result[0].text, 'Hello & goodbye')
  assert.equal(result[0].start, 1.5)
})

test('generated bilingual SRT keeps translation on reload', () => {
  const input = [{ index: 0, start: 0, end: 2, text: 'Hello', translation: '你好\n第三行' }]
  assert.deepEqual(parseSrt(buildSrt(input)), input)
})

test('external UTF-16 subtitles and adjacent VTT files load without AI', () => {
  const file = join(dir, 'movie.srt')
  writeFileSync(file, Buffer.from('\uFEFF1\n00:00:00,000 --> 00:00:01,000\n中文\n第二行', 'utf16le'))
  assert.equal(readSubtitleFile(file)[0].text, '中文\n第二行')
  assert.equal(loadSavedSubtitles(join(dir, 'movie.mp4'))[0].text, '中文\n第二行')
  const vtt = join(dir, 'second.vtt')
  writeFileSync(vtt, 'WEBVTT\n\n00:00.000 --> 00:01.000\nSecond')
  assert.equal(loadSavedSubtitles(join(dir, 'second.mkv'))[0].text, 'Second')
  writeFileSync(join(dir, 'invalid.srt'), 'invalid')
  assert.throws(() => readSubtitleFile(join(dir, 'invalid.srt')), /没有有效/)
})

test('stored preferences reject invalid values and clamp numeric settings', () => {
  const p = normalizePreferences({ volume: 9, muted: 'yes', playbackRate: -1, fontSize: NaN, subtitleMode: 'bad', subtitleOffset: Infinity })
  assert.equal(p.volume, 1)
  assert.equal(p.muted, false)
  assert.equal(p.playbackRate, 0.25)
  assert.equal(p.fontSize, 20)
  assert.equal(p.subtitleMode, 'bilingual')
  assert.equal(p.subtitleOffset, 0)
  assert.equal(normalizePreferences({ subtitleOffset: 120 }).subtitleOffset, 60)
  assert.equal(normalizePreferences(null).autoNext, false)
})
