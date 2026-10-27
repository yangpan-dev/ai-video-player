import AppKit

// Exercises actual native fullscreen transitions with a real decoder and a main-runloop heartbeat.
// Uses PANDAPLAYER_STATE_DIR in the test script; never reads or captures the user's desktop.
final class FullscreenProbe {
    private let store: PlayerStore
    private let window: NSWindow
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var samples = [Double]()
    private var steps = [[String: Any]]()
    private var transitionStart: Double?
    private var transitionFrame = 0
    private var started = false
    private var finished = false
    private var pausedResizePassed = false
    private weak var videoView: MPVVideoView?
    private var geometry = [[String: Any]]()
    private var lastInsets = [Double]()
    private var settling = false
    private var lateInsetChanges = 0
    private var overlayStable = true
    private var outOfBoundsDuringTransition = 0

    private func findVideo(_ view: NSView) -> MPVVideoView? {
        if let video = view as? MPVVideoView { return video }
        return view.subviews.lazy.compactMap { self.findVideo($0) }.first
    }
    private func recordGeometry(_ event: String = "tick") {
        guard let root = window.contentView else { return }
        if videoView == nil { videoView = findVideo(root) }
        guard let videoView else { return }
        let rect = videoView.convert(videoView.bounds, to: root)
        let insets = [rect.minX, root.bounds.width - rect.maxX, rect.minY, root.bounds.height - rect.maxY].map { (Double($0) * 10).rounded() / 10 }
        guard insets != lastInsets || event != "tick" else { return }
        if settling && !lastInsets.isEmpty && insets != lastInsets { lateInsetChanges += 1 }
        if transitionStart != nil && insets.contains(where: { $0 < -0.5 }) { outOfBoundsDuringTransition += 1 }
        lastInsets = insets
        geometry.append(["event": event, "insets": insets, "window": [window.frame.width, window.frame.height], "video": [rect.width, rect.height], "fullscreen": store.isFullscreen])
    }

    init(store: PlayerStore, window: NSWindow) {
        self.store = store; self.window = window
        store.muted = true; store.autoNext = false; store.repeatFile = true
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in self?.didTransition(note.name == NSWindow.didEnterFullScreenNotification) })
        }
        timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { [weak self] in
            guard self != nil else { return }
            fputs("FAIL: fullscreen test timed out\n", stderr); exit(1)
        }
    }
    private func tick() {
        recordGeometry()
        let now = ProcessInfo.processInfo.systemUptime
        if started { samples.append(max(0, now - previousTick - 0.01) * 1000) }
        previousTick = now
        if !started && store.renderedFrameCount >= 12 && store.duration > 0 {
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.toggle() }
        }
    }
    private func toggle() {
        guard !finished else { return }
        settling = false; recordGeometry("before")
        transitionStart = ProcessInfo.processInfo.systemUptime; transitionFrame = store.renderedFrameCount
        store.toggleFullscreen()
        store.toggleFullscreen() // A repeated click during the transition must be ignored.
    }
    private func didTransition(_ fullscreen: Bool) {
        guard let start = transitionStart else { return }
        transitionStart = nil
        settling = true; recordGeometry("didTransition")
        if fullscreen, let videoView {
            let frame = videoView.frame
            store.controlsVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.window.contentView?.layoutSubtreeIfNeeded()
                self.overlayStable = self.overlayStable && self.videoView?.frame == frame
                self.store.controlsVisible = true
            }
        }
        steps.append(["fullscreen": fullscreen, "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000, "frames": store.renderedFrameCount - transitionFrame])
        if steps.count < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.toggle() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.verifyPausedResize() }
        }
    }
    private func verifyPausedResize() {
        settling = false
        store.engine?.set("pause", "yes")
        let before = store.engine?.number("time-pos") ?? 0
        let frames = store.renderedFrameCount
        let size = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        window.setContentSize(NSSize(width: size.width + 40, height: size.height + 20))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.pausedResizePassed = self.store.renderedFrameCount > frames && abs((self.store.engine?.number("time-pos") ?? 0) - before) < 0.1
            self.finish()
        }
    }
    private func finish() {
        finished = true; timer?.invalidate()
        let sorted = samples.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let passed = steps.count == 4 && !store.isFullscreen && store.renderedFrameCount > 30 && store.error == nil && pausedResizePassed && lateInsetChanges == 0 && overlayStable && outOfBoundsDuringTransition == 0 && store.rendererCreationCount == 1 && store.renderStatistics.snapshot.mainThreadFrames == 0 && store.renderStatistics.snapshot.verifiedPixels && steps.allSatisfy { ($0["frames"] as? Int ?? 0) > 0 && ($0["milliseconds"] as? Double ?? 0) < 2500 }
        let report: [String: Any] = ["fullscreenTest": passed ? "passed" : "failed", "lateInsetChanges": lateInsetChanges, "overlayStable": overlayStable, "outOfBoundsDuringTransition": outOfBoundsDuringTransition, "geometry": geometry, "steps": steps, "mainThreadLagP95Ms": p95, "mainThreadLagMaxMs": sorted.last ?? 0, "renderedFrames": store.renderedFrameCount, "rendererCreations": store.rendererCreationCount, "mainThreadRenderedFrames": store.renderStatistics.snapshot.mainThreadFrames, "verifiedVideoPixels": store.renderStatistics.snapshot.verifiedPixels, "pausedResize": pausedResizePassed, "hwdec": store.engine?.string("hwdec-current") ?? "", "error": store.error ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
        store.shutdown(); exit(passed ? 0 : 1)
    }
    deinit { timer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
}
