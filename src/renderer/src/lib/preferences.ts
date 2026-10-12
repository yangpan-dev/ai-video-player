import { reactive, watch } from 'vue'
import { normalizePreferences, PREFERENCES_KEY } from '@shared/playerPreferences'

function read(): unknown {
  try { return JSON.parse(localStorage.getItem(PREFERENCES_KEY) ?? 'null') } catch { return null }
}

// 单个共享实例：切片、转码回退、组件重建也会保留设置。
export const playerPreferences = reactive(normalizePreferences(read()))
watch(playerPreferences, (value) => {
  try { localStorage.setItem(PREFERENCES_KEY, JSON.stringify(value)) } catch { /* 存储不可用时仍可播放 */ }
}, { deep: true })
