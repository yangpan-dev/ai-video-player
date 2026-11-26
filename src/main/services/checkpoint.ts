import { app } from 'electron'
import { createHash } from 'node:crypto'
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
  readdirSync
} from 'node:fs'
import { join } from 'node:path'
import type { SubtitleSegment } from '@shared/types'

/**
 * 语音识别断点。
 *
 * whisper 一次只能整段跑完，中途关闭就白做。这里把识别结果按「已完成的音频位置」
 * 落盘：批量模式按分片记录，流式模式按窗口记录。下次打开同一文件时可以从
 * processedSec 继续，而不是从 0 重来。
 *
 * 断点用「文件大小 + 修改时间」做有效性校验，源文件被改动（重新下载/剪辑）后自动失效。
 */
export interface TranscribeCheckpoint {
  version: 1
  videoPath: string
  fileSize: number
  fileMtimeMs: number
  /** 创建断点时使用的模型（仅用于展示，不参与校验） */
  model: string
  language: string
  /** 音频总时长（秒，0 表示未知） */
  durationSec: number
  /**
   * 批量模式的分片边界（秒，含 0 与结尾）。切在静音处，
   * 续做时直接复用，保证分片位置与上次完全一致；流式模式不记录。
   */
  boundaries?: number[]
  /** 已完成的音频位置（秒）：从这里继续 */
  processedSec: number
  segments: SubtitleSegment[]
  detectedLanguage?: string
  updatedAt: number
}

/** 暴露给界面的断点摘要 */
export interface TranscribeCheckpointInfo {
  percent: number
  segmentCount: number
  processedSec: number
  durationSec: number
  updatedAt: number
  model: string
}

function dirPath(): string {
  const dir = join(app.getPath('userData'), 'transcribe-checkpoints')
  mkdirSync(dir, { recursive: true })
  return dir
}

function filePath(videoPath: string): string {
  const hash = createHash('sha1').update(videoPath).digest('hex').slice(0, 20)
  return join(dirPath(), `${hash}.json`)
}

/** 读取断点；源文件已变化或数据损坏时自动丢弃并返回 null */
export function readCheckpoint(videoPath: string): TranscribeCheckpoint | null {
  const file = filePath(videoPath)
  if (!existsSync(file)) return null
  try {
    const cp = JSON.parse(readFileSync(file, 'utf8')) as TranscribeCheckpoint
    if (cp.version !== 1 || cp.videoPath !== videoPath) throw new Error('断点格式不匹配')
    if (!Array.isArray(cp.segments)) throw new Error('断点内容损坏')
    const st = statSync(videoPath)
    if (st.size !== cp.fileSize || Math.abs(st.mtimeMs - cp.fileMtimeMs) > 1) {
      throw new Error('源文件已变化')
    }
    return cp
  } catch {
    discardCheckpoint(videoPath)
    return null
  }
}

export function createCheckpoint(
  videoPath: string,
  init: { model: string; language: string; durationSec: number; boundaries?: number[] }
): TranscribeCheckpoint {
  const st = statSync(videoPath)
  return {
    version: 1,
    videoPath,
    fileSize: st.size,
    fileMtimeMs: st.mtimeMs,
    model: init.model,
    language: init.language,
    durationSec: init.durationSec,
    boundaries: init.boundaries,
    processedSec: 0,
    segments: [],
    updatedAt: Date.now()
  }
}

/** 原子写入，避免写一半被强杀留下坏文件 */
export function writeCheckpoint(cp: TranscribeCheckpoint): void {
  try {
    cp.updatedAt = Date.now()
    const file = filePath(cp.videoPath)
    const tmp = `${file}.tmp`
    writeFileSync(tmp, JSON.stringify(cp), 'utf8')
    renameSync(tmp, file)
  } catch {
    /* 断点写失败不影响识别本身 */
  }
}

export function discardCheckpoint(videoPath: string): void {
  try {
    unlinkSync(filePath(videoPath))
  } catch {
    /* 不存在时忽略 */
  }
}

/** 给界面用的断点摘要；没有可用断点时返回 null */
export function checkpointInfo(videoPath: string): TranscribeCheckpointInfo | null {
  const cp = readCheckpoint(videoPath)
  if (!cp) return null
  const total = cp.durationSec > 0 ? cp.durationSec : 0
  const percent = total > 0
    ? Math.max(1, Math.min(99, Math.round((cp.processedSec / total) * 100)))
    : 0
  return {
    percent,
    segmentCount: cp.segments.length,
    processedSec: cp.processedSec,
    durationSec: total,
    updatedAt: cp.updatedAt,
    model: cp.model
  }
}

/** 清理长期未使用的断点（默认 30 天），避免 userData 里越积越多 */
export function pruneCheckpoints(maxAgeDays = 30): void {
  const dir = dirPath()
  const deadline = Date.now() - maxAgeDays * 24 * 3600 * 1000
  let names: string[] = []
  try {
    names = readdirSync(dir)
  } catch {
    return
  }
  for (const name of names) {
    if (!name.endsWith('.json')) continue
    const full = join(dir, name)
    try {
      if (statSync(full).mtimeMs < deadline) unlinkSync(full)
    } catch {
      /* 忽略 */
    }
  }
}
