<script setup lang="ts">
import appIcon from '../assets/app-icon.png'
defineEmits<{ (e: 'browse'): void }>()
</script>

<template>
  <div class="dropzone">
    <div class="dropzone-inner">
      <img :src="appIcon" class="dropzone-icon" alt="熊猫播放器图标" />
      <h1>熊猫播放器</h1>
      <p class="hint">拖入视频或文件夹即可开始</p>
      <p class="sub">本地播放 · AI 双语字幕</p>
      <button class="primary" @click="$emit('browse')">打开视频</button>
    </div>
  </div>
</template>

<style scoped>
.dropzone {
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
}
.dropzone-inner {
  text-align: center;
  max-width: 460px;
  padding: 40px;

  border-radius: 16px;

}
.dropzone-icon {
  width: 112px;
  height: 112px;
  margin-bottom: 12px;
}
h1 {
  font-size: 22px;
  margin: 0 0 12px;
}
.hint {
  font-size: 16px;
  color: var(--text);
  margin: 0 0 6px;
}
.sub {
  font-size: 13px;
  color: var(--text-dim);
  margin: 0 0 24px;
}
</style>
