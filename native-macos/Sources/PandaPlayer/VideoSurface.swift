import AppKit
import SwiftUI
import OpenGL.GL3
import CMPV

private final class RenderSignal { weak var view: MPVVideoView? }

struct VideoSurface: NSViewRepresentable {
    @ObservedObject var store: PlayerStore
    func makeNSView(context: Context) -> NSView {
        if let view = MPVVideoView(store: store) { return view }
        DispatchQueue.main.async { store.error = "系统无法创建视频渲染上下文" }
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? MPVVideoView)?.releaseRenderer() }
}

final class MPVVideoView: NSOpenGLView {
    private weak var store: PlayerStore?
    private var rendererReady = false
    private let signal = RenderSignal()
    private var shutdownObserver: NSObjectProtocol?
    private var cursorObserver: NSObjectProtocol?
    private var tracking: NSTrackingArea?
    private var cursorWork: DispatchWorkItem?
    private var cursorHidden = false
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init?(store: PlayerStore) {
        self.store = store
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAlphaSize), 8, 0
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else { return nil }
        super.init(frame: .zero, pixelFormat: format)
        wantsBestResolutionOpenGLSurface = true
        signal.view = self
        shutdownObserver = NotificationCenter.default.addObserver(forName: .lumenShutdown, object: nil, queue: .main) { [weak self] _ in self?.releaseRenderer() }
        cursorObserver = NotificationCenter.default.addObserver(forName: .lumenRevealCursor, object: nil, queue: .main) { [weak self] _ in self?.cursorWork?.cancel(); self?.revealCursor() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        var interval: GLint = 1
        openGLContext?.setValues(&interval, for: .swapInterval)
        guard !rendererReady, let handle = store?.engine?.handle else { return }
        let result = lumen_render_create(handle, { _, name in
            guard let name else { return nil }
            // OpenGL symbols are supplied by the system framework linked above.
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }, nil)
        guard result >= 0 else {
            DispatchQueue.main.async { [weak self] in self?.store?.error = "视频渲染初始化失败：\(String(cString: lumen_error(result)))" }
            return
        }
        rendererReady = true
        lumen_render_callback(handle, { context in
            guard let context else { return }
            let signal = Unmanaged<RenderSignal>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak signal] in signal?.view?.display() }
        }, Unmanaged.passUnretained(signal).toOpaque())
    }
    override func reshape() { super.reshape(); openGLContext?.update(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        let size = convertToBacking(bounds).size
        if rendererReady, let handle = store?.engine?.handle {
            var fbo: GLint = 0; glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
            lumen_render(handle, Int32(size.width), Int32(size.height), fbo)
            if store?.current != nil { store?.renderedFrameCount += 1 }
        } else {
            glClearColor(0.025, 0.029, 0.04, 1); glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        context.flushBuffer()
    }
    func releaseRenderer() {
        cursorWork?.cancel(); revealCursor()
        guard rendererReady else { return }
        openGLContext?.makeCurrentContext()
        if let handle = store?.engine?.handle { lumen_render_destroy(handle) }
        rendererReady = false
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { store?.toggleFullscreen() }
        else { store?.togglePlay() }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 49: store?.togglePlay()
            case 123: store?.jump(event.modifierFlags.contains(.shift) ? -30 : -5)
            case 124: store?.jump(event.modifierFlags.contains(.shift) ? 30 : 5)
            case 125: store?.volume = max(0, (store?.volume ?? 0) - 5)
            case 126: store?.volume = min(100, (store?.volume ?? 0) + 5)
            case 53: if store?.isFullscreen == true { store?.toggleFullscreen() }
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "f": store?.toggleFullscreen()
                case "m": store?.muted.toggle()
                case "[": store?.subtitleDelay -= 0.1
                case "]": store?.subtitleDelay += 0.1
                default: super.keyDown(with: event)
                }
            }
        } else { super.keyDown(with: event) }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        revealCursor(); cursorWork?.cancel(); store?.controlsVisible = true
        guard store?.isFullscreen == true, store?.isPlaying == true else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.store?.isFullscreen == true, self.window?.isKeyWindow == true else { return }
            NSCursor.hide(); self.cursorHidden = true
            self.store?.controlsVisible = false
        }
        cursorWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
    override func mouseExited(with event: NSEvent) { cursorWork?.cancel(); revealCursor() }
    private func revealCursor() { if cursorHidden { NSCursor.unhide(); cursorHidden = false } }
    deinit {
        if let shutdownObserver { NotificationCenter.default.removeObserver(shutdownObserver) }
        if let cursorObserver { NotificationCenter.default.removeObserver(cursorObserver) }
    }
}

extension Notification.Name { static let lumenRevealCursor = Notification.Name("lumen.revealCursor") }
