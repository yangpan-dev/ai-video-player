/** 文件入口共用列表；实际能否播放以流信息和播放器解码结果为准。 */
export const VIDEO_EXTENSIONS = [
  'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'ts', 'mts', 'm2ts', 'm2t',
  'flv', 'f4v', 'wmv', 'asf', 'mpg', 'mpeg', 'mpe', 'm1v', 'm2v', 'vob',
  'ogv', 'ogg', '3gp', '3g2', 'rm', 'rmvb', 'divx', 'mxf', 'wtv', 'm4a'
]

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
  const h264 = video === 'h264' && ['yuv420p', 'yuvj420p'].includes(pixelFormat)
  const modern = ['vp9', 'av1'].includes(video)
  if (ext === 'webm' && ['vp8', 'vp9', 'av1'].includes(video) &&
      (!audio || ['opus', 'vorbis'].includes(audio))) return 'direct'
  if (!video || h264 || modern) {
    const safeAudio = !audio || ['aac', 'mp3'].includes(audio)
    if (safeAudio && ['mp4', 'm4v', 'mov', 'm4a'].includes(ext ?? '')) return 'direct'
    return safeAudio ? 'remux' : 'audio'
  }
  return 'transcode'
}
