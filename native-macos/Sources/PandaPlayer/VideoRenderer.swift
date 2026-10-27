import AppKit
import OpenGL.GL3
import CMPV

// Read by the UI/test harness, written by the render queue. Never publishes SwiftUI updates per frame.
final class VideoRenderStatistics {
    private let lock = NSLock()
    private var frames = 0
    private var mainThreadFrames = 0
    private var creations = 0
    private var verifiedPixels = false
    func created() { lock.lock(); creations += 1; lock.unlock() }
    func rendered() { lock.lock(); frames += 1; if Thread.isMainThread { mainThreadFrames += 1 }; lock.unlock() }
    func verifiedVideoPixels() { lock.lock(); verifiedPixels = true; lock.unlock() }
    var snapshot: (frames: Int, mainThreadFrames: Int, creations: Int, verifiedPixels: Bool) {
        lock.lock(); defer { lock.unlock() }; return (frames, mainThreadFrames, creations, verifiedPixels)
    }
}

private final class RenderSignal {
    let requests: DispatchSourceUserDataOr
    init(_ requests: DispatchSourceUserDataOr) { self.requests = requests }
}

// All mpv_render_* calls use this serial queue and the same current GL context.
// The queue never calls normal mpv properties/commands or waits for the main queue.
final class VideoRenderer {
    private let queue = DispatchQueue(label: "dev.panda.player.video-render", qos: .userInteractive)
    private let context: NSOpenGLContext
    private let handle: OpaquePointer
    private let statistics: VideoRenderStatistics
    private let requests: DispatchSourceUserDataOr
    private let signal: RenderSignal
    private let viewportLock = NSLock()
    private var viewport = NSSize.zero
    private var ready = false // Accessed only on queue.
    private let testPixels = CommandLine.arguments.contains("--fullscreen-test") || CommandLine.arguments.contains("--window-test")

    init(context: NSOpenGLContext, handle: OpaquePointer, statistics: VideoRenderStatistics, onFailure: @escaping (String) -> Void) {
        self.context = context; self.handle = handle; self.statistics = statistics
        requests = DispatchSource.makeUserDataOrSource(queue: queue)
        signal = RenderSignal(requests)
        requests.setEventHandler { [weak self] in
            guard let self else { return }
            self.render(force: self.requests.data & 2 != 0)
        }
        requests.resume()
        queue.async { [self] in
            withContext {
                // mpv sends frames at their due time (video-timing-offset=0).
                // Never wait for display timing while holding the GL lock needed by AppKit resizing.
                var interval: GLint = 0
                context.setValues(&interval, for: .swapInterval)
                let result = lumen_render_create(handle, { _, name in
                    guard let name else { return nil }
                    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
                }, nil)
                guard result >= 0 else {
                    let message = String(cString: lumen_error(result))
                    DispatchQueue.main.async { onFailure(message) }
                    return
                }
                ready = true; statistics.created()
                lumen_render_callback(handle, { opaque in
                    guard let opaque else { return }
                    // Merge callbacks instead of queuing one main-thread display() per video frame.
                    Unmanaged<RenderSignal>.fromOpaque(opaque).takeUnretainedValue().requests.or(data: 1)
                }, Unmanaged.passUnretained(signal).toOpaque())
            }
        }
    }
    // The caller holds the drawable's CGL lock while committing both its size and viewport.
    func updateViewport(size: NSSize) {
        viewportLock.lock(); viewport = size; viewportLock.unlock()
        requestDraw()
    }
    func requestDraw() { requests.or(data: 2) } // Expose/resize must redraw even when paused.
    private func withContext(_ action: () -> Void) {
        guard let cgl = context.cglContextObj else { return }
        CGLLockContext(cgl)
        context.makeCurrentContext()
        defer { NSOpenGLContext.clearCurrentContext(); CGLUnlockContext(cgl) }
        action()
    }
    private func render(force: Bool) {
        guard ready else { return }
        withContext {
            // Read after taking the drawable lock: AppKit may have resized the surface
            // while this render request was waiting. Never draw with the previous size.
            viewportLock.lock(); let size = viewport; viewportLock.unlock()
            guard size.width > 0, size.height > 0 else { return }
            var fbo: GLint = 0; glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
            if lumen_render_if_needed(handle, Int32(size.width), Int32(size.height), fbo, force ? 1 : 0) > 0 {
                // Sample our own framebuffer in integration tests only, to reject black/invalid output.
                if testPixels && statistics.snapshot.frames > 12 && !statistics.snapshot.verifiedPixels {
                    var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
                    var previousBuffer: GLint = 0; glGetIntegerv(GLenum(GL_READ_BUFFER), &previousBuffer)
                    glReadBuffer(fbo == 0 ? GLenum(GL_BACK) : GLenum(GL_COLOR_ATTACHMENT0))
                    glReadPixels(GLint(size.width / 2 - 8), GLint(size.height / 2 - 8), 16, 16, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixels)
                    glReadBuffer(GLenum(previousBuffer))
                    if glGetError() == GLenum(GL_NO_ERROR) && pixels.enumerated().contains(where: { $0.offset % 4 != 3 && $0.element > 32 }) { statistics.verifiedVideoPixels() }
                }
                context.flushBuffer()
                lumen_render_report_swap(handle)
                statistics.rendered()
            }
        }
    }
    func shutdown() {
        requests.cancel()
        // Drain rendering before the owner destroys the mpv core or detaches the GL surface.
        queue.sync {
            withContext {
                if ready { lumen_render_destroy(handle); ready = false }
            }
        }
    }
}
