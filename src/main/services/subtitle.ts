import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { basename, extname, join } from 'node:path'
import type { SaveSubtitlesPayload, SaveSubtitlesResult, SubtitleSegment } from '@shared/types'

function pad(n: number, w = 2): string {
  return String(n).padStart(w, '0')
}

function srtTime(seconds: number): string {
  const ms = Math.max(0, Math.round(seconds * 1000))
  const h = Math.floor(ms / 3600000)
  const m = Math.floor((ms % 3600000) / 60000)
  const s = Math.floor((ms % 60000) / 1000)
  const mm = ms % 1000
  return `${pad(h)}:${pad(m)}:${pad(s)},${pad(mm, 3)}`
}

function vttTime(seconds: number): string {
  return srtTime(seconds).replace(',', '.')
}

/** 拼接双语行（原文在上，译文在下） */
function cueText(seg: SubtitleSegment): string {
  return seg.translation ? `${seg.text}\n${seg.translation}` : seg.text
}

export function buildSrt(segments: SubtitleSegment[]): string {
  return segments
    .map(
      (s, i) => `${i + 1}\n${srtTime(s.start)} --> ${srtTime(s.end)}\n${cueText(s)}`
    )
    .join('\n\n')
}

export function buildVtt(segments: SubtitleSegment[]): string {
  const cues = segments
    .map((s) => `${vttTime(s.start)} --> ${vttTime(s.end)}\n${cueText(s)}`)
    .join('\n\n')
  return `WEBVTT\n\n${cues}\n`
}

/** 将双语字幕写入视频同目录的 .srt / .vtt 文件 */
export function saveSubtitles(payload: SaveSubtitlesPayload): SaveSubtitlesResult {
  const { videoPath, segments } = payload
  const base = basename(videoPath).replace(/\.[^.]+$/, '')
  const dir = videoPath.slice(0, videoPath.length - basename(videoPath).length)

  const srtPath = join(dir, `${base}.zh.srt`)
  const vttPath = join(dir, `${base}.zh.vtt`)
  writeFileSync(srtPath, buildSrt(segments), 'utf8')
  writeFileSync(vttPath, buildVtt(segments), 'utf8')
  return { srtPath, vttPath }
}

/** 解析 SRT 文本为字幕片段（支持双语：第一行原文，第二行译文） */
export function parseSrt(content: string, bilingual = true): SubtitleSegment[] {
  const blocks = content.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n').trim().split(/\n\s*\n/)
  const segments: SubtitleSegment[] = []
  for (const block of blocks) {
    if (/^(?:NOTE|STYLE|REGION)(?:\s|$)/.test(block)) continue
    const lines = block.split('\n').filter((l) => l.trim().length > 0)
    const timeIdx = lines.findIndex((l) => l.includes('-->'))
    if (timeIdx === -1) continue
    const m = /^(?:(\d+):)?(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{2}):(\d{2})[,.](\d{1,3})(?:\s|$)/.exec(lines[timeIdx].trim())
    if (!m) continue
    const start = +(m[1] ?? 0) * 3600 + +m[2] * 60 + +m[3] + +m[4].padEnd(3, '0') / 1000
    const end = +(m[5] ?? 0) * 3600 + +m[6] * 60 + +m[7] + +m[8].padEnd(3, '0') / 1000
    if (end <= start || +m[2] > 59 || +m[3] > 59 || +m[6] > 59 || +m[7] > 59) continue
    const textLines = lines.slice(timeIdx + 1).map((line) => line
      .replace(/<[^>]*>/g, '')
      .replace(/&(?:amp|lt|gt|quot|apos|nbsp);/g, (entity) => ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'", '&nbsp;': ' ' })[entity] ?? entity))
    if (!textLines.join('').trim()) continue
    segments.push({
      index: segments.length,
      start,
      end,
      text: bilingual ? textLines[0] : textLines.join('\n'),
      translation: bilingual && textLines.length > 1 ? textLines.slice(1).join('\n') : undefined
    })
  }
  return segments.sort((a, b) => a.start - b.start || a.end - b.end).map((s, index) => ({ ...s, index }))
}

export function readSubtitleFile(path: string, bilingual = false): SubtitleSegment[] {
  if (!['.srt', '.vtt'].includes(extname(path).toLowerCase())) throw new Error('请选择 SRT 或 VTT 字幕文件')
  if (statSync(path).size > 10 * 1024 * 1024) throw new Error('字幕文件过大（上限 10 MB）')
  const data = readFileSync(path)
  let text: string
  if (data[0] === 0xff && data[1] === 0xfe) text = new TextDecoder('utf-16le').decode(data)
  else if (data[0] === 0xfe && data[1] === 0xff) text = new TextDecoder('utf-16be').decode(data)
  else {
    try { text = new TextDecoder('utf-8', { fatal: true }).decode(data) }
    catch { text = new TextDecoder('gb18030').decode(data) }
  }
  const segments = parseSrt(text, bilingual)
  if (!segments.length) throw new Error('字幕中没有有效的时间轴或文字')
  return segments
}

/** 读取视频同目录已保存的 .zh.srt 字幕（若有），返回片段；无则返回 null */
export function loadSavedSubtitles(videoPath: string): SubtitleSegment[] | null {
  const base = basename(videoPath).replace(/\.[^.]+$/, '')
  const dir = videoPath.slice(0, videoPath.length - basename(videoPath).length)
  for (const suffix of ['.zh.srt', '.zh.vtt', '.srt', '.vtt']) {
    const path = join(dir, base + suffix)
    if (!existsSync(path)) continue
    try { return readSubtitleFile(path, suffix.startsWith('.zh.')) } catch { /* 尝试其他同名字幕 */ }
  }
  return null
}
