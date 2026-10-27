import Foundation

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public struct MediaScanResult: Sendable {
    public var videos: [URL] = []
    public var subtitles: [URL] = []
    public var unreadable: [String] = []
    public var cancelled = false
}

public enum MediaScanner {
    public static func scan(_ roots: [URL], cancellation: CancellationFlag = CancellationFlag(), progress: ((Int) -> Void)? = nil) -> MediaScanResult {
        let manager = FileManager.default
        var result = MediaScanResult(), known = Set<String>()
        func accept(_ url: URL, explicit: Bool) {
            guard !cancellation.isCancelled else { return }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard known.insert(canonical.path).inserted else { return }
            guard (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
            if VideoFiles.subtitles.contains(canonical.pathExtension.lowercased()) {
                if explicit { result.subtitles.append(canonical) }
            } else if VideoFiles.accepts(canonical) || explicit {
                result.videos.append(canonical)
                if result.videos.count % 100 == 0 { progress?(result.videos.count) }
            }
        }
        for root in roots where root.isFileURL {
            if cancellation.isCancelled { break }
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else { result.unreadable.append(canonical.path); continue }
            if !isDirectory.boolValue { accept(canonical, explicit: true); continue }
            let enumerator = manager.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) { url, _ in
                result.unreadable.append(url.path); return !cancellation.isCancelled
            }
            while let file = enumerator?.nextObject() as? URL {
                if cancellation.isCancelled { break }
                if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    enumerator?.skipDescendants()
                    continue
                }
                if VideoFiles.accepts(file) { accept(file, explicit: false) }
            }
        }
        result.cancelled = cancellation.isCancelled
        result.videos.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        progress?(result.videos.count)
        return result
    }
}
