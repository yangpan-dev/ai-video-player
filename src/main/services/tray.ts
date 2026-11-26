import { app, Menu, Notification, Tray, nativeImage, type NativeImage } from 'electron'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

let tray: Tray | null = null
let trayIcon: NativeImage | null = null

/** 托盘图标：打包后取渲染进程资源里的应用图标，开发时用 build/icon.png */
function loadTrayIcon(): NativeImage {
  if (trayIcon) return trayIcon
  const candidates = [
    join(__dirname, '../renderer/app-icon.png'),
    join(app.getAppPath(), 'build/icon.png'),
    join(process.resourcesPath, 'app-icon.png')
  ]
  for (const file of candidates) {
    if (!existsSync(file)) continue
    const image = nativeImage.createFromPath(file)
    if (!image.isEmpty()) {
      trayIcon = image.resize({ width: 16, height: 16 })
      return trayIcon
    }
  }
  return nativeImage.createEmpty()
}

export function isTrayActive(): boolean {
  return tray !== null
}

/** 创建系统托盘图标（重复调用不会创建多个） */
export function ensureTray(actions: { show: () => void; quit: () => void }): Tray {
  if (tray) return tray
  const icon = loadTrayIcon()
  tray = new Tray(icon)
  tray.setToolTip('熊猫播放器')
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: '显示主窗口', click: () => actions.show() },
      { type: 'separator' },
      { label: '退出熊猫播放器', click: () => actions.quit() }
    ])
  )
  tray.on('click', () => actions.show())
  tray.on('double-click', () => actions.show())
  return tray
}

export function destroyTray(): void {
  if (!tray) return
  tray.destroy()
  tray = null
}

/** 首次缩到托盘时提示一下，避免用户以为程序被关掉了 */
export function showTrayHint(): void {
  const title = '熊猫播放器仍在运行'
  const body = '已最小化到系统托盘，双击托盘图标可以重新打开。'
  if (process.platform === 'win32' && tray) {
    try {
      tray.displayBalloon({ title, content: body, icon: loadTrayIcon() })
      return
    } catch {
      /* 气泡提示不可用时退回系统通知 */
    }
  }
  try {
    if (Notification.isSupported()) new Notification({ title, body }).show()
  } catch {
    /* 通知不可用时静默忽略，不影响关闭流程 */
  }
}
