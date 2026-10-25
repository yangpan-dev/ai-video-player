import { ipcMain, dialog, BrowserWindow } from 'electron'
import { extname } from 'node:path'
import type { RunPipelineOptions, SaveSubtitlesPayload } from '@shared/types'
import { runPipeline, cancelPipeline } from './services/pipeline'
import { startStreaming, cancelStreaming } from './services/streaming'
import { listModels, downloadModel, downloadLlmModel, llmModelExists } from './services/models'
import { getLlmServer, isLlmRunning } from './services/llm'
import { saveSubtitles, loadSavedSubtitles, readSubtitleFile } from './services/subtitle'
import {
  getLibrary,
  addToPlaylist,
  removeFromPlaylist,
  clearPlaylist,
  addToHistory,
  clearHistory,
  addFilesToPlaylist,
  addFolderToPlaylist,
  saveProgress,
  getProgress
} from './services/library'
import { cacheStats, clearCache, cancelConvert, prepareConversion, probePlayback, releasePlaybackCache } from './services/playbackCache'
import { VIDEO_EXTENSIONS } from '../shared/media'

export function registerIpc(): void {
  let activeAiRequest: string | null = null
  ipcMain.handle('pipeline:run', (event, videoPath: string, options: RunPipelineOptions) => {
    cancelStreaming()
    activeAiRequest = options.requestId
    return runPipeline(videoPath, options, (progress) => {
      if (activeAiRequest === options.requestId && !event.sender.isDestroyed()) {
        event.sender.send('pipeline:progress', { requestId: options.requestId, data: progress })
      }
    })
  })

  ipcMain.handle('pipeline:cancel', () => {
    activeAiRequest = null
    cancelPipeline()
  })

  ipcMain.handle('stream:start', (event, videoPath: string, options: RunPipelineOptions) => {
    cancelPipeline()
    activeAiRequest = options.requestId
    const send = (channel: string, data: unknown): void => {
      if (activeAiRequest === options.requestId && !event.sender.isDestroyed()) {
        event.sender.send(channel, { requestId: options.requestId, data })
      }
    }
    return startStreaming(videoPath, options, {
      onSegment: (segment) => {
        send('stream:segment', segment)
      },
      onProgress: (progress) => {
        send('stream:progress', progress)
      },
      onLog: (line) => {
        send('stream:log', line)
      }
    })
  })

  ipcMain.handle('stream:cancel', () => {
    activeAiRequest = null
    cancelStreaming()
  })

  ipcMain.handle('models:list', () => listModels())

  ipcMain.handle('models:download', (event, name: string) => {
    return downloadModel(name, (p) => {
      if (!event.sender.isDestroyed()) event.sender.send('models:progress', p)
    })
  })

  ipcMain.handle('subtitle:save', (_event, payload: SaveSubtitlesPayload) => {
    return saveSubtitles(payload)
  })

  ipcMain.handle('subtitle:load', (_event, videoPath: string) => {
    return loadSavedSubtitles(videoPath)
  })

  ipcMain.handle('subtitle:import', async (event, path?: string) => {
    if (!path) {
      const win = BrowserWindow.fromWebContents(event.sender)
      if (!win) return null
      const result = await dialog.showOpenDialog(win, {
        title: '导入字幕', properties: ['openFile'],
        filters: [{ name: '字幕文件', extensions: ['srt', 'vtt'] }]
      })
      if (result.canceled || !result.filePaths.length) return null
      path = result.filePaths[0]
    }
    return { path, segments: readSubtitleFile(path) }
  })

  ipcMain.handle('library:get', () => getLibrary())
  ipcMain.handle('library:add-playlist', (_e, path: string, title: string) => addToPlaylist(path, title))
  ipcMain.handle('library:remove-playlist', (_e, path: string) => removeFromPlaylist(path))
  ipcMain.handle('library:clear-playlist', () => clearPlaylist())
  ipcMain.handle('library:add-history', (_e, path: string, title: string) => addToHistory(path, title))
  ipcMain.handle('library:clear-history', () => clearHistory())

  ipcMain.handle('library:add-files', async (event) => {
    const win = BrowserWindow.fromWebContents(event.sender)
    if (!win) return null
    const { canceled, filePaths } = await dialog.showOpenDialog(win, {
      title: '选择视频文件（可多选）',
      properties: ['openFile', 'multiSelections'],
      filters: [
        {
          name: '视频文件',
          extensions: VIDEO_EXTENSIONS
        },
        { name: '所有文件', extensions: ['*'] }
      ]
    })
    if (canceled || filePaths.length === 0) return null
    return addFilesToPlaylist(filePaths)
  })

  ipcMain.handle('library:add-folder', async (event) => {
    const win = BrowserWindow.fromWebContents(event.sender)
    if (!win) return null
    const { canceled, filePaths } = await dialog.showOpenDialog(win, {
      title: '选择视频文件夹（会递归扫描子文件夹）',
      properties: ['openDirectory']
    })
    if (canceled || filePaths.length === 0) return null
    return addFolderToPlaylist(filePaths[0])
  })

  ipcMain.handle('library:save-progress', (_e, path: string, seconds: number) => {
    saveProgress(path, seconds)
  })

  ipcMain.handle('library:get-progress', (_e, path: string) => getProgress(path))

  ipcMain.handle('llm:translate', async (event, payload: { lines: string[]; srcLang: string; context?: string[] }) => {
    const server = await getLlmServer((line) => {
      if (!event.sender.isDestroyed()) event.sender.send('llm:log', line)
    })
    return server.translate(payload.lines, { srcLang: payload.srcLang, context: payload.context })
  })

  ipcMain.handle('llm:status', () => ({
    modelExists: llmModelExists(),
    running: isLlmRunning()
  }))

  ipcMain.handle('llm:download', (event) => {
    return downloadLlmModel((p) => {
      if (!event.sender.isDestroyed()) event.sender.send('models:progress', p)
    })
  })

  ipcMain.handle('media:probe', (_event, videoPath: string) => {
    return probePlayback(videoPath)
  })

  ipcMain.handle('cache:stats', () => cacheStats())
  ipcMain.handle('cache:clear', () => clearCache())

  ipcMain.handle('media:convert-cancel', (_event, releasePlayback = false) => {
    cancelConvert()
    if (releasePlayback) releasePlaybackCache()
  })

  ipcMain.handle('media:remux', (event, videoPath: string, transcodeAudio = false) => {
    return prepareConversion(videoPath, transcodeAudio ? 'audio' : 'remux', ({ data }) => {
      if (!event.sender.isDestroyed()) event.sender.send('remux:log', { data, sourcePath: videoPath, ext: extname(videoPath) })
    })
  })

  ipcMain.handle('media:transcode', (event, videoPath: string) => {
    return prepareConversion(videoPath, 'transcode', ({ data }) => {
      if (!event.sender.isDestroyed()) event.sender.send('transcode:log', { data, sourcePath: videoPath, ext: extname(videoPath) })
    })
  })

  ipcMain.handle('dialog:openVideo', async (event) => {
    const win = BrowserWindow.fromWebContents(event.sender)
    if (!win) return null
    const { canceled, filePaths } = await dialog.showOpenDialog(win, {
      title: '选择视频文件',
      properties: ['openFile'],
      filters: [
        { name: '视频文件', extensions: VIDEO_EXTENSIONS },
        { name: '所有文件', extensions: ['*'] }
      ]
    })
    if (canceled || filePaths.length === 0) return null
    return filePaths[0]
  })
}
