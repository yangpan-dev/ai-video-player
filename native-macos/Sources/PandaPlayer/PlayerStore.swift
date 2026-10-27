import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import PlayerCore

struct MediaTrack: Identifiable {
    let id: Int
    let type: String
    let label: String
}

struct SavedLibrary: Codable {
    var playlist: [MediaItem] = []
    var recent: [MediaItem] = []
    var progress: [String: Double] = [:]
}

final class PlayerStore: ObservableObject {
    let ai = AIController()
    @Published var isScanning = false
    @Published var scanCount = 0
    @Published var importStatus = ""
    @Published var sortByName = false
    @Published var playlist: [MediaItem] = []
    @Published var recent: [MediaItem] = []
    @Published var current: MediaItem?
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 75 { didSet { engine?.set("volume", "\(volume.clamped(to: 0...100))"); defaults.set(volume, forKey: "volume") } }
    @Published var speed: Double = 1 { didSet { engine?.set("speed", "\(speed)") } }
    @Published var muted = false { didSet { engine?.set("mute", muted ? "yes" : "no") } }
    @Published var settingsVisible = false
    @Published var settingsSection: SettingsSection = .subtitles
    @Published var mediaDetailsExpanded = false
    @Published var sidebarVisible = true
    @Published var compareOriginal = false { didSet { applyPicture() } }
    @Published var preset: PicturePreset = .balanced
    @Published var picture = PicturePreset.balanced.settings { didSet { schedulePicture() } }
    @Published var error: String?
    @Published var notice: String?
    @Published var engineReady = false
    @Published var resolution = ""
    @Published var codec = ""
    @Published var hardware = ""
    @Published var fps: Double = 0
    @Published var droppedFrames: Double = 0
    @Published var tracks: [MediaTrack] = []
    @Published var audioID = 0
    @Published var subtitleID = 0
    @Published var subtitleDelay: Double = 0 { didSet { engine?.set("sub-delay", "\(subtitleDelay)") } }
    @Published var subtitleSize: Double = 42 { didSet { engine?.set("sub-font-size", "\(subtitleSize)") } }
    @Published var aspect = "-1" { didSet { engine?.set("video-aspect-override", aspect) } }
    @Published var autoNext = true { didSet { defaults.set(autoNext, forKey: "autoNext") } }
    @Published var repeatFile = false { didSet { engine?.set("loop-file", repeatFile ? "inf" : "no") } }
    @Published var alwaysOnTop = false { didSet { window?.level = alwaysOnTop ? .floating : .normal } }
    @Published var isFullscreen = false
    private(set) var fullscreenTransitioning = false
    @Published var controlsVisible = true
    @Published var search = ""
    @Published var selectedSection = "playlist"
    @Published var isScrubbing = false
    @Published var dropTargeted = false
    weak var window: NSWindow?
    let renderStatistics = VideoRenderStatistics()
    var renderedFrameCount: Int { renderStatistics.snapshot.frames }
    var rendererCreationCount: Int { renderStatistics.snapshot.creations }
    private(set) var engine: MPVEngine?
    private var timer: Timer?
    private var pictureWork: DispatchWorkItem?
    private var progress: [String: Double] = [:]
    private var tickCount = 0
    private var pendingResume: Double?
    private var scanTask: Task<Void, Never>?
    private var scanCancellation = CancellationFlag()
    private var scanID = UUID()
    private var aiSubscription: AnyCancellable?
    private var generatedSubtitleID: Int?
    private var renderedSubtitlesURL: URL?
    private let defaults: UserDefaults
    private let storageURL: URL

    init() {
        let ephemeral = ProcessInfo.processInfo.environment["PANDAPLAYER_STATE_DIR"]
        defaults = ephemeral != nil ? UserDefaults(suiteName: "dev.panda.player.testing")! : .standard
        let root = ephemeral.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PandaPlayer")
        storageURL = root.appendingPathComponent("library.json")
        let legacyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LumenPlayer/library.json")
        let libraryURL = ephemeral == nil && !FileManager.default.fileExists(atPath: storageURL.path) ? legacyURL : storageURL
        if let data = try? Data(contentsOf: libraryURL), let saved = try? JSONDecoder().decode(SavedLibrary.self, from: data) {
            playlist = saved.playlist; recent = saved.recent; progress = saved.progress
        }
        if defaults.object(forKey: "volume") != nil { volume = defaults.double(forKey: "volume").clamped(to: 0...100) }
        if defaults.object(forKey: "autoNext") != nil { autoNext = defaults.bool(forKey: "autoNext") }
        if let data = defaults.data(forKey: "picture"), let value = try? JSONDecoder().decode(PictureSettings.self, from: data) { picture = value }
        if let value = defaults.string(forKey: "preset"), let selected = PicturePreset(rawValue: value) { preset = selected }
        do {
            let player = try MPVEngine()
            engine = player; engineReady = true
            player.onFileLoaded = { [weak self] in self?.fileLoaded() }
            player.onFailure = { [weak self] message in self?.isLoading = false; self?.isPlaying = false; self?.error = "无法播放此文件：\(message)" }
            player.onEnd = { [weak self] in self?.ended() }
            _ = player.set("volume", "\(volume)")
            applyPicture()
        } catch { self.error = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        ai.onCuesChanged = { [weak self] _ in self?.updateAISubtitles() }
        aiSubscription = ai.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var visibleItems: [MediaItem] {
        let items = selectedSection == "recent" ? recent : orderedPlaylist
        return search.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
    var audioTracks: [MediaTrack] { tracks.filter { $0.type == "audio" } }
    var subtitleTracks: [MediaTrack] { tracks.filter { $0.type == "sub" } }
    var orderedPlaylist: [MediaItem] { sortByName ? playlist.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending } : playlist }

    func openPanel(folder: Bool = false, append: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = folder ? "添加视频文件夹" : "打开视频"
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = true
        // Do not restrict to UTType.movie: many containers are not registered by macOS.
        panel.message = folder ? "递归扫描全部子文件夹，将视频加入播放列表，自动去重。" : "支持 MKV、MP4、AVI、MOV、WebM、TS 等视频格式"
        if panel.runModal() == .OK { add(panel.urls, play: !folder && !append) }
    }
    func add(_ urls: [URL], play: Bool = true) {
        scanCancellation.cancel(); scanTask?.cancel()
        let id = UUID(), cancellation = CancellationFlag(); scanID = id; scanCancellation = cancellation
        isScanning = true; scanCount = 0; importStatus = "正在扫描文件夹及全部子文件夹…"
        scanTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                MediaScanner.scan(urls, cancellation: cancellation) { count in
                    DispatchQueue.main.async { [weak self] in if self?.scanID == id { self?.scanCount = count } }
                }
            }.value
            guard let self, self.scanID == id else { return }
            self.isScanning = false
            guard !result.cancelled else { self.importStatus = "已取消扫描"; return }
            var known = Set(self.playlist.map { $0.url.resolvingSymlinksInPath().path })
            var added = 0
            for url in result.videos where known.insert(url.path).inserted { self.playlist.append(MediaItem(url: url)); added += 1 }
            self.scanCount = result.videos.count
            self.importStatus = "找到 \(result.videos.count) 个视频，新增 \(added) 个" + (result.unreadable.isEmpty ? "" : "，\(result.unreadable.count) 处无法读取")
            self.save()
            if play, let first = result.videos.first { self.open(MediaItem(url: first)) }
            for subtitle in result.subtitles { self.loadSubtitle(subtitle) }
        }
    }
    func open(_ item: MediaItem) {
        guard let engine else { error = "播放引擎尚未就绪，请查看项目 README 的运行说明。"; return }
        guard FileManager.default.fileExists(atPath: item.url.path) else { error = "找不到文件：\(item.url.path)"; return }
        rememberPosition()
        ai.switchVideo(item.url)
        generatedSubtitleID = nil
        if let old = renderedSubtitlesURL { try? FileManager.default.removeItem(at: old) }; renderedSubtitlesURL = nil
        current = item; position = 0; duration = 0; isLoading = true; isPlaying = false
        resolution = ""; codec = ""; tracks = []; audioID = 0; subtitleID = 0
        pendingResume = progress[item.id]; error = nil
        recent.removeAll { $0.id == item.id }; recent.insert(item, at: 0); recent = Array(recent.prefix(100))
        window?.title = "\(item.title) — 熊猫播放器"
        engine.open(item.url)
        engine.set("pause", "no")
        save()
    }
    private func fileLoaded() {
        guard let engine else { return }
        isLoading = false; duration = engine.number("duration"); isPlaying = engine.string("pause") != "yes"
        if let resume = PlaybackTime.resumePosition(saved: pendingResume, duration: duration) {
            _ = engine.command(["seek", "\(resume)", "absolute+exact"])
            showNotice("继续上次播放 · \(PlaybackTime.label(resume))")
        }
        pendingResume = nil
        engine.set("speed", "\(speed)"); engine.set("sub-delay", "\(subtitleDelay)")
        engine.set("sub-font-size", "\(subtitleSize)"); engine.set("video-aspect-override", aspect)
        applyPicture(); readTracks(); refresh()
        if CommandLine.arguments.contains("--subtitle-test"), let current {
            ai.importCues([SubtitleCue(start: 0, end: 10, text: "PandaPlayer subtitle check", translation: "熊猫播放器字幕测试")], video: current.url)
        }
        updateAISubtitles()
    }
    func refresh() {
        guard let engine, current != nil else { return }
        if !isScrubbing { position = engine.number("time-pos") }
        duration = engine.number("duration")
        isPlaying = engine.string("pause") != "yes" && !isLoading && engine.string("eof-reached") != "yes"
        tickCount += 1
        if tickCount % 4 == 0 {
            let width = Int(engine.number("video-params/w")), height = Int(engine.number("video-params/h"))
            resolution = width > 0 ? "\(width) × \(height)" : ""
            codec = engine.string("video-format")?.uppercased() ?? ""
            hardware = engine.string("hwdec-current") ?? "no"
            fps = engine.number("container-fps"); droppedFrames = engine.number("frame-drop-count")
            readTracks()
        }
        if tickCount % 20 == 0 { rememberPosition(); save() }
    }
    func togglePlay() {
        guard let engine, current != nil else { openPanel(); return }
        if engine.string("eof-reached") == "yes" { seek(0) }
        engine.command(["cycle", "pause"]); refresh()
        controlsVisible = true
        if !isPlaying { NotificationCenter.default.post(name: .lumenRevealCursor, object: nil) }
    }
    func seek(_ seconds: Double) {
        guard duration > 0 else { return }
        let target = seconds.clamped(to: 0...duration)
        engine?.command(["seek", "\(target)", "absolute+exact"]); position = target
    }
    func jump(_ seconds: Double) { seek(position + seconds) }
    func adjacent(_ delta: Int) {
        let items = orderedPlaylist
        guard let current, let index = items.firstIndex(where: { $0.id == current.id }), items.indices.contains(index + delta) else { return }
        open(items[index + delta])
    }
    private func ended() {
        isPlaying = false
        if let current { progress.removeValue(forKey: current.id) }
        if autoNext && !repeatFile { adjacent(1) }
        save()
    }
    func remove(_ item: MediaItem) { playlist.removeAll { $0.id == item.id }; save() }
    func clearList() { playlist.removeAll(); save() }
    func setPreset(_ value: PicturePreset) { preset = value; picture = value.settings; defaults.set(value.rawValue, forKey: "preset") }
    private func schedulePicture() {
        pictureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPicture() }
        pictureWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func applyPicture() {
        guard let engine else { return }
        let failures = engine.apply(compareOriginal ? PicturePreset.original.settings : picture)
        if !failures.isEmpty { error = "部分画面设置未能应用：\n" + failures.joined(separator: "\n") }
        if let data = try? JSONEncoder().encode(picture) { defaults.set(data, forKey: "picture") }
    }
    func selectAudio(_ id: Int) { engine?.set("aid", "\(id)"); audioID = id }
    func selectSubtitle(_ id: Int) { engine?.set("sid", id == 0 ? "no" : "\(id)"); subtitleID = id }
    private func readTracks() {
        guard let engine else { return }
        var result = [MediaTrack]()
        let count = min(Int(engine.number("track-list/count")), 100)
        for index in 0..<max(0, count) {
            let prefix = "track-list/\(index)/"
            let type = engine.string(prefix + "type") ?? ""
            guard type == "audio" || type == "sub" else { continue }
            let id = Int(engine.number(prefix + "id"))
            let title = engine.string(prefix + "title") ?? ""
            let language = engine.string(prefix + "lang") ?? ""
            let codec = engine.string(prefix + "codec") ?? ""
            let label = [title.isEmpty ? "\(type == "audio" ? "音轨" : "字幕") \(id)" : title, language, codec].filter { !$0.isEmpty }.joined(separator: " · ")
            result.append(MediaTrack(id: id, type: type, label: label))
        }
        tracks = result; audioID = Int(engine.string("aid") ?? "") ?? 0; subtitleID = Int(engine.string("sid") ?? "") ?? 0
    }
    func subtitlePanel() {
        guard current != nil else { showNotice("请先打开视频"); return }
        let panel = NSOpenPanel(); panel.title = "加载字幕"; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadSubtitle(url) }
    }
    func loadSubtitle(_ url: URL) {
        guard current != nil else { showNotice("请先打开视频再加载字幕"); return }
        if ["srt", "vtt"].contains(url.pathExtension.lowercased()), let current {
            do { ai.importCues(try SubtitleCodec.read(url), video: current.url); showNotice("字幕已导入，可翻译为中文") }
            catch { self.error = error.localizedDescription }
            return
        }
        let result = engine?.command(["sub-add", url.path, "select"]) ?? -1
        if result < 0 { error = "字幕加载失败" } else { readTracks(); showNotice("字幕已加载") }
    }
    func screenshot() {
        guard current != nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(current!.title)-\(PlaybackTime.label(position).replacingOccurrences(of: ":", with: "-" )).png"
        if panel.runModal() == .OK, let url = panel.url {
            let result = engine?.command(["screenshot-to-file", url.path, "subtitles"]) ?? -1
            if result < 0 { error = "截图失败" } else { showNotice("截图已保存") }
        }
    }
    func toggleFullscreen() {
        guard let window, !fullscreenTransitioning else { return }
        fullscreenTransitioning = true
        window.toggleFullScreen(nil)
    }
    func beginFullscreenTransition() { fullscreenTransitioning = true; controlsVisible = true }
    func finishFullscreenTransition(_ fullscreen: Bool) {
        isFullscreen = fullscreen; fullscreenTransitioning = false; controlsVisible = true
        NotificationCenter.default.post(name: .lumenRevealCursor, object: nil)
    }
    func openSettings(_ section: SettingsSection? = nil) {
        if let section { settingsSection = section }
        settingsVisible = true
    }
    func startAI() {
        guard let current else { showNotice("请先打开视频"); return }
        var audioIndex: Int?
        if let engine {
            for i in 0..<Int(engine.number("track-list/count")) where Int(engine.number("track-list/\(i)/id")) == audioID && engine.string("track-list/\(i)/type") == "audio" {
                audioIndex = Int(engine.number("track-list/\(i)/ff-index", fallback: -1)); break
            }
        }
        ai.start(video: current.url, duration: duration, position: position, audioIndex: audioIndex.flatMap { $0 >= 0 ? $0 : nil })
    }
    func translateSubtitles() { if let current { ai.translateExisting(video: current.url) } }
    func exportSubtitles() {
        guard !ai.cues.isEmpty, let current else { return }
        let panel = NSSavePanel(); panel.title = "导出双语字幕"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]
        panel.nameFieldStringValue = current.title + ".zh.srt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try SubtitleCodec.encode(ai.cues, display: ai.display == .off ? .bilingual : ai.display, vtt: url.pathExtension.lowercased() == "vtt").write(to: url, atomically: true, encoding: .utf8); showNotice("字幕已导出") }
            catch { self.error = error.localizedDescription }
        }
    }
    private func updateAISubtitles() {
        guard current != nil, !isLoading, let engine else { return }
        engine.set("sub-visibility", ai.display == .off ? "no" : "yes")
        guard !ai.cues.isEmpty else {
            if let id = generatedSubtitleID { _ = engine.command(["sub-remove", "\(id)"]); generatedSubtitleID = nil }
            return
        }
        let url = renderedSubtitlesURL ?? AIRuntime.appSupport.appendingPathComponent("subtitles/render-\(UUID().uuidString).srt")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SubtitleCodec.encode(ai.cues, display: ai.display == .off ? .bilingual : ai.display).write(to: url, atomically: true, encoding: .utf8)
            if let id = generatedSubtitleID { _ = engine.command(["sub-reload", "\(id)"]) }
            else {
                let result = engine.command(["sub-add", url.path, "select", "PandaPlayer AI 双语字幕"])
                if result < 0 { throw SubtitleError.invalid("生成字幕加载失败") }
                renderedSubtitlesURL = url; generatedSubtitleID = Int(engine.string("sid") ?? "")
            }
            readTracks()
        } catch { self.error = error.localizedDescription }
    }
    func showNotice(_ message: String) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.notice == message { self?.notice = nil } }
    }
    private func rememberPosition() {
        if let current, position.isFinite, position > 0 { progress[current.id] = position }
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SavedLibrary(playlist: playlist, recent: recent, progress: progress))
            try data.write(to: storageURL, options: .atomic)
        } catch { NSLog("Library save failed: %@", error.localizedDescription) }
    }
    func shutdown() {
        ai.shutdown(); scanCancellation.cancel(); scanTask?.cancel()
        rememberPosition(); save(); timer?.invalidate(); timer = nil; pictureWork?.cancel()
        // Renderer must release its context while its OpenGL context is current.
        NotificationCenter.default.post(name: .lumenShutdown, object: nil)
        engine?.shutdown()
    }
}

extension Notification.Name { static let lumenShutdown = Notification.Name("lumen.shutdown") }
