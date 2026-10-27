import AppKit
import SwiftUI
import PlayerCore

@main
enum PandaPlayerMain {
    static func main() {
        if CommandLine.arguments.contains("--ai-test") { AIIntegrationTest.run(); return }
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--render-test") { SmokeTest.run(); return }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: PlayerStore!
    private var window: NSWindow!
    private var pendingURLs = [URL]()
    private var fullscreenProbe: FullscreenProbe?
    func applicationDidFinishLaunching(_ notification: Notification) {
        store = PlayerStore()
        let root = ContentView(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "熊猫播放器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.08, alpha: 1)
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrameAutosaveName("PandaPlayerMainWindow")
        window.center(); store.window = window
        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        let urls = pendingURLs + arguments
        if !urls.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.store.add(urls) } }
        if CommandLine.arguments.contains("--fullscreen-test") { fullscreenProbe = FullscreenProbe(store: store, window: window) }
        if CommandLine.arguments.contains("--settings-test") {
            for (index, section) in SettingsSection.allCases.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 0.6) { self.store.openSettings(section) }
            }
        }
        if CommandLine.arguments.contains("--window-test") {
            store.muted = true
            let testSettings = CommandLine.arguments.contains("--settings-test")
            DispatchQueue.main.asyncAfter(deadline: .now() + (testSettings ? 4.5 : 3)) {
                let subtitles = self.store.engine?.string("sub-text") ?? ""
                let checkSubtitles = !CommandLine.arguments.contains("--subtitle-test") || subtitles.contains("熊猫")
                let checkFolders = !CommandLine.arguments.contains("--folder-test") || self.store.playlist.count >= 3
                let checkSettings = !testSettings || (self.store.settingsVisible && self.store.settingsSection == .playback && self.window.attachedSheet != nil)
                let passed = self.store.renderedFrameCount > 0 && self.store.duration > 0 && self.store.error == nil && checkSubtitles && checkFolders && checkSettings && self.store.renderStatistics.snapshot.verifiedPixels
                let report: [String: Any] = ["window": passed ? "passed" : "failed", "renderedFrames": self.store.renderedFrameCount, "duration": self.store.duration, "error": self.store.error ?? "", "playlist": self.store.playlist.count, "subtitles": subtitles, "sid": self.store.engine?.string("sid") ?? "", "subVisible": self.store.engine?.string("sub-visibility") ?? "", "position": self.store.position, "verifiedVideoPixels": self.store.renderStatistics.snapshot.verifiedPixels, "mainThreadRenderedFrames": self.store.renderStatistics.snapshot.mainThreadFrames, "settingsSheet": self.window.attachedSheet != nil, "settingsSection": self.store.settingsSection.rawValue, "tracks": self.store.tracks.map { "\($0.id):\($0.label)" }]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
                self.store.shutdown()
                exit(passed ? 0 : 1)
            }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let store { store.add(urls) } else { pendingURLs += urls }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
    func windowWillEnterFullScreen(_ notification: Notification) { store.beginFullscreenTransition() }
    func windowWillExitFullScreen(_ notification: Notification) { store.beginFullscreenTransition() }
    func windowDidEnterFullScreen(_ notification: Notification) { store.finishFullscreenTransition(true) }
    func windowDidExitFullScreen(_ notification: Notification) { store.finishFullscreenTransition(false) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { store.finishFullscreenTransition(false) }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { store.finishFullscreenTransition(true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }

    private func installMenu() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); item.title = title; let menu = NSMenu(title: title); item.submenu = menu; bar.addItem(item); return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: key); value.target = self; value.keyEquivalentModifierMask = modifiers; menu.addItem(value)
        }
        let app = menu("熊猫播放器")
        item(app, "关于熊猫播放器", #selector(about)); app.addItem(.separator())
        item(app, "设置…", #selector(settings), ","); app.addItem(.separator())
        item(app, "隐藏熊猫播放器", #selector(hideApp), "h"); app.addItem(.separator())
        item(app, "退出熊猫播放器", #selector(quit), "q")
        let file = menu("文件")
        item(file, "打开视频…", #selector(openVideo), "o")
        item(file, "添加文件夹…", #selector(openFolder), "o", [.command, .shift])
        item(file, "加载字幕…", #selector(openSubtitles), "l")
        item(file, "保存截图…", #selector(capture), "s", [.command, .shift])
        let edit = menu("编辑")
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let playback = menu("播放")
        item(playback, "播放 / 暂停", #selector(playPause), " ", [])
        item(playback, "后退 5 秒", #selector(backward), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [])
        item(playback, "前进 5 秒", #selector(forward), String(UnicodeScalar(NSRightArrowFunctionKey)!), [])
        item(playback, "上一个视频", #selector(previous), "[", .command)
        item(playback, "下一个视频", #selector(next), "]", .command)
        let view = menu("显示")
        item(view, "进入 / 退出全屏", #selector(fullscreen), "f", [.command, .control])
        item(view, "显示 / 隐藏播放列表", #selector(sidebar), "1")
        item(view, "画面设置…", #selector(inspector), "2")
        item(view, "对比原片", #selector(compare), "b")
        NSApplication.shared.mainMenu = bar
    }
    @objc private func openVideo() { store.openPanel() }
    @objc private func openFolder() { store.openPanel(folder: true) }
    @objc private func openSubtitles() { store.subtitlePanel() }
    @objc private func capture() { store.screenshot() }
    @objc private func playPause() { store.togglePlay() }
    @objc private func backward() { store.jump(-5) }
    @objc private func forward() { store.jump(5) }
    @objc private func previous() { store.adjacent(-1) }
    @objc private func next() { store.adjacent(1) }
    @objc private func fullscreen() { store.toggleFullscreen() }
    @objc private func sidebar() { store.sidebarVisible.toggle() }
    @objc private func settings() { store.openSettings() }
    @objc private func inspector() { store.openSettings(.picture) }
    @objc private func compare() { store.compareOriginal.toggle() }
    @objc private func hideApp() { NSApplication.shared.hide(nil) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func about() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "熊猫播放器", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1", .credits: NSAttributedString(string: "原生 macOS AI 视频播放器\nSwiftUI · AppKit · libmpv\nWhisper 语音识别 · Qwen 本地翻译\n高质量缩放 · 多格式播放 · 递归视频列表")])
    }
}
