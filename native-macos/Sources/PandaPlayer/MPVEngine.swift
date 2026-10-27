import AppKit
import CMPV
import PlayerCore

enum EngineError: LocalizedError {
    case unavailable(String)
    case operation(String, Int32)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .operation(let name, let code): return "\(name)：\(String(cString: lumen_error(code)))"
        }
    }
}

final class MPVEngine {
    private(set) var handle: OpaquePointer?
    private(set) var libraryPath = ""
    var onFileLoaded: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onEnd: (() -> Void)?
    private var timer: Timer?
    private var endReported = false

    static var libraryCandidates: [String] {
        var result = [String]()
        if let custom = ProcessInfo.processInfo.environment["PANDAPLAYER_LIBMPV"] { result.append(custom) }
        if let bundled = Bundle.main.privateFrameworksPath {
            result.append(bundled + "/libmpv.2.dylib")
        }
        result += ["/opt/homebrew/lib/libmpv.2.dylib", "/usr/local/lib/libmpv.2.dylib"]
        #if DEBUG
        result.append("/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib")
        #endif
        return result
    }

    init(headless: Bool = false) throws {
        var diagnostics = [String]()
        for path in Self.libraryCandidates where FileManager.default.fileExists(atPath: path) {
            var buffer = [CChar](repeating: 0, count: 4096)
            if lumen_load_library(path, &buffer, buffer.count) == 0 { libraryPath = path; break }
            diagnostics.append(String(cString: buffer))
        }
        guard !libraryPath.isEmpty else {
            throw EngineError.unavailable("尚未找到可用的播放引擎。请安装 mpv（brew install mpv），或使用包含引擎的安装包。" + (diagnostics.first.map { "\n\($0)" } ?? ""))
        }
        guard let player = lumen_create(headless ? 1 : 0) else { throw EngineError.unavailable("播放引擎创建失败") }
        handle = player
        // The embedded OpenGL surface is SDR. Map HDR into this output explicitly.
        _ = lumen_option(player, "target-prim", "bt.709")
        _ = lumen_option(player, "target-trc", "srgb")
        _ = lumen_option(player, "target-peak", "100")
        let result = lumen_initialize(player)
        if result < 0 { lumen_destroy(player); handle = nil; throw EngineError.operation("初始化播放引擎", result) }
        if !headless {
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.pollEvents() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    @discardableResult func command(_ arguments: [String]) -> Int32 {
        guard let handle else { return -1 }
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let pointers = strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        return pointers.withUnsafeBufferPointer { lumen_command(handle, $0.baseAddress) }
    }
    @discardableResult func set(_ name: String, _ value: String) -> Int32 {
        guard let handle else { return -1 }
        return lumen_set(handle, name, value)
    }
    func number(_ name: String, fallback: Double = 0) -> Double {
        guard let handle else { return fallback }
        let value = lumen_number(handle, name, fallback)
        return value.isFinite ? value : fallback
    }
    func string(_ name: String) -> String? {
        guard let handle, let value = lumen_string(handle, name) else { return nil }
        defer { lumen_free_string(value) }
        return String(cString: value)
    }
    func open(_ url: URL) {
        endReported = false
        let result = command(["loadfile", url.path, "replace"])
        if result < 0 { onFailure?(String(cString: lumen_error(result))) }
    }
    func apply(_ picture: PictureSettings) -> [String] {
        picture.properties.compactMap { name, value in
            let result = set(name, value)
            return result < 0 ? "\(name): \(String(cString: lumen_error(result)))" : nil
        }
    }
    func pollEvents() {
        guard let handle else { return }
        for _ in 0..<100 {
            var detail: Int32 = 0
            let event = lumen_poll(handle, &detail)
            if event == 0 { break }
            switch event {
            case 8: onFileLoaded?() // MPV_EVENT_FILE_LOADED
            case 7 where detail < 0: onFailure?(String(cString: lumen_error(detail)))
            default: break
            }
        }
        // keep-open=yes pauses at EOF instead of unloading the file.
        let atEnd = string("eof-reached") == "yes"
        if atEnd && !endReported { endReported = true; onEnd?() }
        if !atEnd { endReported = false }
    }
    func shutdown() {
        timer?.invalidate(); timer = nil
        if let handle { lumen_destroy(handle); self.handle = nil }
    }
    deinit { shutdown() }
}
