<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, toRefs, watch } from 'vue'
import type { SubtitleSegment } from '@shared/types'
import SubtitleOverlay from './SubtitleOverlay.vue'
import { playerPreferences } from '../lib/preferences'

const props = defineProps<{
  src: string | null
  segments: SubtitleSegment[]
  title?: string
  initialTime?: number
  autoplay?: boolean
  minimal?: boolean
  hasPrevious?: boolean
  hasNext?: boolean
  settingsOpen?: boolean
}>()

const emit = defineEmits<{
  (e: 'error', detail: { message: string; code: number; src: string | null }): void
  (e: 'time', t: number): void
  (e: 'toggleMinimal'): void
  (e: 'previous'): void
  (e: 'next'): void
  (e: 'ended'): void
  (e: 'pause'): void
  (e: 'settings'): void
}>()

const videoEl = ref<HTMLVideoElement | null>(null)
const seekBarEl = ref<HTMLDivElement | null>(null)
const playerEl = ref<HTMLDivElement | null>(null)

const currentTime = ref(0)
const duration = ref(0)
const isPlaying = ref(false)
const { volume, muted, brightness, playbackRate, subtitleMode, fontSize, bottomMargin, subtitleOffset } = toRefs(playerPreferences)

// ---- 字幕设置（PotPlayer 风格）----


// ---- UI 状态（IINA 风格）----
const controlsVisible = ref(false)
const osd = ref<string | null>(null)
const minimalBarVisible = ref(false)
const cursorHidden = ref(false)

let hideTimer: ReturnType<typeof setTimeout> | null = null
let osdTimer: ReturnType<typeof setTimeout> | null = null
let minimalHideTimer: ReturnType<typeof setTimeout> | null = null
let cursorHideTimer: ReturnType<typeof setTimeout> | null = null

watch(
  () => props.src,
  () => {
    currentTime.value = 0
    duration.value = 0
    isPlaying.value = false
  }
)
watch(playbackRate, (rate) => { if (videoEl.value) videoEl.value.playbackRate = rate })
watch(volume, (v) => {
  if (videoEl.value) videoEl.value.volume = v
})
watch(muted, (v) => { if (videoEl.value) videoEl.value.muted = v })
// 进度 / 自动播放可能在 src 挂载后才异步就绪，用 watch 兜底
watch(
  () => props.initialTime,
  (t) => applyInitialTime(t)
)
watch(
  () => props.autoplay,
  (a) => {
    if (a) maybePlay()
  }
)

function onTimeUpdate(): void {
  if (videoEl.value) {
    currentTime.value = videoEl.value.currentTime
    emit('time', videoEl.value.currentTime)
  }
}
function applyInitialTime(t: number | undefined): void {
  const v = videoEl.value
  if (!v || !t || t <= 0) return
  if (v.duration > 0 && t < v.duration) {
    const resume = t / v.duration >= 0.98 ? 0 : t
    v.currentTime = resume
    currentTime.value = resume
  }
}

function maybePlay(): void {
  const v = videoEl.value
  if (!v || !props.autoplay) return
  if (v.readyState >= 1 && v.paused) {
    v.play().catch(() => {
      /* 自动播放被拒绝时保持暂停态，图标由 onPause 正确回退 */
    })
  }
}

function onLoadedMetadata(): void {
  if (videoEl.value) {
    duration.value = videoEl.value.duration || 0
    videoEl.value.volume = volume.value
    videoEl.value.muted = muted.value
    videoEl.value.playbackRate = playbackRate.value
    // 恢复上次播放进度；若要求自动播放则在就绪后开始
    applyInitialTime(props.initialTime)
    maybePlay()
  }
}
function onPlay(): void {
  isPlaying.value = true
}
function onPause(): void {
  isPlaying.value = false
  emit('pause')
}
function toggleMute(): void {
  muted.value = !muted.value
  showOsd(muted.value ? '已静音' : '已恢复声音')
}
function onError(): void {
  const code = videoEl.value?.error?.code ?? 0
  if (!props.src || code === 1) return
  const message = code === 2 ? '视频读取失败，请检查文件是否仍可访问' : '当前设备无法解码该视频或音轨'
  emit('error', { message, code, src: props.src })
}

function togglePlay(): void {
  const v = videoEl.value
  if (!v) return
  if (v.paused) void v.play().catch(() => { if (v.error) onError() })
  else v.pause()
}

function toggleFullscreen(): void {
  if (document.fullscreenElement) {
    void document.exitFullscreen()
  } else {
    void playerEl.value?.requestFullscreen()
  }
}

function clearCursorHideTimer(): void {
  if (cursorHideTimer) clearTimeout(cursorHideTimer)
  cursorHideTimer = null
}

function onFullscreenChange(): void {
  clearCursorHideTimer()
  cursorHidden.value = document.fullscreenElement === playerEl.value
}

// 单击画面 = 播放/暂停；双击 = 全屏（用延时区分单击和双击）
let clickTimer: ReturnType<typeof setTimeout> | null = null
function onVideoClick(): void {
  if (clickTimer) {
    clearTimeout(clickTimer)
    clickTimer = null
    toggleFullscreen()
    return
  }
  clickTimer = setTimeout(() => {
    clickTimer = null
    togglePlay()
  }, 250)
}

function seekBy(delta: number): void {
  const v = videoEl.value
  if (!v) return
  const t = Math.max(0, Math.min(v.duration || 0, v.currentTime + delta))
  v.currentTime = t
  currentTime.value = t
  showOsd((delta >= 0 ? '+' : '') + delta + 's')
}

function seekTo(t: number): void {
  const v = videoEl.value
  if (!v) return
  const clamped = Math.max(0, Math.min(v.duration || 0, t))
  v.currentTime = clamped
  currentTime.value = clamped
}

function adjustSubtitle(delta: number): void {
  subtitleOffset.value = Math.round((subtitleOffset.value + delta) * 10) / 10
  const off = subtitleOffset.value
  showOsd('字幕' + (off >= 0 ? `延迟 +${off.toFixed(1)}s` : `提前 ${off.toFixed(1)}s`))
}

function showOsd(text: string): void {
  osd.value = text
  if (osdTimer) clearTimeout(osdTimer)
  osdTimer = setTimeout(() => {
    osd.value = null
  }, 1500)
}

function pokeControls(): void {
  controlsVisible.value = true
  if (hideTimer) clearTimeout(hideTimer)
  hideTimer = setTimeout(() => {
    if (!props.settingsOpen) controlsVisible.value = false
  }, 2600)
}

// 精简模式：鼠标移动唤出临时控制条（右上角「还原」），静止后自动隐藏
function pokeMinimal(): void {
  if (!props.minimal) return
  minimalBarVisible.value = true
  if (minimalHideTimer) clearTimeout(minimalHideTimer)
  minimalHideTimer = setTimeout(() => {
    minimalBarVisible.value = false
  }, 2600)
}

function onPlayerMouseMove(): void {
  clearCursorHideTimer()
  cursorHidden.value = false
  if (document.fullscreenElement === playerEl.value) {
    cursorHideTimer = setTimeout(() => {
      cursorHideTimer = null
      cursorHidden.value = true
    }, 2600)
  }
  pokeControls()
  pokeMinimal()
}

function onPlayerMouseLeave(): void {
  clearCursorHideTimer()
  cursorHidden.value = document.fullscreenElement === playerEl.value
  controlsVisible.value = false
  minimalBarVisible.value = false
}

// ---- 进度条拖拽 ----
let seeking = false
function onSeekDown(e: PointerEvent): void {
  seeking = true
  seekBarEl.value?.setPointerCapture(e.pointerId)
  doSeek(e)
}
function onSeekMove(e: PointerEvent): void {
  if (seeking) doSeek(e)
}
function onSeekUp(e: PointerEvent): void {
  if (seeking) {
    seeking = false
    seekBarEl.value?.releasePointerCapture(e.pointerId)
  }
}
function doSeek(e: PointerEvent): void {
  const el = seekBarEl.value
  const v = videoEl.value
  if (!el || !v || !v.duration) return
  const rect = el.getBoundingClientRect()
  const frac = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
  seekTo(frac * v.duration)
}

// ---- 当前字幕（含延迟偏移）----
const activeTime = computed(() => currentTime.value - subtitleOffset.value)
const active = computed(() => findActive(activeTime.value))

function findActive(t: number): SubtitleSegment | null {
  const segs = props.segments
  if (!segs.length || t < 0) return null
  let lo = 0
  let hi = segs.length - 1
  let ans = -1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (segs[mid].start <= t) {
      ans = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  if (ans === -1) return null
  const s = segs[ans]
  return t < s.end ? s : null
}

const progress = computed(() => (duration.value > 0 ? (currentTime.value / duration.value) * 100 : 0))
// 音量/亮度滑块填充百分比（用于画出与播放进度一致的细进度条）
const volumeFill = computed(() => `${(volume.value * 100).toFixed(0)}%`)
function fmtTime(s: number): string {
  if (!isFinite(s) || s < 0) s = 0
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = Math.floor(s % 60)
  const mm = String(m).padStart(2, '0')
  const ss = String(sec).padStart(2, '0')
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`
}

// ---- 键盘快捷键（IINA / PotPlayer 习惯）----
function onKeydown(e: KeyboardEvent): void {
  if (props.settingsOpen) return
  if (e.target instanceof HTMLElement && (e.target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT', 'BUTTON'].includes(e.target.tagName))) return
  if (e.ctrlKey || e.metaKey || e.altKey) return
  switch (e.key) {
    case ' ':
      e.preventDefault()
      togglePlay()
      break
    case 'ArrowLeft':
      e.preventDefault()
      seekBy(e.shiftKey ? -30 : -5)
      break
    case 'ArrowRight':
      e.preventDefault()
      seekBy(e.shiftKey ? 30 : 5)
      break
    case 'ArrowUp':
    case 'ArrowDown':
      e.preventDefault()
      volume.value = Math.min(1, Math.max(0, volume.value + (e.key === 'ArrowUp' ? 0.05 : -0.05)))
      muted.value = false
      showOsd('音量 ' + Math.round(volume.value * 100) + '%')
      break
    case 'f':
    case 'F':
      toggleFullscreen()
      break
    case 'v':
    case 'V':
      toggleMute()
      break
    case 'n':
    case 'N':
      if (props.hasNext) emit('next')
      break
    case 'p':
    case 'P':
      if (props.hasPrevious) emit('previous')
      break
    case '[':
      adjustSubtitle(-0.5)
      break
    case ']':
      adjustSubtitle(0.5)
      break
  }
}

onMounted(() => {
  window.addEventListener('keydown', onKeydown)
  document.addEventListener('fullscreenchange', onFullscreenChange)
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKeydown)
  document.removeEventListener('fullscreenchange', onFullscreenChange)
  clearCursorHideTimer()
  if (hideTimer) clearTimeout(hideTimer)
  if (osdTimer) clearTimeout(osdTimer)
  if (minimalHideTimer) clearTimeout(minimalHideTimer)
  if (clickTimer) clearTimeout(clickTimer)
})
</script>

<template>
  <div
    ref="playerEl"
    class="player"
    :class="{ 'hide-cursor': cursorHidden }"
    @mousemove="onPlayerMouseMove"
    @mouseleave="onPlayerMouseLeave"
  >
    <video
      ref="videoEl"
      class="video"
      :src="src ?? undefined"
      :style="{ filter: `brightness(${brightness})` }"
      @timeupdate="onTimeUpdate"
      @loadedmetadata="onLoadedMetadata"
      @play="onPlay"
      @pause="onPause"
      @ended="emit('ended')"
      @error="onError"
      @click="onVideoClick"
    ></video>

    <SubtitleOverlay
      :segment="active"
      :mode="subtitleMode"
      :font-size="fontSize"
      :bottom-margin="bottomMargin"
    />

    <!-- IINA 顶部栏 -->
    <div v-show="!minimal" class="top-bar" :class="{ visible: controlsVisible }">
      <span class="title">{{ title || '视频' }}</span>
      <span class="spacer"></span>
      <span class="subtitle-indicator" v-if="subtitleOffset !== 0">字幕 {{ subtitleOffset > 0 ? '+' : '' }}{{ subtitleOffset.toFixed(1) }}s</span>
    </div>

    <!-- IINA 底部控制栏 -->
    <div v-show="!minimal" class="control-bar" :class="{ visible: controlsVisible }">
      <button class="icon-btn" :disabled="!hasPrevious" title="上一集（P）" aria-label="上一集" @click="emit('previous')">⏮</button>
      <button class="icon-btn play" title="播放 / 暂停（空格）" @click="togglePlay">
        {{ isPlaying ? '⏸' : '▶' }}
      </button>
      <button class="icon-btn" :disabled="!hasNext" title="下一集（N）" aria-label="下一集" @click="emit('next')">⏭</button>
      <span class="time">{{ fmtTime(currentTime) }}</span>
      <div
        ref="seekBarEl"
        class="seek"
        @pointerdown="onSeekDown"
        @pointermove="onSeekMove"
        @pointerup="onSeekUp"
      >
        <div class="seek-track">
          <div class="seek-fill" :style="{ width: progress + '%' }"></div>
          <div class="seek-thumb" :style="{ left: progress + '%' }"></div>
        </div>
      </div>
      <span class="time">{{ fmtTime(duration) }}</span>

      <div class="vol">
        <button class="icon-btn vol-icon" :title="muted ? '恢复声音（V）' : '静音（V）'" aria-label="切换静音" :aria-pressed="muted" @click="toggleMute">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon>
            <path v-if="!muted" d="M15.54 8.46a5 5 0 0 1 0 7.07"></path>
            <path v-if="!muted" d="M19.07 4.93a10 10 0 0 1 0 14.14"></path>
            <path v-else d="M16 9l6 6m0-6l-6 6"></path>
          </svg>
        </button>
        <input
          v-model.number="volume"
          type="range"
          min="0"
          max="1"
          step="0.05"
          class="vol-slider"
          title="音量"
          @input="muted = false"
          :style="{ '--fill': volumeFill }"
        />
      </div>

      <button class="icon-btn icon-lg" title="全屏（双击画面亦可）" @click="toggleFullscreen">⛶</button>
      <button class="icon-btn icon-lg" title="设置" @click="emit('settings')" aria-label="设置">⚙</button>
    </div>

    <!-- 精简模式：鼠标移动唤出的临时控制条（右上角还原） -->
    <div v-if="minimal" class="minimal-bar" :class="{ visible: minimalBarVisible }">
      <button class="minimal-restore" title="还原（Esc）" @click="emit('toggleMinimal')">还原</button>
    </div>

    <!-- OSD 浮动提示 -->
    <transition name="fade">
      <div v-if="osd" class="osd">{{ osd }}</div>
    </transition>
  </div>
</template>

<style scoped>
.player {
  position: relative;
  width: 100%;
  height: 100%;
  background: #000;
  overflow: hidden;
  cursor: default;
}
.video {
  width: 100%;
  height: 100%;
  object-fit: contain;
  outline: none;
  display: block;
  cursor: pointer;
}
.player:fullscreen.hide-cursor,
.player:fullscreen.hide-cursor :deep(*) {
  cursor: none !important;
}

/* ---- 顶部栏 ---- */
.top-bar,
.control-bar {
  position: absolute;
  left: 0;
  right: 0;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 14px;
  background: linear-gradient(to bottom, rgba(0, 0, 0, 0.85), rgba(0, 0, 0, 0));
  opacity: 0;
  transition: opacity 0.25s;
  z-index: 6;
}
.top-bar {
  top: 0;
  background: linear-gradient(to bottom, rgba(0, 0, 0, 0.85), rgba(0, 0, 0, 0));
}
.control-bar {
  bottom: 0;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.85), rgba(0, 0, 0, 0));
}
.top-bar.visible,
.control-bar.visible,
.control-bar:focus-within {
  opacity: 1;
}
.title {
  font-size: 13px;
  color: #eee;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 60%;
}
.spacer {
  flex: 1;
}
.subtitle-indicator {
  font-size: 12px;
  color: var(--accent);
}

/* ---- 控制按钮 ---- */
.icon-btn {
  background: transparent;
  border: none;
  color: #ddd;
  font-size: 13px;
  padding: 4px 8px;
  border-radius: 6px;
  cursor: pointer;
  white-space: nowrap;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  line-height: 1;
}
.icon-btn:hover {
  background: rgba(255, 255, 255, 0.14);
}
.icon-btn:disabled { opacity: 0.3; cursor: default; }
.shortcut-help { color: var(--text-dim); line-height: 1.8; font-size: 12px; }
@media (max-width: 1100px) {
  .sub-sync, .brightness-control { display: none; }
  .control-bar { gap: 6px; }
}
.icon-lg {
  font-size: 18px;
  padding: 6px 12px;
}
.play {
  font-size: 15px;
  padding: 4px 10px;
}
.time {
  font-size: 12px;
  color: #ccc;
  font-variant-numeric: tabular-nums;
  min-width: 40px;
  text-align: center;
}

/* ---- 进度条 ---- */
.seek {
  flex: 1;
  padding: 8px 0;
  cursor: pointer;
  touch-action: none;
}
.seek-track {
  position: relative;
  height: 4px;
  background: rgba(255, 255, 255, 0.25);
  border-radius: 2px;
}
.seek-fill {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  background: var(--accent);
  border-radius: 2px;
}
.seek-thumb {
  position: absolute;
  top: 50%;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: #fff;
  transform: translate(-50%, -50%);
  box-shadow: 0 0 4px rgba(0, 0, 0, 0.5);
  pointer-events: none;
}

/* ---- 音量 ---- */
.vol {
  display: flex;
  align-items: center;
  gap: 6px;
}
.vol-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: #ddd;
  flex-shrink: 0;
  cursor: default;
}
.vol-slider {
  -webkit-appearance: none;
  appearance: none;
  width: 70px;
  height: 4px;
  background: transparent;
  outline: none;
  cursor: pointer;
}
.vol-slider::-webkit-slider-runnable-track {
  height: 4px;
  border-radius: 2px;
  background: linear-gradient(
    to right,
    var(--accent) var(--fill, 50%),
    rgba(255, 255, 255, 0.25) var(--fill, 50%)
  );
}
.vol-slider::-webkit-slider-thumb {
  -webkit-appearance: none;
  appearance: none;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: #fff;
  margin-top: -4px;
  box-shadow: 0 0 4px rgba(0, 0, 0, 0.5);
  cursor: pointer;
}

/* ---- 字幕同步按钮 ---- */
.sub-sync {
  display: flex;
  gap: 2px;
}

/* ---- 设置抽屉 ---- */
.settings {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 0;
  width: 280px;
  background: rgba(18, 20, 26, 0.96);
  border-left: 1px solid rgba(255, 255, 255, 0.1);
  transform: translateX(100%);
  transition: transform 0.28s;
  z-index: 7;
  padding: 16px;
  box-sizing: border-box;
  overflow-y: auto;
}
.settings.open {
  transform: translateX(0);
}
.settings-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 14px;
  font-weight: 600;
  margin-bottom: 16px;
}
.setting-group {
  margin-bottom: 18px;
}
.setting-label {
  font-size: 12px;
  color: #9aa1b5;
  margin-bottom: 8px;
}
.row {
  display: flex;
  gap: 8px;
}
.mode-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 6px;
}
.speed-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 6px;
}
.seg-btn {
  border: 1px solid #2a2f3d;
  background: #1f2330;
  color: #ccc;
  border-radius: 6px;
  padding: 7px 0;
  font-size: 13px;
  cursor: pointer;
}
.seg-btn.active {
  border-color: var(--accent);
  background: rgba(79, 140, 255, 0.18);
  color: #fff;
}

/* ---- OSD ---- */
.osd {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  background: rgba(0, 0, 0, 0.7);
  color: #fff;
  padding: 10px 20px;
  border-radius: 10px;
  font-size: 20px;
  z-index: 8;
  pointer-events: none;
}
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

/* ---- 精简模式临时控制条 ---- */
.minimal-bar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  display: flex;
  justify-content: flex-end;
  padding: 10px 12px;
  background: linear-gradient(to bottom, rgba(0, 0, 0, 0.6), rgba(0, 0, 0, 0));
  opacity: 0;
  transition: opacity 0.25s;
  z-index: 7;
  pointer-events: none;
}
.minimal-bar.visible {
  opacity: 1;
}
.minimal-restore {
  pointer-events: auto;
  padding: 3px 10px;
  font-size: 12px;
  line-height: 1.5;
  border: 1px solid rgba(255, 255, 255, 0.22);
  background: rgba(0, 0, 0, 0.5);
  color: #eee;
  border-radius: 6px;
  cursor: pointer;
}
.minimal-restore:hover {
  background: rgba(0, 0, 0, 0.8);
}
</style>
