import { app, shell, BrowserWindow, protocol } from 'electron'
import { join } from 'node:path'
import { existsSync, cpSync } from 'node:fs'
import { registerIpc } from './ipc'
import { ensureDirs } from './services/paths'
import { mediaHandler } from './services/mediaProtocol'
import { cancelConvert } from './services/playbackCache'

/** 旧版本 productName 为 LocalAIVideoPlayer，改名后把已下载的模型迁移过来 */
function migrateOldModels(): void {
  try {
    const appData = app.getPath('appData')
    const oldModels = join(appData, 'LocalAIVideoPlayer', 'models')
    const newModels = join(appData, 'AIVideoPlayer', 'models')
    if (existsSync(oldModels) && !existsSync(newModels)) {
      cpSync(oldModels, newModels, { recursive: true })
      console.log('已迁移旧模型目录：', oldModels, '->', newModels)
    }
  } catch (err) {
    console.warn('模型迁移失败（忽略）：', err)
  }
}

// 允许无用户手势自动播放（本地媒体播放器场景）
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')

// 注册自定义 media:// 协议（用于「打开文件」场景的视频流式播放，支持 Range 拖动）
protocol.registerSchemesAsPrivileged([
  {
    scheme: 'media',
    privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true }
  }
])

function createWindow(): void {
  const win = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 940,
    minHeight: 600,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#0f1115',
    title: 'AIVideoPlayer',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
      contextIsolation: true,
      nodeIntegration: false
    }
  })

  win.on('closed', cancelConvert)
  win.on('ready-to-show', () => win.show())
  win.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url)
    return { action: 'deny' }
  })

  if (process.env['ELECTRON_RENDERER_URL']) {
    win.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    win.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

app.whenReady().then(() => {
  migrateOldModels()
  ensureDirs()
  protocol.handle('media', mediaHandler)
  registerIpc()
  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', cancelConvert)
