<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import type {
  Library,
  ModelProgress,
  PipelineProgress,
  StreamProgress,
  SubtitleSegment,
  WhisperModelInfo
} from '@shared/types'
import { NLLB_LANG } from '@shared/types'
import { playbackMode, type PlaybackMode, type ConversionMode } from '@shared/media'
import DropZone from './components/DropZone.vue'
import VideoPlayer from './components/VideoPlayer.vue'
import ControlPanel from './components/ControlPanel.vue'
import { playerPreferences } from './lib/preferences'

interface LoadedVideo {
  /** 原始文件路径：播放列表/历史/进度/字幕都以此为键 */
  sourcePath: string
  /** 实际播放的文件路径（可能是转换缓存） */
  path: string
  url: string
  needsRemux: boolean
}

const video = ref<LoadedVideo | null>(null)
const segments = ref<SubtitleSegment[]>([])
const detectedLanguage = ref<string | null>(null)

const models = ref<WhisperModelInfo[]>([])
const selectedModel = ref('large-v3-turbo')
const mode = ref<'stream' | 'batch'>('stream')

const running = ref(false)
const translating = ref(false)
const downloading = ref<ModelProgress | null>(null)
const probing = ref(false)
const appliedMode = ref<PlaybackMode>('direct')
const remuxing = ref(false)
const transcoding = ref(false)
const transcodePercent = ref(0)
let transcodeDuration = 0
let progressLog = ''

// 播放进度（记住上次位置）
const initialTime = ref(0)
let currentVideoTime = 0
let lastSavedTime = -1
// 进度和字幕就绪后自动播放。
const shouldAutoplay = ref(false)
// 精简模式：只显示视频 + 字幕，隐藏侧栏/控制面板/状态栏
const minimalMode = ref(false)

const pipelineState = ref<PipelineProgress>({ stage: 'idle', message: '', percent: 0 })
const streamState = ref<StreamProgress>({ status: 'listening', message: '', percent: 0 })

// LLM 翻译模型状态
const llmModelReady = ref(false)
const llmLoading = ref(false)

// 播放列表 / 历史记录
const library = ref<Library>({ playlist: [], history: [], progress: {} })
const sidebarTab = ref<'playlist' | 'history'>('playlist')
const librarySearch = ref('')
const sortByName = ref(false)
const orderedPlaylist = computed(() => sortByName.value
  ? [...library.value.playlist].sort((a, b) => a.title.localeCompare(b.title, 'zh-CN', { numeric: true }))
  : library.value.playlist)
const visibleEntries = computed(() => {
  const entries = sidebarTab.value === 'playlist' ? orderedPlaylist.value : library.value.history
  const query = librarySearch.value.trim().toLocaleLowerCase()
  return query ? entries.filter((entry) => entry.title.toLocaleLowerCase().includes(query)) : entries
})
const playlistIndex = computed(() => orderedPlaylist.value.findIndex((entry) => entry.path === video.value?.sourcePath))
const hasPrevious = computed(() => playlistIndex.value > 0)
const hasNext = computed(() => playlistIndex.value >= 0 && playlistIndex.value < orderedPlaylist.value.length - 1)
let activeSubtitleRequest = ''
let subtitleRevision = 0

function stopSubtitleWork(): void {
  activeSubtitleRequest = ''
  subtitleRevision++
  void window.api.cancelPipeline()
  void window.api.cancelStreaming()
  running.value = false
  translating.value = false
  llmLoading.value = false
  if (translateTimer) clearTimeout(translateTimer)
  translateTimer = null
  translateBuf = []
}

function playAdjacent(direction: -1 | 1): void {
  if (direction < 0 ? !hasPrevious.value : !hasNext.value) return
  setVideoFromPath(orderedPlaylist.value[playlistIndex.value + direction].path)
}

function onPlayerEnded(): void {
  const source = video.value?.sourcePath
  if (!source) return
  currentVideoTime = 0
  lastSavedTime = 0
  void window.api.saveProgress(source, 0)
  if (playerPreferences.autoNext) playAdjacent(1)
}

async function importSubtitles(path?: string): Promise<void> {
  if (!video.value) { error.value = '请先打开视频，再导入字幕'; return }
  const seq = openSeq
  try {
    const result = await window.api.importSubtitles(path)
    if (!result || seq !== openSeq) return
    stopSubtitleWork()
    segments.value = result.segments
    if (playerPreferences.subtitleMode === 'off' || playerPreferences.subtitleMode === 'translation') {
      playerPreferences.subtitleMode = 'original'
    }
    error.value = null
    statusMsg.value = `已导入 ${titleOf(result.path)}，共 ${result.segments.length} 条字幕`
  } catch (e) {
    if (seq === openSeq) error.value = e instanceof Error ? e.message : String(e)
  }
}

// 转换缓存占用
const cacheInfo = ref<{ fileCount: number; totalBytes: number; dir: string } | null>(null)

const error = ref<string | null>(null)
const statusMsg = ref('')

// 流式日志（whisper-server / ffmpeg 输出），便于排查
const streamLogs = ref<string[]>([])
const showStreamLog = ref(false)

// 翻译队列（逐段串行，避免并发调用 worker）
let translateChain: Promise<void> = Promise.resolve()

function mediaUrl(path: string): string {
  return 'media://f/' + encodeURIComponent(path)
}

function resetResults(): void {
  segments.value = []
  detectedLanguage.value = null
  error.value = null
  statusMsg.value = ''
  pipelineState.value = { stage: 'idle', message: '', percent: 0 }
  streamState.value = { status: 'listening', message: '', percent: 0 }
  translateChain = Promise.resolve()
  translateBuf = []
  lastContext = []
  if (translateTimer) {
    clearTimeout(translateTimer)
    translateTimer = null
  }
}

/** 根据 whisper 检测到的语言映射 NLLB 源语言码；未知则默认日语 */
function srcLangCode(): string {
  return NLLB_LANG[detectedLanguage.value ?? ''] ?? 'jpn_Jpan'
}

/**
 * 用本地 LLM（Qwen）翻译一组句子，带上一组原文作为上下文。
 * 句数多时内部按每 5 句分块、滑动传递上下文。
 */
async function llmTranslateBatch(
  lines: string[],
  srcLang: string,
  context: string[] = [],
  requestId = activeSubtitleRequest
): Promise<string[]> {
  const GROUP = 5
  const out: string[] = []
  let ctx = context
  for (let i = 0; i < lines.length; i += GROUP) {
    if (!requestId || requestId !== activeSubtitleRequest) throw new Error('已取消')
    const group = lines.slice(i, i + GROUP)
    const t = await window.api.llmTranslate({ lines: group, srcLang, context: ctx })
    if (requestId !== activeSubtitleRequest) throw new Error('已取消')
    out.push(...t)
    ctx = group
  }
  return out
}

/** 流式翻译缓冲：攒几条一起翻，让相邻句共享上下文 */
let translateBuf: { idx: number; text: string }[] = []
let translateTimer: ReturnType<typeof setTimeout> | null = null
let lastContext: string[] = []

function flushTranslate(): void {
  if (translateTimer) {
    clearTimeout(translateTimer)
    translateTimer = null
  }
  if (!translateBuf.length) return
  const batch = translateBuf
  translateBuf = []
  const idxs = batch.map((b) => b.idx)
  const texts = batch.map((b) => b.text)
  const ctx = lastContext
  const requestId = activeSubtitleRequest
  translateChain = translateChain.then(async () => {
    if (!requestId || requestId !== activeSubtitleRequest) return
    try {
      llmLoading.value = true
      const translations = await llmTranslateBatch(texts, srcLangCode(), ctx, requestId)
      if (requestId !== activeSubtitleRequest) return
      translations.forEach((t, j) => {
        if (idxs[j] != null && segments.value[idxs[j]]) {
          segments.value[idxs[j]].translation = t
        }
      })
      lastContext = texts
    } catch {
      /* 翻译失败不阻断 */
    } finally {
      if (requestId === activeSubtitleRequest) llmLoading.value = false
    }
  })
}

/** 把一条字幕加入翻译队列（缓冲 + 串行） */
function queueTranslate(idx: number, text: string): void {
  translateBuf.push({ idx, text })
  if (translateBuf.length >= 3) {
    flushTranslate()
  } else if (!translateTimer) {
    translateTimer = setTimeout(flushTranslate, 1500)
  }
}

function titleOf(path: string): string {
  return path.split(/[\\/]/).pop() ?? path
}

/** 当前播放的源文件是否就是该列表项（用于高亮选中的视频） */
function isCurrentVideo(path: string): boolean {
  return video.value?.sourcePath === path
}

/** 播放器时间更新：节流保存进度（每 5 秒一次） */
function onPlayerTime(t: number): void {
  currentVideoTime = t
  if (!video.value) return
  if (Math.abs(t - lastSavedTime) >= 5) {
    lastSavedTime = t
    void window.api.saveProgress(video.value.sourcePath, t)
  }
}

/** 保存当前视频的播放进度（切换/关闭前调用） */
function saveCurrentProgress(): void {
  if (!video.value || currentVideoTime <= 0) return
  try {
    void window.api.saveProgress(video.value.sourcePath, currentVideoTime)
  } catch {
    /* 忽略 */
  }
}

/** 打开视频后：自动加入历史 + 播放列表，加载进度和上次保存的字幕 */
let openSeq = 0

async function afterVideoOpened(path: string, seq: number): Promise<void> {
  const revision = subtitleRevision
  try {
    const history = await window.api.addToHistory(path, titleOf(path))
    if (seq !== openSeq) return
    library.value = history
    const playlist = await window.api.addToPlaylist(path, titleOf(path))
    if (seq !== openSeq) return
    library.value = playlist
    const [time, saved] = await Promise.all([
      window.api.getProgress(path), window.api.loadSavedSubtitles(path)
    ])
    if (seq !== openSeq) return
    initialTime.value = time
    if (saved && revision === subtitleRevision) segments.value = saved
  } finally {
    if (seq === openSeq) shouldAutoplay.value = true
  }
}

function setVideoFromPath(path: string): void {
  saveCurrentProgress()
  stopSubtitleWork()
  stopActiveConversion(true)
  shouldAutoplay.value = false
  initialTime.value = 0
  currentVideoTime = 0
  lastSavedTime = -1
  appliedMode.value = 'direct'
  video.value = { sourcePath: path, path, url: '', needsRemux: true }
  resetResults()
  // 每次打开都检查实际流，MP4 也可能需要修复音频或转码。
  void afterVideoOpened(path, ++openSeq).catch(() => {})
  void autoConvert(path)
}

function onDropped(file: File): void {
  try {
    const path = window.api.getPathForFile(file)
    if (!path) throw new Error('请拖入本地视频文件')
    if (/\.(srt|vtt)$/i.test(path)) { void importSubtitles(path); return }
    setVideoFromPath(path)
  } catch (e) {
    error.value = '无法读取文件路径：' + (e instanceof Error ? e.message : String(e))
  }
}

async function openDialog(): Promise<void> {
  const path = await window.api.openVideoDialog()
  if (path) setVideoFromPath(path)
}

// ---- 播放列表 / 历史 ----
async function loadLibrary(): Promise<void> {
  try {
    library.value = await window.api.getLibrary()
  } catch {
    /* 忽略 */
  }
}

function playPath(path: string): void {
  setVideoFromPath(path)
}

async function addFiles(): Promise<void> {
  try {
    const res = await window.api.addVideoFiles()
    if (!res) return
    library.value = res.library
    statusMsg.value = res.added > 0 ? `已添加 ${res.added} 个视频到播放列表` : '所选视频已在播放列表中'
  } catch {
    /* 忽略 */
  }
}

async function addFolder(): Promise<void> {
  try {
    const res = await window.api.addFolderToPlaylist()
    if (!res) return
    library.value = res.library
    statusMsg.value =
      res.added > 0 ? `已从文件夹添加 ${res.added} 个视频到播放列表` : '文件夹中没有新的视频文件'
  } catch {
    /* 忽略 */
  }
}

async function removePlaylist(path: string): Promise<void> {
  try {
    library.value = await window.api.removeFromPlaylist(path)
  } catch {
    /* 忽略 */
  }
}

async function clearPlaylistList(): Promise<void> {
  if (!library.value.playlist.length) return
  try {
    library.value = await window.api.clearPlaylist()
  } catch {
    /* 忽略 */
  }
}

async function clearHistoryList(): Promise<void> {
  try {
    library.value = await window.api.clearHistory()
  } catch {
    /* 忽略 */
  }
}

function fmtBytes(n: number): string {
  if (n < 1024) return n + ' B'
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB'
  if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB'
  return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB'
}

async function loadCacheStats(): Promise<void> {
  try {
    cacheInfo.value = await window.api.cacheStats()
  } catch {
    /* 忽略 */
  }
}

async function clearTranscodeCache(): Promise<void> {
  if (probing.value || remuxing.value || transcoding.value) return
  try {
    cacheInfo.value = await window.api.clearCache()
    statusMsg.value = '已清理转换缓存（正在播放的缓存文件会保留）'
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  }
}

/** 自动保存字幕（生成完成后调用，下次打开无需重新识别） */
async function autoSaveSubtitles(): Promise<void> {
  if (!video.value || !segments.value.length) return
  const requestId = activeSubtitleRequest
  try {
    await window.api.saveSubtitles({
      videoPath: video.value.sourcePath,
      segments: segments.value.map((s) => ({
        index: s.index,
        start: s.start,
        end: s.end,
        text: s.text,
        translation: s.translation
      }))
    })
    if (requestId === activeSubtitleRequest) statusMsg.value = '字幕已自动保存'
  } catch {
    /* 忽略自动保存失败 */
  }
}

async function loadModels(): Promise<void> {
  try {
    models.value = await window.api.listModels()
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  }
}

async function onDownload(name: string): Promise<void> {
  downloading.value = { name, percent: 0, message: '开始下载' }
  try {
    await window.api.downloadModel(name)
    await loadModels()
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    downloading.value = null
  }
}

async function checkLlmStatus(): Promise<void> {
  try {
    const status = await window.api.llmStatus()
    llmModelReady.value = status.modelExists
  } catch {
    /* 忽略 */
  }
}

async function downloadLlm(): Promise<void> {
  downloading.value = { name: 'qwen2.5-7b', percent: 0, message: '开始下载（约 4.4GB）' }
  try {
    await window.api.downloadLlmModel()
    await checkLlmStatus()
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    downloading.value = null
  }
}

/** 批量模式：抽整段音频 -> 识别 -> 批量翻译 */
async function runBatch(): Promise<void> {
  if (!video.value || video.value.needsRemux) return
  running.value = true
  const requestId = activeSubtitleRequest
  try {
    const res = await window.api.runPipeline(video.value.sourcePath, {
      requestId,
      model: selectedModel.value,
      language: 'auto'
    })
    if (requestId !== activeSubtitleRequest) return
    detectedLanguage.value = res.detectedLanguage
    segments.value = res.segments

    if (res.segments.length === 0) {
      statusMsg.value = '未识别到语音内容'
      return
    }

    translating.value = true
    llmLoading.value = true
    const texts = res.segments.map((s) => s.text)
    const translations = await llmTranslateBatch(texts, srcLangCode(), [], requestId)
    if (requestId !== activeSubtitleRequest) return
    segments.value = res.segments.map((s, i) => ({ ...s, translation: translations[i] }))
    await autoSaveSubtitles()
  } finally {
    if (requestId === activeSubtitleRequest) {
      running.value = false
      translating.value = false
      llmLoading.value = false
    }
  }
}

/** 流式模式：边识别边出字幕，逐段翻译 */
async function runStream(): Promise<void> {
  if (!video.value || video.value.needsRemux) return
  running.value = true
  const requestId = activeSubtitleRequest
  try {
    const res = await window.api.startStreaming(video.value.sourcePath, {
      requestId,
      model: selectedModel.value,
      language: 'auto'
    })
    if (requestId !== activeSubtitleRequest) return
    detectedLanguage.value = res.detectedLanguage || detectedLanguage.value
    statusMsg.value =
      res.segmentCount === 0
        ? '未检测到语音：请确认视频有音轨；若是纯音乐/环境音或噪声很大，也可能切不出语音片段'
        : `识别完成，共 ${res.segmentCount} 句`
    // 等翻译队列全部完成，再自动保存（下次打开直接加载，无需重新识别）
    flushTranslate()
    await translateChain
    if (requestId !== activeSubtitleRequest) return
    if (segments.value.length > 0) await autoSaveSubtitles()
  } finally {
    if (requestId === activeSubtitleRequest) running.value = false
  }
}

async function generate(): Promise<void> {
  if (!video.value || video.value.needsRemux) return
  stopSubtitleWork()
  const requestId = crypto.randomUUID()
  activeSubtitleRequest = requestId
  error.value = null
  statusMsg.value = ''
  segments.value = []
  detectedLanguage.value = null
  translateChain = Promise.resolve()
  translateBuf = []
  if (translateTimer) {
    clearTimeout(translateTimer)
    translateTimer = null
  }
  try {
    if (mode.value === 'stream') await runStream()
    else await runBatch()
  } catch (e) {
    if (requestId !== activeSubtitleRequest) return
    const msg = e instanceof Error ? e.message : String(e)
    if (msg.includes('已取消')) statusMsg.value = '已取消'
    else error.value = msg
  }
}

function cancel(): void {
  stopSubtitleWork()
  statusMsg.value = '字幕任务已取消'
}

async function exportSubtitles(): Promise<void> {
  if (!video.value || !segments.value.length) return
  try {
    const { srtPath, vttPath } = await window.api.saveSubtitles({
      videoPath: video.value.sourcePath,
      // 转成普通对象，避免 Vue 响应式 Proxy 无法被 IPC 结构化克隆
      segments: segments.value.map((s) => ({
        index: s.index,
        start: s.start,
        end: s.end,
        text: s.text,
        translation: s.translation
      }))
    })
    statusMsg.value = `已导出：${srtPath} 和 ${vttPath}`
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  }
}

// 打开、取消、重试都使旧异步结果作废。
let convertSeq = 0

function stopActiveConversion(releasePlayback = false): void {
  convertSeq++
  void window.api.cancelConvert(releasePlayback)
  probing.value = false
  remuxing.value = false
  transcoding.value = false
  transcodePercent.value = 0
  transcodeDuration = 0
  progressLog = ''
}

function cancelConversion(): void {
  stopActiveConversion()
  statusMsg.value = '兼容处理已取消，可重试或打开其他视频'
}

async function remux(): Promise<void> {
  if (!video.value || probing.value || remuxing.value || transcoding.value) return
  stopActiveConversion()
  await autoConvert(video.value.sourcePath, 'remux')
}

async function transcode(): Promise<void> {
  if (!video.value || probing.value || remuxing.value || transcoding.value) return
  stopActiveConversion()
  await autoConvert(video.value.sourcePath, 'transcode')
}

async function autoConvert(sourcePath: string, force?: ConversionMode): Promise<void> {
  const seq = convertSeq
  const current = (): boolean => seq === convertSeq && video.value?.sourcePath === sourcePath
  error.value = null
  probing.value = true
  statusMsg.value = '正在检查视频和音频编码…'
  try {
    const probe = await window.api.probeVideo(sourcePath)
    if (!current()) return
    probing.value = false
    transcodeDuration = probe.duration
    let mode: PlaybackMode = force ?? playbackMode(sourcePath, probe)
    if (mode === 'direct') {
      appliedMode.value = mode
      video.value = { sourcePath, path: sourcePath, url: mediaUrl(sourcePath), needsRemux: false }
      statusMsg.value = ''
      return
    }
    if (video.value) video.value.needsRemux = true
    if (mode === 'remux' || mode === 'audio') {
      remuxing.value = true
      statusMsg.value = mode === 'audio' ? '正在兼容音轨，保留原始视频画质…' : '正在快速整理视频封装，保留原始画质…'
      try {
        const result = await window.api.remuxVideo(sourcePath, mode === 'audio')
        if (!current()) return
        appliedMode.value = mode
        video.value = { sourcePath, path: result.outputPath, url: mediaUrl(result.outputPath), needsRemux: false }
        statusMsg.value = result.cached ? '已使用兼容播放缓存' : '兼容处理完成，视频画质未改变'
        return
      } catch (e) {
        if (!current() || (e instanceof Error && e.message.includes('已取消'))) return
        mode = 'transcode'
      } finally {
        if (current()) remuxing.value = false
      }
    }
    transcoding.value = true
    transcodePercent.value = 0
    progressLog = ''
    statusMsg.value = '正在转换为兼容视频，首次处理需要等待，完成后会自动播放…'
    const result = await window.api.transcodeVideo(sourcePath)
    if (!current()) return
    appliedMode.value = 'transcode'
    video.value = { sourcePath, path: result.outputPath, url: mediaUrl(result.outputPath), needsRemux: false }
    statusMsg.value = result.cached ? '已使用兼容播放缓存' : '兼容处理完成'
  } catch (e) {
    if (current()) {
      error.value = e instanceof Error ? e.message : String(e)
      statusMsg.value = ''
    }
  } finally {
    if (current()) {
      probing.value = false
      remuxing.value = false
      transcoding.value = false
      void loadCacheStats()
    }
  }
}

function onPlayerError(event: { message: string; code: number; src: string | null }): void {
  const loaded = video.value
  if (!loaded || loaded.url !== event.src || probing.value || remuxing.value || transcoding.value) return
  if ((event.code === 3 || event.code === 4) && appliedMode.value !== 'transcode') {
    // 设备解码能力仍可能不同：最多升级一次，避免失败重试循环。
    initialTime.value = currentVideoTime || initialTime.value
    stopActiveConversion()
    loaded.needsRemux = true
    void autoConvert(loaded.sourcePath, 'transcode')
  } else {
    error.value = event.message + (appliedMode.value === 'transcode' ? '；兼容转换后仍无法播放，请检查文件是否损坏。' : '')
  }
}

function toggleMinimal(): void {
  minimalMode.value = !minimalMode.value
}

function onAppKeydown(e: KeyboardEvent): void {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'o') {
    e.preventDefault()
    void openDialog()
    return
  }
  if (e.ctrlKey || e.metaKey || e.altKey) return
  if (e.target instanceof HTMLElement && (e.target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT', 'BUTTON'].includes(e.target.tagName))) return
  // Esc 退出精简模式（也支持 M 键快速切换）
  if (e.key === 'Escape' && minimalMode.value) {
    minimalMode.value = false
  } else if ((e.key === 'm' || e.key === 'M') && video.value && !(e.target instanceof HTMLInputElement) && !(e.target instanceof HTMLTextAreaElement)) {
    minimalMode.value = !minimalMode.value
  }
}

function onWindowDrop(e: DragEvent): void {
  e.preventDefault()
  const f = e.dataTransfer?.files?.[0]
  if (f) onDropped(f)
}
function onWindowDragOver(e: DragEvent): void {
  e.preventDefault()
}

const unsubscribers: Array<() => void> = []

onMounted(() => {
  void loadModels()
  void checkLlmStatus()
  void loadLibrary()
  void loadCacheStats()
  window.addEventListener('dragover', onWindowDragOver)
  window.addEventListener('drop', onWindowDrop)
  window.addEventListener('keydown', onAppKeydown)
  window.addEventListener('beforeunload', saveCurrentProgress)
  unsubscribers.push(window.api.onPipelineProgress(({ requestId, data }) => {
    if (requestId === activeSubtitleRequest) pipelineState.value = data
  }))
  unsubscribers.push(window.api.onModelProgress((p) => (downloading.value = p)))
  unsubscribers.push(window.api.onStreamProgress(({ requestId, data }) => {
    if (requestId !== activeSubtitleRequest) return
    streamState.value = data
    if (data.detectedLanguage) detectedLanguage.value = data.detectedLanguage
  }))
  unsubscribers.push(
    window.api.onStreamSegment(({ requestId, data: seg }) => {
      if (!requestId || requestId !== activeSubtitleRequest) return
      const idx = segments.value.length
      segments.value.push({ index: seg.index, start: seg.start, end: seg.end, text: seg.text })
      queueTranslate(idx, seg.text)
    })
  )
  unsubscribers.push(
    window.api.onStreamLog(({ requestId, data: line }) => {
      if (requestId !== activeSubtitleRequest) return
      const t = line.trim()
      if (!t) return
      streamLogs.value.push(t)
      if (streamLogs.value.length > 200) streamLogs.value.shift()
    })
  )
  unsubscribers.push(
    window.api.onTranscodeLog(({ data, sourcePath }) => {
      if (!transcoding.value || sourcePath !== video.value?.sourcePath) return
      progressLog = (progressLog + data).slice(-4096)
      const matches = [...progressLog.matchAll(/time=\s*(\d+):(\d+):(\d+\.\d+)/g)]
      const tm = matches.at(-1)
      if (tm && transcodeDuration > 0) {
        const cur = +tm[1] * 3600 + +tm[2] * 60 + +tm[3]
        transcodePercent.value = Math.max(0, Math.min(99, Math.round((cur / transcodeDuration) * 100)))
      }
    })
  )
})

onBeforeUnmount(() => {
  openSeq++
  saveCurrentProgress()
  stopActiveConversion(true)
  stopSubtitleWork()
  window.removeEventListener('dragover', onWindowDragOver)
  window.removeEventListener('drop', onWindowDrop)
  window.removeEventListener('keydown', onAppKeydown)
  window.removeEventListener('beforeunload', saveCurrentProgress)
  unsubscribers.forEach((u) => u())
})

const hasSegments = computed(() => segments.value.length > 0)
const busy = computed(
  () =>
    running.value || translating.value || probing.value || remuxing.value || transcoding.value || !!downloading.value
)
</script>

<template>
  <div class="app">
    <div class="content">
      <aside v-show="!minimalMode" class="sidebar">
        <div class="sidebar-tabs">
            <button
              class="tab"
              :class="{ active: sidebarTab === 'playlist' }"
              @click="sidebarTab = 'playlist'"
            >
              播放列表
            </button>
            <button
              class="tab"
              :class="{ active: sidebarTab === 'history' }"
              @click="sidebarTab = 'history'"
            >
              历史记录
            </button>
          </div>

          <div class="library-tools">
            <input v-model="librarySearch" type="search" placeholder="搜索视频…" aria-label="搜索视频" />
            <label v-if="sidebarTab === 'playlist'" class="sort-option">
              <input v-model="sortByName" type="checkbox" /> 按名称排序
            </label>
          </div>
          <div v-if="sidebarTab === 'playlist'" class="sidebar-body">
            <button class="sidebar-action" title="打开视频（⌘ / Ctrl + O）" @click="openDialog">打开视频</button>
            <button class="sidebar-action" @click="addFiles">🎬 添加视频文件</button>
            <button class="sidebar-action" @click="addFolder">📁 添加文件夹（含子文件夹）</button>
            <button v-if="library.playlist.length" class="sidebar-action sidebar-clear" @click="clearPlaylistList">
              🗑 清空列表
            </button>
            <div v-if="!library.playlist.length" class="sidebar-empty">播放列表为空</div>
            <div v-if="librarySearch && !visibleEntries.length" class="sidebar-empty">没有匹配的视频</div>
            <div v-for="e in visibleEntries" :key="e.path" class="sidebar-item" :class="{ active: isCurrentVideo(e.path) }">
              <div class="sidebar-item-title" :title="e.path" @click="playPath(e.path)">
                {{ e.title }}
              </div>
              <button class="sidebar-item-x" title="移除" @click="removePlaylist(e.path)">✕</button>
            </div>
          </div>

          <div v-if="sidebarTab === 'history'" class="sidebar-body">
            <button v-if="library.history.length" class="sidebar-action" @click="clearHistoryList">
              清空历史
            </button>
            <div v-if="!library.history.length" class="sidebar-empty">暂无历史</div>
            <div v-if="librarySearch && !visibleEntries.length" class="sidebar-empty">没有匹配的视频</div>
            <div v-for="e in visibleEntries" :key="e.path" class="sidebar-item" :class="{ active: isCurrentVideo(e.path) }">
              <div class="sidebar-item-title" :title="e.path" @click="playPath(e.path)">
                {{ e.title }}
              </div>
            </div>
          </div>

          <div class="sidebar-footer">
            <span class="cache-label" :title="cacheInfo?.dir">
              转换缓存：{{ cacheInfo ? fmtBytes(cacheInfo.totalBytes) : '…' }}
            </span>
            <button
              class="sidebar-cache-clear"
              :disabled="probing || remuxing || transcoding || !cacheInfo || cacheInfo.totalBytes === 0"
              @click="clearTranscodeCache"
            >
              清理
            </button>
          </div>
        </aside>

        <div class="player-area">
          <template v-if="!video">
            <DropZone @browse="openDialog" />
          </template>
          <template v-else>
      <ControlPanel
        v-show="!minimalMode"
        :models="models"
        v-model:selected-model="selectedModel"
        v-model:mode="mode"
        :running="running"
        :translating="translating"
        :has-segments="hasSegments"
        :needs-remux="video.needsRemux"
        :detected-language="detectedLanguage"
        :download-state="downloading"
        :llm-model-ready="llmModelReady"
        :disabled="video.needsRemux"
        @download="onDownload"
        @download-llm="downloadLlm"
        @generate="generate"
        @cancel="cancel"
        @export="exportSubtitles"
        @remux="remux"
        @import="importSubtitles()"
      />

      <main class="main">
        <VideoPlayer
          v-if="!video.needsRemux"
          :key="video.url"
          :src="video.url"
          :segments="segments"
          :title="video.sourcePath.split('/').pop()"
          :initial-time="initialTime"
          :autoplay="shouldAutoplay"
          :minimal="minimalMode"
          :has-previous="hasPrevious"
          :has-next="hasNext"
          @time="onPlayerTime"
          @toggle-minimal="toggleMinimal"
          @error="onPlayerError"
          @previous="playAdjacent(-1)"
          @next="playAdjacent(1)"
          @ended="onPlayerEnded"
          @pause="saveCurrentProgress"
        />
        <div v-else class="remux-hint">
          <div class="remux-hint-icon">⚠️</div>
          <p>{{ statusMsg || '此视频需要兼容处理后播放' }}</p>
          <p class="dim">
            自动检测视频与音轨，优先保留原始画质。<br />
            需要转换的视频会保存在本地缓存中，再次打开可直接播放。
          </p>
          <p v-if="error" class="dim">{{ error }}</p>
          <div class="remux-actions">
            <button class="primary" :disabled="probing || remuxing || transcoding" @click="remux">
              {{ remuxing ? '封装中…' : '无损转 MP4' }}
            </button>
            <button :disabled="probing || remuxing || transcoding" @click="transcode">
              {{ transcoding ? `转码中… ${transcodePercent}%` : '转码为 H.264' }}
            </button>
            <button
              v-if="probing || remuxing || transcoding"
              class="danger"
              title="取消当前转换"
              @click="cancelConversion"
            >
              取消
            </button>
          </div>
          <div v-if="transcoding" class="bar-track transcode-bar">
            <div class="bar-fill" :style="{ width: transcodePercent + '%' }"></div>
          </div>
        </div>
      </main>

      <footer class="status" v-show="!minimalMode" v-if="busy || error || statusMsg">
        <div v-if="running && mode === 'batch'" class="bar">
          <span class="bar-label">{{ pipelineState.message }}</span>
          <div class="bar-track">
            <div class="bar-fill" :style="{ width: pipelineState.percent + '%' }"></div>
          </div>
          <span class="bar-pct">{{ pipelineState.percent }}%</span>
        </div>

        <div v-if="running && mode === 'stream'" class="bar">
          <span class="bar-label">
            {{ streamState.message }}
            <span v-if="streamState.segmentCount" class="seg-count">已识别 {{ streamState.segmentCount }} 句</span>
          </span>
          <div class="bar-track">
            <div class="bar-fill" :style="{ width: streamState.percent + '%' }"></div>
          </div>
          <span class="bar-pct">{{ streamState.percent }}%</span>
          <button class="mini-log" @click="showStreamLog = !showStreamLog">日志</button>
        </div>

        <div v-if="showStreamLog && streamLogs.length" class="log-panel">
          <div v-for="(l, i) in streamLogs" :key="i" class="log-line">{{ l }}</div>
        </div>

        <div v-if="translating" class="bar">
          <span class="bar-label">
            {{ llmLoading ? '翻译中（首次会先加载 Qwen 模型，需几十秒）…' : '翻译中…' }}
          </span>
        </div>

        <div v-if="downloading" class="bar">
          <span class="bar-label">下载模型 {{ downloading.name }}</span>
          <div class="bar-track">
            <div class="bar-fill" :style="{ width: downloading.percent + '%' }"></div>
          </div>
          <span class="bar-pct">{{ downloading.percent }}%</span>
        </div>

        <div v-if="error" class="error">{{ error }}</div>
        <div v-if="statusMsg && !error" class="ok">{{ statusMsg }}</div>
      </footer>
          </template>
        </div>
    </div>
  </div>
</template>

<style scoped>
.library-tools { padding: 10px 12px; display: grid; gap: 8px; }
.library-tools > input {
  min-width: 0; width: 100%; padding: 8px 10px; color: var(--text);
  background: var(--bg-panel); border: 1px solid var(--border); border-radius: 8px; outline: none;
}
.library-tools > input:focus { border-color: var(--accent); }
.sort-option { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--text-dim); }
.sort-option input { width: auto; }
.app {
  height: 100%;
  display: flex;
  flex-direction: column;
}
.content {
  flex: 1;
  min-height: 0;
  display: flex;
}
.sidebar {
  width: 220px;
  flex-shrink: 0;
  background: var(--bg-panel);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  min-height: 0;
}
.sidebar-tabs {
  display: flex;
  border-bottom: 1px solid var(--border);
}
.tab {
  flex: 1;
  border: none;
  background: transparent;
  color: var(--text-dim);
  padding: 10px 0;
  font-size: 13px;
  border-radius: 0;
}
.tab.active {
  color: var(--text);
  border-bottom: 2px solid var(--accent);
}
.sidebar-body {
  flex: 1;
  overflow-y: auto;
  padding: 8px;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.sidebar-action {
  margin-bottom: 8px;
  font-size: 12px;
  padding: 7px 10px;
}
.sidebar-action.sidebar-clear:hover:not(:disabled) {
  color: var(--danger);
  border-color: var(--danger);
}
.sidebar-empty {
  color: var(--text-dim);
  font-size: 12px;
  text-align: center;
  margin-top: 24px;
}
.sidebar-item {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 6px 8px;
  border-radius: 6px;
}
.sidebar-item:hover {
  background: var(--bg-elevated);
}
.sidebar-item.active {
  background: rgba(79, 140, 255, 0.16);
}
.sidebar-item.active .sidebar-item-title {
  color: var(--accent);
  font-weight: 600;
}
.sidebar-item-title {
  flex: 1;
  font-size: 13px;
  cursor: pointer;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.sidebar-item-x {
  border: none;
  background: transparent;
  color: var(--text-dim);
  font-size: 11px;
  padding: 2px 6px;
  border-radius: 4px;
}
.sidebar-item-x:hover {
  color: var(--danger);
  background: rgba(255, 92, 108, 0.12);
}
.sidebar-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 8px 10px;
  border-top: 1px solid var(--border);
  font-size: 11px;
  color: var(--text-dim);
}
.cache-label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.sidebar-cache-clear {
  flex-shrink: 0;
  border: 1px solid var(--border);
  background: var(--bg-elevated);
  color: var(--text-dim);
  font-size: 11px;
  padding: 2px 8px;
  border-radius: 4px;
  cursor: pointer;
}
.sidebar-cache-clear:hover:not(:disabled) {
  color: var(--danger);
  border-color: var(--danger);
}
.sidebar-cache-clear:disabled {
  opacity: 0.4;
  cursor: default;
}
.player-area {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.main {
  flex: 1;
  min-height: 0;
  position: relative;
}
.status {
  padding: 8px 16px;
  background: var(--bg-panel);
  border-top: 1px solid var(--border);
  font-size: 13px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.bar {
  display: flex;
  align-items: center;
  gap: 10px;
}
.bar-label {
  color: var(--text-dim);
  white-space: nowrap;
  min-width: 180px;
}
.seg-count {
  color: var(--accent);
  margin-left: 6px;
}
.bar-track {
  flex: 1;
  height: 6px;
  background: var(--bg-elevated);
  border-radius: 4px;
  overflow: hidden;
}
.bar-fill {
  height: 100%;
  background: var(--accent);
  border-radius: 4px;
  transition: width 0.2s;
}
.bar-pct {
  color: var(--text-dim);
  min-width: 48px;
  text-align: right;
}
.mini-log {
  padding: 2px 8px;
  font-size: 11px;
  border: 1px solid var(--border);
  background: var(--bg-elevated);
  color: var(--text-dim);
  border-radius: 4px;
  cursor: pointer;
}
.log-panel {
  max-height: 160px;
  overflow-y: auto;
  background: #0b0d12;
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 8px 10px;
  font-family: ui-monospace, Menlo, monospace;
  font-size: 11px;
}
.log-line {
  color: #8b93a7;
  white-space: pre-wrap;
  word-break: break-all;
  line-height: 1.4;
}
.error {
  color: var(--danger);
}
.ok {
  color: var(--ok);
}
.remux-hint {
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
  gap: 8px;
  padding: 32px;
}
.remux-hint-icon {
  font-size: 44px;
}
.remux-hint .dim {
  color: var(--text-dim);
  font-size: 13px;
  margin: 0 0 12px;
}
.remux-actions {
  display: flex;
  gap: 12px;
}
.transcode-bar {
  width: 320px;
  margin-top: 4px;
}
</style>
