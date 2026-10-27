<script setup lang="ts">
import type { ModelProgress, WhisperModelInfo } from '@shared/types'

defineProps<{
  models: WhisperModelInfo[]
  selectedModel: string
  mode: 'stream' | 'batch'
  running: boolean
  translating: boolean
  detectedLanguage: string | null
  downloadState: ModelProgress | null
  llmModelReady: boolean
}>()

const emit = defineEmits<{
  (e: 'update:selectedModel', v: string): void
  (e: 'update:mode', v: 'stream' | 'batch'): void
  (e: 'download', name: string): void
  (e: 'downloadLlm'): void
}>()

const LANG_LABEL: Record<string, string> = { ja: '日语', en: '英语', auto: '自动' }
</script>

<template>
  <div class="control-panel">
    <h3>识别与翻译</h3>
    <div class="field">
      <label>识别模式</label>
      <div class="seg">
        <button
          class="seg-btn"
          :class="{ active: mode === 'batch' }"
          :disabled="running"
          @click="emit('update:mode', 'batch')"
        >
          整片批量
        </button>
        <button
          class="seg-btn"
          :class="{ active: mode === 'stream' }"
          :disabled="running"
          @click="emit('update:mode', 'stream')"
        >
          流式实时
        </button>
      </div>
    </div>

    <div class="field">
      <label>Whisper 模型</label>
      <select
        :value="selectedModel"
        :disabled="running || translating"
        @change="emit('update:selectedModel', ($event.target as HTMLSelectElement).value)"
      >
        <option v-for="m in models" :key="m.name" :value="m.name">
          {{ m.label }}（{{ m.sizeMb }}MB）{{ m.installed ? '✓' : '· 未下载' }}
        </option>
      </select>
      <button
        v-if="!models.find((m) => m.name === selectedModel)?.installed"
        class="mini"
        :disabled="running || translating || !!downloadState"
        @click="emit('download', selectedModel)"
      >
        下载模型
      </button>
    </div>

    <div class="field">
      <label>字幕语言</label>
      <span class="tag lang-fixed">简体中文</span>
      <span v-if="detectedLanguage" class="tag">
        原声：{{ LANG_LABEL[detectedLanguage] ?? detectedLanguage }}
      </span>
    </div>

    <div class="field">
      <label>翻译引擎</label>
      <span class="tag" :class="llmModelReady ? '' : 'lang-warn'">Qwen2.5-7B</span>
      <button
        v-if="!llmModelReady"
        class="mini"
        :disabled="running || translating || !!downloadState"
        @click="emit('downloadLlm')"
      >
        下载翻译模型（4.4GB）
      </button>
    </div>
    <p v-if="downloadState" class="download-progress">正在下载 {{ downloadState.name }} · {{ downloadState.percent }}%</p>
  </div>
</template>

<style scoped>
.control-panel {
  display: flex;
  flex-direction: column;
  gap: 16px;
  align-items: stretch;
  padding: 22px 0;
  background: var(--bg-panel);

}
.field {
  display: flex;
  align-items: center;
  gap: 8px;
}
.field { justify-content: space-between; flex-wrap: wrap; }
h3 { margin: 0; font-size: 12px; font-weight: 500; color: var(--text-dim); }
.field label {
  font-size: 13px;
  color: var(--text-dim);
  white-space: nowrap;
}
.tag {
  font-size: 12px;
  color: var(--ok);
  background: rgba(56, 193, 114, 0.12);
  padding: 3px 8px;
  border-radius: 6px;
}
.tag.lang-fixed {
  color: var(--accent);
  background: rgba(79, 140, 255, 0.14);
}
.tag.lang-warn {
  color: var(--danger);
  background: rgba(255, 92, 108, 0.12);
}
.mini {
  padding: 7px 10px;
  font-size: 12px;
}
.seg {
  display: flex;
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: hidden;
}
.seg-btn {
  border: none;
  border-radius: 0;
  padding: 7px 12px;
  background: var(--bg-elevated);
  color: var(--text-dim);
}
.seg-btn.active {
  background: var(--accent);
  color: #fff;
}
.seg-btn + .seg-btn {
  border-left: 1px solid var(--border);
}
</style>
