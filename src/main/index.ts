import { app, shell, BrowserWindow, protocol, dialog } from 'electron'
import { join } from 'node:path'
import { existsSync, cpSync } from 'node:fs'
import { registerIpc } from './ipc'
import { ensureDirs } from './services/paths'
import { pruneCheckpoints } from './services/checkpoint'
import { flushStreamingCheckpoint } from './services/streaming'
import { mediaHandler } from './services/mediaProtocol'
import { cancelConvert } from './services/playbackCache'
import { cancelPipeline } from './services/pipeline'
import { cancelStreaming } from './services/streaming'
import { stopLlmServer } from './services/llm'
import { getAppSettings, updateAppSettings } from './services/appSettings'
import { ensureTray, showTrayHint } from './services/tray'

let mainWindow: BrowserWindow | null = null
/** 真正退出中：此时不再拦截窗口关闭 */
let isQuitting = false
/** 窗口按「直接退出」关掉后，需要顺带结束进程（macOS 默认不退出） */
let shouldExitOnClose = false
/** 询问框已经打开，避免连点关闭按钮弹出多个对话框 */
let closePrompting = false

function stopBackgroundWork(): void {
  cancelConvert()
  cancelPipeline()
  cancelStreaming()
  stopLlmServer()
}

/** 旧版本 productName 为 LocalAIVideoPlayer，改名后把已下载的模型迁移过来 */
function migrateOldModels(): void {
  try {
    const appData = app.getPath('appData')
    const oldModels = join(appData, 'LocalAIVideoPlayer', 'models')
    const newModels = join(app.getPath('userData'), 'models')
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

/** 退出应用：先标记，避免关闭窗口时又被拦下来 */
function quitApp(): void {
  isQuitting = true
  app.quit()
}

/** 从托盘/二次启动恢复主窗口 */
function showMainWindow(): void {
  if (!mainWindow || mainWindow.isDestroyed()) {
    createWindow()
    return
  }
  if (mainWindow.isMinimized()) mainWindow.restore()
  if (!mainWindow.isVisible()) mainWindow.show()
  mainWindow.focus()
}

/** 隐藏到系统托盘，同时保证托盘图标存在 */
function hideToTray(win: BrowserWindow): void {
  ensureTray({ show: showMainWindow, quit: quitApp })
  if (win.isFullScreen()) win.setFullScreen(false)
  win.hide()
  if (!getAppSettings().trayHintShown) {
    showTrayHint()
    updateAppSettings({ trayHintShown: true })
  }
}

/** closeAction = ask 时的选择框；勾选「记住」就把选择存为下次的默认值 */
async function promptCloseAction(win: BrowserWindow): Promise<void> {
  if (closePrompting) return
  closePrompting = true
  try {
    const { response, checkboxChecked } = await dialog.showMessageBox(win, {
      type: 'question',
      buttons: ['最小化到托盘', '直接退出', '取消'],
      defaultId: 0,
      cancelId: 2,
      noLink: true,
      title: '关闭熊猫播放器',
      message: '关闭主窗口后要怎么做？',
      detail: '最小化到系统托盘时程序继续在后台运行，下载与识别不会中断。\n可以在「设置 → 应用」里修改这个默认行为。',
      checkboxLabel: '记住我的选择，下次不再询问',
      checkboxChecked: false
    })
    if (response === 2) return
    const action = response === 1 ? 'quit' : 'tray'
    if (checkboxChecked) updateAppSettings({ closeAction: action })
    if (action === 'quit') quitApp()
    else if (!win.isDestroyed()) hideToTray(win)
  } catch (err) {
    console.warn('关闭确认框失败（忽略）：', err)
  } finally {
    closePrompting = false
  }
}

function createWindow(): void {
  const win = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 940,
    minHeight: 600,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#0f1115',
    title: '熊猫播放器',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
      contextIsolation: true,
      nodeIntegration: false
    }
  })
  mainWindow = win

  // 关闭窗口：按设置决定「直接退出」还是「托管到托盘」
  win.on('close', (event) => {
    if (isQuitting) return
    const { closeAction } = getAppSettings()
    if (closeAction === 'quit') {
      isQuitting = true
      shouldExitOnClose = true
      return
    }
    event.preventDefault()
    if (closeAction === 'tray') hideToTray(win)
    else void promptCloseAction(win)
  })

  win.on('closed', () => {
    if (mainWindow === win) mainWindow = null
    stopBackgroundWork()
    // macOS 关掉窗口默认不退出应用，这里按「直接退出」的语义补齐
    if (shouldExitOnClose || (process.platform === 'darwin' && !isQuitting)) app.quit()
  })
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

// Keep the existing profile, model downloads and localStorage when changing the display name.
const existingProfile = app.getPath('userData')
app.setName('熊猫播放器')
app.setPath('userData', existingProfile)

// 单实例：托盘驻留时再次双击图标只唤起已有窗口，而不是启动第二个程序
const hasSingleInstanceLock = app.requestSingleInstanceLock()
if (!hasSingleInstanceLock) {
  app.quit()
} else {
  app.on('second-instance', () => showMainWindow())

  app.whenReady().then(() => {
    // Windows 通知（托盘气泡/系统通知）需要 AUMID
    app.setAppUserModelId('com.example.local-ai-video-player')
    const icon = app.isPackaged ? join(__dirname, '../renderer/app-icon.png') : join(app.getAppPath(), 'build/icon.png')
    if (process.platform === 'darwin' && app.dock && existsSync(icon)) app.dock.setIcon(icon)
    migrateOldModels()
    ensureDirs()
    pruneCheckpoints()
    protocol.handle('media', mediaHandler)
    registerIpc()
    createWindow()

    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow()
      else showMainWindow()
    })
  })

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit()
  })

  // 退出前把流式识别的进度同步写入断点，避免“关了应用就白做”
  app.on('before-quit', () => {
    isQuitting = true
    flushStreamingCheckpoint()
    stopBackgroundWork()
  })
}
