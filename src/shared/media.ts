/** 文件入口共用列表；实际能否播放以流信息和播放器解码结果为准。 */
export const VIDEO_EXTENSIONS = [
  'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'ts', 'mts', 'm2ts', 'm2t',
  'flv', 'f4v', 'wmv', 'asf', 'mpg', 'mpeg', 'mpe', 'm1v', 'm2v', 'vob',
  'ogv', '3gp', '3g2', 'rm', 'rmvb', 'divx', 'mxf', 'wtv'
]

export const AUDIO_EXTENSIONS = [
  'mp3', 'm4a', 'm4b', 'aac', 'wav', 'wave', 'flac', 'ogg', 'oga', 'opus',
  'aif', 'aiff', 'aifc', 'wma', 'ape', 'ac3', 'eac3', 'dts', 'mka', 'amr', 'wv'
]
export const MEDIA_EXTENSIONS = [...VIDEO_EXTENSIONS, ...AUDIO_EXTENSIONS]

export interface MediaProbe {
  videoCodec: string
  audioCodec: string
  pixelFormat: string
  videoStream?: number
  audioStream?: number
  duration: number
}

export type ConversionMode = 'remux' | 'audio' | 'transcode'
export type PlaybackMode = 'direct' | ConversionMode

/** 保守的快速路径；运行时解码失败还会再升级为完整转码。 */
export function playbackMode(path: string, probe: MediaProbe): PlaybackMode {
  const ext = path.split('.').pop()?.toLowerCase()
  const { videoCodec: video, audioCodec: audio, pixelFormat } = probe
  if (!video) {
    if (['mp4', 'm4a', 'm4b', 'mov'].includes(ext ?? '') && ['aac', 'mp3'].includes(audio)) return 'direct'
    if (ext === 'mp3' && audio === 'mp3') return 'direct'
    if (['wav', 'wave'].includes(ext ?? '') && ['pcm_s16le', 'pcm_s24le', 'pcm_f32le', 'pcm_u8', 'pcm_alaw', 'pcm_mulaw'].includes(audio)) return 'direct'
    if (ext === 'flac' && audio === 'flac') return 'direct'
    if (['ogg', 'oga', 'opus', 'webm'].includes(ext ?? '') && ['opus', 'vorbis', 'flac'].includes(audio)) return 'direct'
    return ['aac', 'mp3'].includes(audio) ? 'remux' : 'audio'
  }
  const h264 = video === 'h264' && ['yuv420p', 'yuvj420p'].includes(pixelFormat)
  const modern = ['vp9', 'av1'].includes(video)
  if (ext === 'webm' && ['vp8', 'vp9', 'av1'].includes(video) &&
      (!audio || ['opus', 'vorbis'].includes(audio))) return 'direct'
  if (h264 || modern) {
    const safeAudio = !audio || ['aac', 'mp3'].includes(audio)
    if (safeAudio && ['mp4', 'm4v', 'mov', 'm4a'].includes(ext ?? '')) return 'direct'
    return safeAudio ? 'remux' : 'audio'
  }
  return 'transcode'
}
