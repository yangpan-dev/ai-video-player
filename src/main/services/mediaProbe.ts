import type { MediaProbe } from '../../shared/media'

/** ffmpeg 的输入信息由固定的 Stream 行构成；只解析输入流并跳过封面。 */
export function parseMediaProbe(output: string): MediaProbe {
  const streams = output.split(/\r?\n/).flatMap((line) => {
    const match = /^\s*Stream #0:(\d+)(?:\[[^\]]*\])?(?:\([^)]*\))?:\s*(Video|Audio):\s*([\w]+)/.exec(line)
    if (!match || line.includes('(attached pic)')) return []
    return [{ index: Number(match[1]), type: match[2], codec: match[3].toLowerCase(), line }]
  })
  const choose = (type: string) => {
    const candidates = streams.filter((s) => s.type === type)
    return candidates.find((s) => s.line.includes('(default)')) ?? candidates[0]
  }
  const video = choose('Video')
  const audio = choose('Audio')
  if (!video && !audio) throw new Error('没有找到可读取的音视频流；文件可能已损坏或格式不受 FFmpeg 支持。')
  const duration = /Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/.exec(output)
  return {
    videoCodec: video?.codec ?? '',
    audioCodec: audio?.codec ?? '',
    videoStream: video?.index,
    audioStream: audio?.index,
    pixelFormat: video ? /,\s*((?:yuv|yuva|gbr|rgb|bgr|gray|nv|p0)[a-z0-9]+)(?:[,(\s])/.exec(video.line)?.[1] ?? '' : '',
    duration: duration ? Number(duration[1]) * 3600 + Number(duration[2]) * 60 + Number(duration[3]) : 0
  }
}
