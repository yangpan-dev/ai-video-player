import AppKit
import SwiftUI
import OpenGL.GL3
import CMPV

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
    private var renderer: VideoRenderer?
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
        shutdownObserver = NotificationCenter.default.addObserver(forName: .lumenShutdown, object: nil, queue: .main) { [weak self] _ in self?.releaseRenderer() }
        cursorObserver = NotificationCenter.default.addObserver(forName: .lumenRevealCursor, object: nil, queue: .main) { [weak self] _ in self?.cursorWork?.cancel(); self?.revealCursor() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard renderer == nil, let context = openGLContext, let store, let handle = store.engine?.handle else { return }
        NSOpenGLContext.clearCurrentContext()
        renderer = VideoRenderer(context: context, handle: handle, statistics: store.renderStatistics) { [weak store] message in
            store?.error = "视频渲染初始化失败：\(message)"
        }
        requestRedraw()
    }
    // AppKit can touch the same drawable during a resize. Serialize those short operations
    // with rendering, but never decode/render or wait for vsync on the UI thread.
    override func update() {
        guard let cgl = openGLContext?.cglContextObj else { super.update(); return }
        CGLLockContext(cgl); super.update(); CGLUnlockContext(cgl)
        requestRedraw()
    }
    override func reshape() {
        guard let cgl = openGLContext?.cglContextObj else { super.reshape(); return }
        CGLLockContext(cgl); super.reshape(); openGLContext?.update(); CGLUnlockContext(cgl)
        requestRedraw()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); update() }
    override func draw(_ dirtyRect: NSRect) { requestRedraw() }
    private func requestRedraw() { renderer?.requestDraw(size: convertToBacking(bounds).size) }
    func releaseRenderer() {
        cursorWork?.cancel(); revealCursor()
        renderer?.shutdown(); renderer = nil
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
        revealCursor(); cursorWork?.cancel(); if store?.controlsVisible == false { store?.controlsVisible = true }
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
        renderer?.shutdown()
        if let shutdownObserver { NotificationCenter.default.removeObserver(shutdownObserver) }
        if let cursorObserver { NotificationCenter.default.removeObserver(cursorObserver) }
    }
}

extension Notification.Name { static let lumenRevealCursor = Notification.Name("lumen.revealCursor") }
