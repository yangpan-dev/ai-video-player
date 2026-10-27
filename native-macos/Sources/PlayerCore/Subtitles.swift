import Foundation
import CoreFoundation

public struct SubtitleCue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var translation: String
    public init(id: UUID = UUID(), start: Double, end: Double, text: String, translation: String = "") {
        self.id = id; self.start = start; self.end = end; self.text = text; self.translation = translation
    }
}

public enum SubtitleDisplay: String, CaseIterable, Identifiable, Codable {
    case bilingual, original, translation, off
    public var id: String { rawValue }
    public var title: String {
        switch self { case .bilingual: "双语"; case .original: "原文"; case .translation: "中文"; case .off: "关闭" }
    }
}

public enum SubtitleCodec {
    public static func time(_ value: Double, vtt: Bool = false) -> String {
        let ms = Int((value.isFinite ? max(0, min(value, 359_999)) : 0) * 1000 + 0.5)
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, vtt ? "." : ",", ms % 1000)
    }
    public static func encode(_ cues: [SubtitleCue], display: SubtitleDisplay = .bilingual, vtt: Bool = false) -> String {
        if display == .off { return "" }
        let body = cues.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }.enumerated().map { index, cue in
            let lines: String
            switch display {
            case .bilingual: lines = cue.translation.isEmpty ? cue.text : cue.text + "\n" + cue.translation
            case .translation: lines = cue.translation.isEmpty ? cue.text : cue.translation
            default: lines = cue.text
            }
            return (vtt ? "" : "\(index + 1)\n") + "\(time(cue.start, vtt: vtt)) --> \(time(cue.end, vtt: vtt))\n\(lines)"
        }.joined(separator: "\n\n")
        return (vtt ? "WEBVTT\n\n" : "") + body + "\n"
    }
    public static func parse(_ input: String) -> [SubtitleCue] {
        let content = input.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let expression = try! NSRegularExpression(pattern: #"^\s*(?:(\d+):)?(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{2}):(\d{2})[,.](\d{1,3})(?:\s|$)"#)
        var result = [SubtitleCue]()
        let blocks = content.components(separatedBy: try! NSRegularExpression(pattern: #"\n\s*\n"#))
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }), let match = expression.firstMatch(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index])) else { continue }
            func field(_ i: Int) -> String { Range(match.range(at: i), in: lines[index]).map { String(lines[index][$0]) } ?? "0" }
            func seconds(_ offset: Int) -> Double {
                let ms = field(offset + 3).padding(toLength: 3, withPad: "0", startingAt: 0)
                return (Double(field(offset)) ?? 0) * 3600 + (Double(field(offset + 1)) ?? 0) * 60 + (Double(field(offset + 2)) ?? 0) + (Double(ms) ?? 0) / 1000
            }
            guard (Int(field(2)) ?? 99) < 60, (Int(field(3)) ?? 99) < 60, (Int(field(6)) ?? 99) < 60, (Int(field(7)) ?? 99) < 60 else { continue }
            let start = seconds(1), end = seconds(5)
            let text = lines.dropFirst(index + 1).joined(separator: "\n").replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if end > start, !text.isEmpty { result.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return result.sorted { $0.start < $1.start }
    }
    public static func read(_ url: URL) throws -> [SubtitleCue] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10 * 1024 * 1024 else { throw SubtitleError.invalid("字幕文件超过 10 MB") }
        let data = try Data(contentsOf: url)
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: String.Encoding(rawValue: gb))
        let cues = parse(text ?? "")
        guard !cues.isEmpty else { throw SubtitleError.invalid("字幕没有可读取的文字或时间轴") }
        return cues
    }
}

public enum SubtitleError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        expression.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: "\u{001E}").components(separatedBy: "\u{001E}")
    }
}
