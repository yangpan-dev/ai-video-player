import AppKit
import Foundation
import PlayerCore

enum RecognitionMode: String, CaseIterable, Identifiable {
    case stream, batch
    var id: String { rawValue }
    var title: String { self == .stream ? "流式实时" : "整片批量" }
}

struct RecognitionModel: Identifiable {
    let id: String
    let label: String
    let megabytes: Int
    var filename: String { "ggml-\(id).bin" }
    static let all = [RecognitionModel(id: "small", label: "Small", megabytes: 488), RecognitionModel(id: "medium", label: "Medium", megabytes: 1530), RecognitionModel(id: "large-v3-turbo", label: "Large v3 Turbo", megabytes: 1620), RecognitionModel(id: "large-v3", label: "Large v3", megabytes: 3100)]
}

final class AIController: ObservableObject {
    @Published var mode: RecognitionMode = .stream
    @Published var selectedModel = "large-v3-turbo"
    @Published var language = "auto"
    @Published var fromCurrentPosition = true
    @Published var cues: [SubtitleCue] = []
    @Published var display: SubtitleDisplay = .bilingual { didSet { onCuesChanged?(cues) } }
    @Published var running = false
    @Published var status = "本地 AI 字幕：识别原声并翻译为简体中文"
    @Published var percent: Double = 0
    @Published var failure: String?
    @Published var detectedLanguage = ""
    @Published var modelRevision = 0
    @Published var downloading = false
    @Published var downloadPercent: Double = 0
    @Published var downloadLabel = ""
    private var task: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var downloader: ModelDownload?
    private var job: AIJob?
    private var requestID = UUID()
    private var source: URL?
    var onCuesChanged: (([SubtitleCue]) -> Void)?
    var modelReady: Bool { AIRuntime.model("ggml-\(selectedModel).bin") != nil }
    var translationReady: Bool { AIRuntime.model(AIRuntime.translationFile) != nil }
    var translatedCount: Int { cues.filter { !$0.translation.isEmpty }.count }

    func switchVideo(_ url: URL) {
        cancel(); source = url; cues = []; detectedLanguage = ""; failure = nil
        status = "本地 AI 字幕：识别原声并翻译为简体中文"; percent = 0
        if let data = try? Data(contentsOf: cacheURL(url)), let saved = try? JSONDecoder().decode(CachedSubtitles.self, from: data), saved.fingerprint == fingerprint(url) {
            cues = saved.cues; detectedLanguage = saved.language; status = "已恢复 \(cues.count) 条 AI 字幕"
        }
    }
    func cancel() {
        requestID = UUID(); task?.cancel(); task = nil; job?.cancel(); job = nil
        if running { status = "已取消，保留已生成的字幕" }
        running = false
    }
    func start(video: URL, duration: Double, position: Double, audioIndex: Int? = nil) {
        guard duration > 0 else { failure = "请等待视频打开完成"; return }
        guard let whisperModel = AIRuntime.model("ggml-\(selectedModel).bin") else { failure = "请先下载或选择 Whisper 模型目录"; return }
        guard let translationModel = AIRuntime.model(AIRuntime.translationFile) else { failure = "请先下载翻译模型，或选择旧版模型所在目录"; return }
        cancel(); let id = UUID(); requestID = id
        let operation = AIJob(); job = operation
        let selectedMode = mode, selectedLanguage = language
        let start = mode == .stream && fromCurrentPosition ? min(max(0, position), max(0, duration - 1)) : 0
        cues = []; running = true; percent = 0; failure = nil; detectedLanguage = selectedLanguage
        onCuesChanged?([])
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("PandaPlayer-AI-\(id)")
            defer { operation.stopChildren(); try? FileManager.default.removeItem(at: workspace); if self.requestID == id { self.running = false; self.job = nil } }
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                self.status = "正在加载 Whisper 语音模型…"
                let whisper = try LocalAIServer(name: "whisper-server", model: whisperModel, job: operation, vad: AIRuntime.model("ggml-silero-v6.2.0.bin"))
                try await whisper.ready(job: operation)
                var translator: LocalAIServer?
                var context = [String]()
                var cursor = start
                let window: Double = selectedMode == .stream ? 15 : 60
                let stride = window - 3
                while cursor < duration {
                    try operation.check(); guard self.requestID == id else { throw CancellationError() }
                    self.status = "识别中 · \(PlaybackTime.label(cursor)) / \(PlaybackTime.label(duration)) · \(self.cues.count) 句"
                    let length = min(window, duration - cursor)
                    let wav = workspace.appendingPathComponent("chunk.wav")
                    let map = audioIndex.map { "0:\($0)" } ?? "0:a:0"
                    try await operation.run(AIRuntime.binary("ffmpeg"), ["-hide_banner", "-loglevel", "error", "-y", "-ss", "\(cursor)", "-i", video.path, "-t", "\(length)", "-map", map, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path])
                    let (segments, language) = try await whisper.transcribe(wav: wav, language: selectedLanguage, job: operation)
                    try operation.check(); guard self.requestID == id else { throw CancellationError() }
                    self.detectedLanguage = language
                    let lastEnd = self.cues.last?.end ?? -1
                    let lastWindow = cursor + length >= duration - 0.01
                    let fresh = segments.compactMap { cue -> SubtitleCue? in
                        var value = cue; value.start += cursor; value.end = min(duration, cue.end + cursor)
                        guard value.start >= lastEnd - 0.15, value.end > value.start else { return nil }
                        if !lastWindow && cue.end > length - 0.5 { return nil }
                        return value
                    }
                    self.cues += fresh
                    self.publish(video)
                    if selectedMode == .stream && !fresh.isEmpty {
                        if translator == nil {
                            self.status = "正在加载 Qwen 翻译模型…"
                            translator = try LocalAIServer(name: "llama-server", model: translationModel, job: operation)
                            try await translator!.ready(job: operation)
                        }
                        try await self.translatePending(server: translator!, operation: operation, id: id, video: video, context: &context)
                    }
                    self.percent = min(selectedMode == .stream ? 99 : 70, (cursor + length - start) / max(1, duration - start) * (selectedMode == .stream ? 100 : 70))
                    if lastWindow { break }; cursor += stride
                }
                whisper.stop()
                guard !self.cues.isEmpty else { throw SubtitleError.invalid("没有识别到有效语音。请检查音轨、原声语言或尝试其他模型。") }
                if selectedMode == .batch {
                    self.status = "识别完成，正在加载 Qwen 翻译模型…"
                    let server = try LocalAIServer(name: "llama-server", model: translationModel, job: operation)
                    try await server.ready(job: operation)
                    try await self.translatePending(server: server, operation: operation, id: id, video: video, context: &context)
                }
                try operation.check(); guard self.requestID == id else { throw CancellationError() }
                self.percent = 100; self.status = "已完成 · \(self.cues.count) 句原文 / \(self.translatedCount) 句中文"
                self.publish(video)
            } catch {
                if self.requestID == id && !operation.cancelled.isCancelled {
                    self.failure = error.localizedDescription; self.status = "任务失败，已保留生成结果"
                }
            }
        }
    }
    func translateExisting(video: URL) {
        guard !cues.isEmpty else { failure = "请先导入 SRT/VTT 字幕或识别语音"; return }
        guard let model = AIRuntime.model(AIRuntime.translationFile) else { failure = "请先下载翻译模型"; return }
        cancel(); let id = UUID(); requestID = id; let operation = AIJob(); job = operation
        running = true; failure = nil; percent = 0
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { operation.stopChildren(); if self.requestID == id { self.running = false; self.job = nil } }
            do {
                self.status = "正在加载 Qwen 翻译模型…"
                let server = try LocalAIServer(name: "llama-server", model: model, job: operation)
                try await server.ready(job: operation)
                var context = [String]()
                try await self.translatePending(server: server, operation: operation, id: id, video: video, context: &context)
                guard self.requestID == id else { return }
                self.percent = 100; self.status = "翻译完成 · \(self.translatedCount) 句中文"; self.publish(video)
            } catch { if self.requestID == id && !operation.cancelled.isCancelled { self.failure = error.localizedDescription; self.status = "翻译失败，已保留原文" } }
        }
    }
    @MainActor private func translatePending(server: LocalAIServer, operation: AIJob, id: UUID, video: URL, context: inout [String]) async throws {
        while let first = cues.firstIndex(where: { $0.translation.isEmpty }) {
            try operation.check(); guard requestID == id else { throw CancellationError() }
            let indices = Array(cues.indices.filter { $0 >= first && cues[$0].translation.isEmpty }.prefix(4))
            let lines = indices.map { cues[$0].text }
            status = "翻译中 · \(translatedCount) / \(cues.count) 句"
            let translated: [String]
            do { translated = try await server.translate(lines, language: detectedLanguage.isEmpty ? language : detectedLanguage, context: context, job: operation) }
            catch {
                try operation.check()
                if lines.count == 1 { throw error }
                var singles = [String]()
                for line in lines { singles += try await server.translate([line], language: detectedLanguage, context: context, job: operation) }
                translated = singles
            }
            try operation.check(); guard requestID == id else { throw CancellationError() }
            for (offset, index) in indices.enumerated() { cues[index].translation = translated[offset] }
            context = lines; publish(video)
            if mode == .batch { percent = 70 + Double(translatedCount) / Double(max(1, cues.count)) * 30 }
        }
    }
    func importCues(_ values: [SubtitleCue], video: URL) { cancel(); cues = values; display = .bilingual; status = "已导入 \(values.count) 条字幕，可继续翻译为中文"; publish(video) }
    private struct CachedSubtitles: Codable { var fingerprint: String; var language: String; var cues: [SubtitleCue] }
    private func fingerprint(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    private func cacheURL(_ url: URL) -> URL {
        // Stable FNV-1a; cache identity includes the full original path.
        let hash = url.path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return AIRuntime.appSupport.appendingPathComponent("subtitles/\(String(hash, radix: 16)).json")
    }
    private func publish(_ video: URL) {
        guard source == video else { return }
        onCuesChanged?(cues)
        let url = cacheURL(video)
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(CachedSubtitles(fingerprint: fingerprint(video), language: detectedLanguage, cues: cues)).write(to: url, options: .atomic) }
        catch { failure = "字幕已生成，但缓存保存失败：\(error.localizedDescription)" }
    }
    func chooseModelsDirectory() {
        let panel = NSOpenPanel(); panel.title = "选择 Whisper / Qwen 模型目录"; panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: "aiModelsDirectory"); modelRevision += 1 }
    }
    func download(translation: Bool = false) {
        guard !downloading else { return }
        let model = RecognitionModel.all.first { $0.id == selectedModel }!
        let filename = translation ? AIRuntime.translationFile : model.filename
        let path = translation ? "bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/\(filename)" : "ggerganov/whisper.cpp/resolve/main/\(filename)"
        downloading = true; downloadPercent = 0; downloadLabel = translation ? "Qwen2.5-7B（约 4.4 GB）" : model.label; failure = nil
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloading = false; self.downloader = nil; self.modelRevision += 1 }
            do {
                let destination = AIRuntime.appSupport.appendingPathComponent("models/\(filename)")
                var last: Error?
                for endpoint in ["https://hf-mirror.com", "https://huggingface.co"] {
                    try Task.checkCancellation()
                    let download = ModelDownload(); self.downloader = download
                    do { try await download.fetch(URL(string: "\(endpoint)/\(path)")!, destination: destination) { [weak self] value in self?.downloadPercent = value }; last = nil; break }
                    catch { if Task.isCancelled { throw CancellationError() }; last = error }
                }
                if let last { throw last }
                self.status = "\(self.downloadLabel) 模型已就绪"
            } catch { if !Task.isCancelled { self.failure = "模型下载失败：\(error.localizedDescription)" } }
        }
    }
    func cancelDownload() { downloadTask?.cancel(); downloader?.cancel() }
    func shutdown() { cancel(); cancelDownload(); ManagedChild.stopAllAndWait() }
}

final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL!
    private var progress: ((Double) -> Void)?
    func fetch(_ url: URL, destination: URL, progress: @escaping (Double) -> Void) async throws {
        self.destination = destination; self.progress = progress
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.default; configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 24 * 3600
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            let resume = destination.appendingPathExtension("resume")
            if let data = try? Data(contentsOf: resume) { task = session!.downloadTask(withResumeData: data) }
            else { task = session!.downloadTask(with: url) }
            task?.resume()
        }
    }
    func cancel() {
        task?.cancel(byProducingResumeData: { [weak self] data in
            if let data, let destination = self?.destination { try? data.write(to: destination.appendingPathExtension("resume"), options: .atomic) }
        })
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, [200,206].contains(response.statusCode), (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 10_000_000 else { throw SubtitleError.invalid("下载内容不是有效模型文件") }
            let staged = destination.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: staged); try FileManager.default.moveItem(at: location, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staged, to: destination)
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("resume"))
            finish(nil)
        } catch { finish(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: destination.appendingPathExtension("resume"), options: .atomic) }
            finish(error)
        }
    }
    private func finish(_ error: Error?) {
        guard let continuation else { return }; self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        session?.finishTasksAndInvalidate()
    }
}
