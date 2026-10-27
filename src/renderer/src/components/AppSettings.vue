<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { playerPreferences as prefs } from '../lib/preferences'
import AppIcon from './AppIcon.vue'

defineProps<{ cacheSize: string; cacheDisabled: boolean; sortByName: boolean }>()
const emit = defineEmits<{
  (e: 'close'): void
  (e: 'clearCache'): void
  (e: 'toggleMinimal'): void
  (e: 'update:sortByName', value: boolean): void
}>()
const dialog = ref<HTMLDialogElement | null>(null)
const tab = ref('ai')
onMounted(() => dialog.value?.showModal())
</script>

<template>
  <dialog ref="dialog" class="app-settings" aria-labelledby="settings-title" @cancel="emit('close')" @close="emit('close')" @click="($event.target === dialog) && emit('close')">
    <header><h2 id="settings-title">设置</h2><button autofocus class="quiet-icon" title="关闭设置（Esc）" aria-label="关闭设置" @click="emit('close')"><AppIcon name="close" /></button></header>
    <nav aria-label="设置分类">
      <button v-for="item in [{ id: 'ai', title: '字幕与 AI' }, { id: 'picture', title: '画面与声音' }, { id: 'playback', title: '播放' }]" :key="item.id" :class="{ active: tab === item.id }" :aria-pressed="tab === item.id" @click="tab = item.id">{{ item.title }}</button>
    </nav>
    <div class="settings-content">
      <div v-show="tab === 'ai'">
        <slot />
        <section>
          <h3>字幕显示</h3>
          <label>显示方式<select v-model="prefs.subtitleMode"><option value="bilingual">双语</option><option value="original">原文</option><option value="translation">中文</option><option value="off">关闭</option></select></label>
          <label>字号 <span><input v-model.number="prefs.fontSize" type="range" min="12" max="48" />{{ prefs.fontSize }} px</span></label>
          <label>垂直位置 <span><input v-model.number="prefs.bottomMargin" type="range" min="20" max="220" step="2" />{{ prefs.bottomMargin }} px</span></label>
          <label>字幕时间偏移 <span><input v-model.number="prefs.subtitleOffset" type="number" min="-60" max="60" step="0.5" />秒<button @click="prefs.subtitleOffset = 0">重置</button></span></label>
        </section>
      </div>
      <section v-if="tab === 'picture'">
        <h3>画面与声音</h3>
        <label>亮度 <span><input v-model.number="prefs.brightness" type="range" min="0.4" max="1.6" step="0.05" />{{ Math.round(prefs.brightness * 100) }}%</span></label>
        <label>音量 <span><input v-model.number="prefs.volume" type="range" min="0" max="1" step="0.05" />{{ Math.round(prefs.volume * 100) }}%</span></label>
        <label>静音<input v-model="prefs.muted" type="checkbox" /></label>
        <button @click="prefs.brightness = 1">恢复原始亮度</button>
      </section>
      <template v-if="tab === 'playback'">
        <section>
          <h3>播放偏好</h3>
          <label>播放速度<select v-model.number="prefs.playbackRate" aria-label="播放速度"><option v-for="r in [0.5, 0.75, 1, 1.25, 1.5, 2]" :key="r" :value="r">{{ r }}×</option></select></label>
          <label>自动播放下一个<input v-model="prefs.autoNext" type="checkbox" aria-label="自动播放下一个" /></label>
          <label>播放列表按名称排序<input :checked="sortByName" type="checkbox" @change="emit('update:sortByName', ($event.target as HTMLInputElement).checked)" /></label>
          <label>专注观影<button @click="emit('toggleMinimal')">进入精简模式</button></label>
        </section>
        <section><h3>存储与维护</h3><label>转换缓存 · {{ cacheSize }}<button :disabled="cacheDisabled" @click="emit('clearCache')">清理缓存</button></label></section>
        <section class="shortcuts"><h3>快捷键</h3><p>空格 播放 / 暂停 · ← → 快进 / 后退 · ↑ ↓ 音量</p><p>F 全屏 · V 静音 · P / N 上一个 / 下一个</p><p>[ / ] 字幕同步 · M 精简模式 · Esc 退出精简模式</p><p>⌘ / Ctrl + O 打开视频 · ⌘ / Ctrl + , 设置</p></section>
      </template>
    </div>
  </dialog>
</template>

<style scoped>
.app-settings { width: min(600px, calc(100vw - 48px)); max-height: calc(100vh - 64px); padding: 0; color: var(--text); background: var(--bg-panel); border: 1px solid var(--border); border-radius: 16px; box-shadow: 0 24px 100px #0009; }
.app-settings::backdrop { background: #0008; backdrop-filter: blur(5px); }
header { display: flex; align-items: center; justify-content: space-between; padding: 20px 24px 16px; }
h2 { margin: 0; font-size: 18px; font-weight: 600; }
nav { display: flex; gap: 4px; margin: 0 24px 20px; padding: 4px; background: var(--bg); border-radius: 10px; }
nav button { flex: 1; border: 0; background: transparent; color: var(--text-dim); }
nav button.active { color: var(--text); background: var(--bg-elevated); }
.settings-content { padding: 0 24px 24px; border-top: 1px solid var(--border); }
section { padding-top: 22px; }
h3 { font-size: 12px; font-weight: 500; color: var(--text-dim); margin: 0 0 10px; }
label { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 12px 0; font-size: 13px; border-bottom: 1px solid #ffffff08; }
label span { display: flex; align-items: center; gap: 10px; color: var(--text-dim); font-size: 12px; }
input[type='range'] { width: 145px; accent-color: var(--accent); }
input[type='number'] { width: 70px; padding: 7px; background: var(--bg-elevated); border: 1px solid var(--border); border-radius: 7px; color: var(--text); }
input[type='checkbox'] { accent-color: var(--accent); }
.shortcuts p { color: var(--text-dim); font-size: 12px; line-height: 1.6; }
</style>
