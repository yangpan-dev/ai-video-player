import { app } from 'electron'
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { normalizeAppSettings, type AppSettings, type CloseAction } from '@shared/appSettings'

let cache: AppSettings | null = null

function settingsFile(): string {
  return join(app.getPath('userData'), 'app-settings.json')
}

/** 读取应用设置（带内存缓存，读失败时回退到默认值） */
export function getAppSettings(): AppSettings {
  if (cache) return cache
  try {
    cache = normalizeAppSettings(JSON.parse(readFileSync(settingsFile(), 'utf8')))
  } catch {
    cache = normalizeAppSettings(null)
  }
  return cache
}

/** 合并写入设置；先写临时文件再重命名，避免写一半断电留下坏 JSON */
export function updateAppSettings(patch: Partial<AppSettings>): AppSettings {
  const next = normalizeAppSettings({ ...getAppSettings(), ...patch })
  cache = next
  try {
    const target = settingsFile()
    mkdirSync(dirname(target), { recursive: true })
    const temp = `${target}.tmp`
    writeFileSync(temp, `${JSON.stringify(next, null, 2)}\n`, 'utf8')
    renameSync(temp, target)
  } catch (err) {
    console.warn('保存应用设置失败（忽略）：', err)
  }
  return next
}

/** 设置「关闭主窗口时」的行为，并作为下次的默认选项 */
export function setCloseAction(action: CloseAction): AppSettings {
  return updateAppSettings({ closeAction: action })
}
