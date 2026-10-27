import Foundation

public enum VideoFiles {
    public static let extensions: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "m4v", "ts", "mts", "m2ts", "mpg", "mpeg", "vob", "wmv", "flv", "ogv", "3gp", "rm", "rmvb", "mxf", "divx", "asf", "f4v"]
    public static let subtitles: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup"]
    public static func accepts(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    public static func naturallySorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

public struct MediaItem: Identifiable, Codable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public var title: String { url.deletingPathExtension().lastPathComponent }
    public init(url: URL) { self.url = url.standardizedFileURL }
}

public enum PicturePreset: String, CaseIterable, Codable, Identifiable {
    case original, balanced, cinema, animation, lowResolution
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .original: "原片"
        case .balanced: "清晰自然"
        case .cinema: "影院"
        case .animation: "动画"
        case .lowResolution: "低清优化"
        }
    }
    public var symbol: String {
        switch self {
        case .original: "circle.lefthalf.filled"
        case .balanced: "sparkles"
        case .cinema: "film"
        case .animation: "paintpalette"
        case .lowResolution: "viewfinder"
        }
    }
    public var detail: String {
        switch self {
        case .original: "保留原始色彩与质感"
        case .balanced: "细腻放大，轻度锐化"
        case .cinema: "柔和层次，舒适观影"
        case .animation: "清晰线条，平滑渐变"
        case .lowResolution: "轻度降噪，改善放大观感"
        }
    }
    public var settings: PictureSettings {
        switch self {
        case .original: PictureSettings(highQualityScaling: false, deband: false)
        case .balanced: PictureSettings(sharpness: 0.35)
        case .cinema: PictureSettings(contrast: 3, saturation: -3, gamma: 2, sharpness: 0.15)
        case .animation: PictureSettings(contrast: 2, saturation: 4, sharpness: 0.45)
        case .lowResolution: PictureSettings(sharpness: 0.3, denoise: true)
        }
    }
}

public struct PictureSettings: Codable, Equatable {
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var saturation: Double = 0
    public var gamma: Double = 0
    public var sharpness: Double = 0
    public var highQualityScaling: Bool = true
    public var deband: Bool = true
    public var denoise: Bool = false
    public var deinterlace: Bool = false
    public var toneMapping: Bool = true

    public init(brightness: Double = 0, contrast: Double = 0, saturation: Double = 0,
                gamma: Double = 0, sharpness: Double = 0, highQualityScaling: Bool = true,
                deband: Bool = true, denoise: Bool = false, deinterlace: Bool = false,
                toneMapping: Bool = true) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
        self.gamma = gamma; self.sharpness = sharpness; self.highQualityScaling = highQualityScaling
        self.deband = deband; self.denoise = denoise; self.deinterlace = deinterlace
        self.toneMapping = toneMapping
    }
    public var properties: [(String, String)] {
        let filters = denoise ? "lavfi=[hqdn3d=1.5:1.5:3:3]" : ""
        return [
            ("brightness", Self.number(brightness.clamped(to: -100...100))),
            ("contrast", Self.number(contrast.clamped(to: -100...100))),
            ("saturation", Self.number(saturation.clamped(to: -100...100))),
            ("gamma", Self.number(gamma.clamped(to: -100...100))),
            ("sharpen", Self.number(sharpness.clamped(to: 0...1))),
            ("scale", highQualityScaling ? "ewa_lanczossharp" : "bilinear"),
            ("cscale", highQualityScaling ? "spline36" : "bilinear"),
            ("dscale", highQualityScaling ? "mitchell" : "bilinear"),
            ("deband", deband ? "yes" : "no"),
            ("deinterlace", deinterlace ? "yes" : "no"),
            ("tone-mapping", toneMapping ? "bt.2390" : "clip"),
            ("vf", filters)
        ]
    }
    private static func number(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
}

public extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        isFinite ? min(range.upperBound, max(range.lowerBound, self)) : range.lowerBound
    }
}

public enum PlaybackTime {
    public static func label(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let value = Int(min(seconds, 359_999))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    public static func resumePosition(saved: Double?, duration: Double) -> Double? {
        guard let saved, saved.isFinite, duration.isFinite, saved > 5, duration > 15,
              saved < duration - 10 else { return nil }
        return saved
    }
}
