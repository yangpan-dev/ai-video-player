import Foundation
import Darwin
import PlayerCore

final class ManagedChild: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [UUID: ManagedChild] = [:]
    private let id = UUID()
    let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var tail = Data()
    var log: String { lock.lock(); defer { lock.unlock() }; return String(decoding: tail, as: UTF8.self) }
    init(binary: URL, arguments: [String]) {
        process.executableURL = binary; process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardOutput = output; process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["GGML_METAL_PATH_RESOURCES"] = binary.deletingLastPathComponent().path
        process.environment = environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock(); self.tail.append(data)
            if self.tail.count > 24_000 { self.tail = self.tail.suffix(24_000) }
            self.lock.unlock()
        }
    }
    func launch() throws {
        Self.registryLock.lock(); Self.registry[id] = self; Self.registryLock.unlock()
        let identifier = id
        process.terminationHandler = { _ in
            Self.registryLock.lock(); Self.registry.removeValue(forKey: identifier); Self.registryLock.unlock()
        }
        do { try process.run() }
        catch { Self.registryLock.lock(); Self.registry.removeValue(forKey: id); Self.registryLock.unlock(); throw error }
    }
    static func stopAllAndWait() {
        registryLock.lock(); let values = Array(registry.values); registryLock.unlock()
        values.forEach { $0.stop() }
        let deadline = Date().addingTimeInterval(2)
        while values.contains(where: { $0.process.isRunning }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        for value in values where value.process.isRunning { kill(value.process.processIdentifier, SIGKILL); value.process.waitUntilExit() }
    }
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.process.waitUntilExit()
                self.output.fileHandleForReading.readabilityHandler = nil
                if self.process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: SubtitleError.invalid("引擎执行失败（\(self.process.terminationStatus)）：\n\(self.log.suffix(1000))")) }
            }
        }
    }
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    deinit { output.fileHandleForReading.readabilityHandler = nil; if process.isRunning { process.terminate() } }
}

final class AIJob: @unchecked Sendable {
    let cancelled = CancellationFlag()
    private let lock = NSLock()
    private var children = [ManagedChild]()
    func check() throws { if cancelled.isCancelled || Task.isCancelled { throw CancellationError() } }
    func launch(_ binary: URL, _ arguments: [String]) throws -> ManagedChild {
        try check()
        let child = ManagedChild(binary: binary, arguments: arguments)
        lock.lock(); children.append(child); lock.unlock()
        try child.launch()
        if cancelled.isCancelled { child.stop(); throw CancellationError() }
        return child
    }
    func run(_ binary: URL, _ arguments: [String]) async throws {
        let child = try launch(binary, arguments)
        defer { release(child) }
        try await child.wait(); try check()
    }
    private func release(_ child: ManagedChild) { lock.lock(); children.removeAll { $0 === child }; lock.unlock() }
    func cancel() { cancelled.cancel(); stopChildren() }
    func stopChildren() {
        lock.lock(); let values = children; children.removeAll(); lock.unlock()
        values.forEach { $0.stop() }
    }
    deinit { stopChildren() }
}

enum AIRuntime {
    static let translationFile = "Qwen2.5-7B-Instruct-Q4_K_M.gguf"
    static var appSupport: URL {
        if let custom = ProcessInfo.processInfo.environment["PANDAPLAYER_STATE_DIR"] ?? ProcessInfo.processInfo.environment["PANDAPLAYER_STATE_DIR"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PandaPlayer")
    }
    static var modelDirectories: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directories = [appSupport.appendingPathComponent("models")]
        if let custom = UserDefaults.standard.string(forKey: "aiModelsDirectory") { directories.insert(URL(fileURLWithPath: custom), at: 0) }
        directories += ["local-ai-video-player/models", "AIVideoPlayer/models", "PandaPlayer/models"].map { support.appendingPathComponent($0) }
        if let custom = ProcessInfo.processInfo.environment["PANDAPLAYER_MODELS"] { directories.insert(URL(fileURLWithPath: custom), at: 0) }
        return directories
    }
    static func model(_ name: String) -> URL? {
        modelDirectories.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 100_000 }
    }
    static func binary(_ name: String) throws -> URL {
        var candidates = [URL]()
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("AIEngine/\(name)")) }
        if let custom = ProcessInfo.processInfo.environment["PANDAPLAYER_AI_BIN"] { candidates.insert(URL(fileURLWithPath: custom).appendingPathComponent(name), at: 0) }
        #if DEBUG
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(project.deletingLastPathComponent().appendingPathComponent("resources/bin/darwin-arm64/\(name)"))
        if name == "ffmpeg" { candidates.append(project.deletingLastPathComponent().appendingPathComponent("node_modules/ffmpeg-static/ffmpeg")) }
        #endif
        candidates += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw SubtitleError.invalid("缺少 \(name) 引擎，请使用包含 AI 引擎的 PandaPlayer 安装包。") }
        return found
    }
    static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SubtitleError.invalid("无法创建本地服务端口") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard status == 0 else { throw SubtitleError.invalid("无法绑定本地服务端口") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard result == 0 else { throw SubtitleError.invalid("无法读取本地服务端口") }
        return UInt16(bigEndian: address.sin_port)
    }
}

final class LocalAIServer {
    let child: ManagedChild
    let endpoint: URL
    init(name: String, model: URL, job: AIJob, vad: URL? = nil) throws {
        let port = try AIRuntime.freePort()
        endpoint = URL(string: "http://127.0.0.1:\(port)")!
        var arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port)]
        if name == "llama-server" { arguments += ["-ngl", "99", "--ctx-size", "4096", "--batch-size", "256", "--parallel", "1"] }
        else if let vad { arguments += ["--vad", "-vm", vad.path] }
        child = try job.launch(AIRuntime.binary(name), arguments)
    }
    func ready(job: AIJob) async throws {
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try job.check()
            if !child.process.isRunning { throw SubtitleError.invalid("AI 引擎启动失败（退出码 \(child.process.terminationStatus)）：\n\(child.log.suffix(1200))") }
            var request = URLRequest(url: endpoint.appendingPathComponent("health")); request.timeoutInterval = 2
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return }
            } catch is CancellationError { throw CancellationError() } catch {}
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw SubtitleError.invalid("AI 模型加载超时：\n\(child.log.suffix(800))")
    }
    func transcribe(wav: URL, language: String, job: AIJob) async throws -> ([SubtitleCue], String) {
        try job.check()
        let boundary = "PandaPlayer-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in [("language", language), ("response_format", "verbose_json"), ("temperature", "0.0")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wav)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint.appendingPathComponent("inference"))
        request.httpMethod = "POST"; request.timeoutInterval = 600; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, job: job)
        struct Segment: Decodable { var start: Double?; var end: Double?; var text: String?; var no_speech_prob: Double? }
        struct Response: Decodable { var language: String?; var segments: [Segment]? }
        let result = try JSONDecoder().decode(Response.self, from: data)
        let cues = (result.segments ?? []).compactMap { segment -> SubtitleCue? in
            let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, (segment.no_speech_prob ?? 0) < 0.65, let start = segment.start, let end = segment.end, end > start else { return nil }
            return SubtitleCue(start: start, end: end, text: text)
        }
        return (cues, result.language ?? language)
    }
    func translate(_ lines: [String], language: String, context: [String], job: AIJob) async throws -> [String] {
        let label = language == "ja" ? "日语" : language == "en" ? "英语" : "外语"
        let system = "你是影视字幕翻译专家。将\(label)对白译为自然、口语化的简体中文，保持人物语气。输入是 JSON 字幕数组。严格输出 JSON 对象 {\"translations\":[\"译文\"]}，数组长度及顺序必须与输入一致。不要解释，不要合并或遗漏字幕。"
        let input = try JSONSerialization.data(withJSONObject: ["context": context, "lines": lines], options: [.sortedKeys])
        let payload: [String: Any] = ["messages": [["role": "system", "content": system], ["role": "user", "content": String(decoding: input, as: UTF8.self)]], "temperature": 0.2, "max_tokens": 1600, "stream": false, "response_format": ["type": "json_object"]]
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await send(request, job: job)
        struct Message: Decodable { var content: String? }
        struct Choice: Decodable { var message: Message? }
        struct Response: Decodable { var choices: [Choice]? }
        let content = try JSONDecoder().decode(Response.self, from: data).choices?.first?.message?.content ?? ""
        guard let begin = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), begin <= end else { throw SubtitleError.invalid("翻译模型没有返回有效译文，请重试") }
        struct Translation: Decodable { var translations: [String] }
        let result = try JSONDecoder().decode(Translation.self, from: Data(content[begin...end].utf8)).translations
        guard result.count == lines.count, result.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw SubtitleError.invalid("翻译句数与原文不一致，已保留原文，请重试翻译") }
        return result
    }
    private func send(_ request: URLRequest, job: AIJob) async throws -> Data {
        try job.check()
        let (data, response) = try await URLSession.shared.data(for: request)
        try job.check()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw SubtitleError.invalid("AI 请求失败：\(String(decoding: data.prefix(700), as: UTF8.self))") }
        return data
    }
    func stop() { child.stop() }
}
