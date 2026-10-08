import { open } from 'node:fs/promises'
import { Readable } from 'node:stream'

const MIME: Record<string, string> = {
  mp4: 'video/mp4', m4v: 'video/mp4', mov: 'video/quicktime', webm: 'video/webm',
  ogv: 'video/ogg', ogg: 'video/ogg', avi: 'video/x-msvideo', mkv: 'video/x-matroska', m4a: 'audio/mp4'
}

/** 流式读取 Range，避免 bytes=0- 把整部电影一次性分配到内存。 */
export async function mediaHandler(request: Request): Promise<Response> {
  let file
  try {
    const url = new URL(request.url)
    if (url.hostname !== 'f') return new Response(null, { status: 404 })
    if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405 })
    const path = decodeURIComponent(url.pathname.slice(1))
    file = await open(path, 'r')
    const stat = await file.stat()
    if (!stat.isFile()) return new Response(null, { status: 404 })
    const size = stat.size
    const headers = new Headers({
      'Accept-Ranges': 'bytes',
      'Content-Type': MIME[path.split('.').pop()?.toLowerCase() ?? ''] ?? 'application/octet-stream'
    })
    let start = 0
    let end = size - 1
    const range = request.headers.get('range')
    if (range) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim())
      if (!match || (!match[1] && !match[2]) || !size) {
        return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } })
      }
      if (match[1]) {
        start = Number(match[1])
        if (match[2]) end = Math.min(Number(match[2]), size - 1)
      } else {
        const suffix = Number(match[2])
        start = suffix > 0 ? Math.max(0, size - suffix) : size
      }
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) {
        return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } })
      }
      headers.set('Content-Range', `bytes ${start}-${end}/${size}`)
    }
    headers.set('Content-Length', String(Math.max(0, end - start + 1)))
    const status = range ? 206 : 200
    if (request.method === 'HEAD' || !size) return new Response(null, { status, headers })
    const stream = file.createReadStream({ start, end, highWaterMark: 256 * 1024, signal: request.signal })
    file = undefined // stream 负责关闭文件；取消 Web 流也会销毁 Node 流。
    return new Response(Readable.toWeb(stream) as ReadableStream<Uint8Array>, { status, headers })
  } catch {
    return new Response('Not found', { status: 404 })
  } finally {
    await file?.close()
  }
}
