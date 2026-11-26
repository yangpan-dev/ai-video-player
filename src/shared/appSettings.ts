/**
 * 应用级设置（主进程持有，持久化到 userData/app-settings.json）。
 * 与播放器偏好（localStorage）区分：这些设置决定了主进程的行为。
 */

/** 关闭主窗口时的行为 */
export type CloseAction = 'ask' | 'quit' | 'tray'

export interface AppSettings {
  /** ask=每次询问 / quit=直接退出 / tray=最小化到系统托盘 */
  closeAction: CloseAction
  /** 是否已经提示过「程序仍在托盘运行」（只提示一次） */
  trayHintShown: boolean
}

export const CLOSE_ACTION_OPTIONS: { value: CloseAction; label: string; hint: string }[] = [
  { value: 'ask', label: '每次询问', hint: '关闭窗口时弹出选择框，可勾选「记住我的选择」。' },
  { value: 'tray', label: '最小化到系统托盘', hint: '窗口隐藏，下载与识别任务继续在后台运行，双击托盘图标可重新打开。' },
  { value: 'quit', label: '直接退出', hint: '关闭窗口即结束程序，未完成的识别会保留断点，下次可继续。' }
]

export function normalizeAppSettings(value: unknown): AppSettings {
  const source = value && typeof value === 'object' ? (value as Partial<AppSettings>) : {}
  const closeAction: CloseAction =
    source.closeAction === 'quit' || source.closeAction === 'tray' ? source.closeAction : 'ask'
  return {
    closeAction,
    trayHintShown: source.trayHintShown === true
  }
}
