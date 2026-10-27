import Foundation
import PlayerCore

// A standalone test executable also runs on machines with Command Line Tools
// only (where XCTest is not shipped). Each group checks a user-facing invariant.
@main enum CoreChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1
        }
        expect(PlaybackTime.resumePosition(saved: 90, duration: 600) == 90, "resume mid-film")
        expect(PlaybackTime.resumePosition(saved: 595, duration: 600) == nil, "do not resume near EOF")
        expect(PlaybackTime.resumePosition(saved: -.infinity, duration: 600) == nil, "reject infinite resume")
        expect(PlaybackTime.resumePosition(saved: 4, duration: 600) == nil, "ignore trivial progress")
        expect(PlaybackTime.resumePosition(saved: 40, duration: .nan) == nil, "reject invalid duration")
        let urls = ["Episode 10.MKV", "Episode 2.mkv", "Episode 1.mkv"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        expect(VideoFiles.naturallySorted(urls).map(\.lastPathComponent) == ["Episode 1.mkv", "Episode 2.mkv", "Episode 10.MKV"], "natural episode order")
        for file in ["video.MKV", "video.mxf", "video.rmvb", "video.m2ts", "video.webm"] {
            expect(VideoFiles.accepts(URL(fileURLWithPath: file)), "recognize \(file)")
        }
        expect(!VideoFiles.accepts(URL(fileURLWithPath: "image.png")), "exclude non-video files from folder scan")
        let properties = Dictionary(uniqueKeysWithValues: PictureSettings(brightness: 300, contrast: -400, saturation: .nan, sharpness: 9).properties)
        expect(properties["brightness"] == "100.000", "clamp brightness")
        expect(properties["contrast"] == "-100.000", "clamp contrast")
        expect(properties["saturation"] == "-100.000", "reject NaN picture setting")
        expect(properties["sharpen"] == "1.000", "bound sharpen")
        let enhanced = Dictionary(uniqueKeysWithValues: PicturePreset.lowResolution.settings.properties)
        let original = Dictionary(uniqueKeysWithValues: PicturePreset.original.settings.properties)
        expect(enhanced["vf"]!.contains("hqdn3d"), "low-resolution preset enables denoising")
        expect(original["vf"] == "", "comparison removes denoising")
        expect(original["sharpen"] == "0.000", "comparison removes sharpening")
        expect(original["brightness"] == "0.000", "comparison resets brightness")
        expect(original["deband"] == "no", "comparison removes debanding")
        expect(PlaybackTime.label(.nan) == "00:00", "format NaN metadata")
        expect(PlaybackTime.label(.infinity) == "00:00", "format infinite metadata")
        expect(PlaybackTime.label(-30) == "00:00", "format negative metadata")
        expect(PlaybackTime.label(3661) == "1:01:01", "format hour-long media")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PandaPlayer-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let nested = root.appendingPathComponent("Series/Season 1/Disc 1/bonus")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            for name in ["Episode 10.MKV", "Episode 2.mp4", "Episode 1.avi", "notes.txt", "sub.srt", ".hidden.mp4"] { try Data("fixture".utf8).write(to: nested.appendingPathComponent(name)) }
            try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("cycle"), withDestinationURL: root)
            let scanned = MediaScanner.scan([root, root.appendingPathComponent("Series")])
            expect(scanned.videos.count == 3, "scan four nested folder levels and deduplicate overlapping roots")
            expect(scanned.videos.map(\.lastPathComponent) == ["Episode 1.avi", "Episode 2.mp4", "Episode 10.MKV"], "recursive natural episode order")
            expect(scanned.subtitles.isEmpty, "do not add subtitle files to video list")
            let cancelled = CancellationFlag(); cancelled.cancel()
            expect(MediaScanner.scan([root], cancellation: cancelled).cancelled, "cancel recursive scan")
            let cues = SubtitleCodec.parse("WEBVTT\n\n00:01.2 --> 00:03.45\nHello\nsecond line\n\n00:04.000 --> 00:05.000\nGoodbye\n")
            expect(cues.count == 2, "parse VTT with short timestamps")
            expect(abs(cues[0].start - 1.2) < 0.001 && abs(cues[0].end - 3.45) < 0.001, "preserve fractional subtitle timing")
            expect(cues[0].text == "Hello\nsecond line", "preserve multiline original subtitle text")
            var translated = cues; translated[0].translation = "你好"; translated[1].translation = "再见"
            let srt = SubtitleCodec.encode(translated)
            expect(srt.contains("Hello\nsecond line\n你好"), "bilingual subtitle export")
            expect(SubtitleCodec.encode(translated, display: .translation).contains("你好") && !SubtitleCodec.encode(translated, display: .translation).contains("Hello"), "Chinese-only display")
            expect(SubtitleCodec.parse(srt).count == 2, "SRT export preserves cue count and timeline")
            expect(SubtitleCodec.parse("1\n00:70:00,000 --> 00:70:01,000\ninvalid").isEmpty, "reject malformed subtitle timestamp")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        print("PASS: \(checks) core checks")
    }
}
