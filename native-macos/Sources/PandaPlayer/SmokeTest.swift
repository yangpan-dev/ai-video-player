import Foundation
import PlayerCore

enum SmokeTest {
    static func run() {
        let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else { fputs("Usage: PandaPlayer --smoke-test video...\n", stderr); exit(2) }
        do {
            let rendering = CommandLine.arguments.contains("--render-test")
            let engine = try MPVEngine(headless: !rendering)
            engine.set("mute", "yes")
            let probe = rendering ? try RenderProbe(engine: engine) : nil
            defer { probe?.close(); engine.shutdown() }
            for file in files {
                var loaded = false
                var failure: String?
                engine.onFileLoaded = { loaded = true }
                engine.onFailure = { failure = $0 }
                engine.open(file)
                let deadline = Date().addingTimeInterval(15)
                while !loaded && failure == nil && Date() < deadline {
                    engine.pollEvents(); probe?.draw(); Thread.sleep(forTimeInterval: 0.02)
                }
                guard loaded, failure == nil else { throw EngineError.unavailable("\(file.lastPathComponent): \(failure ?? "load timed out")") }
                guard engine.number("video-params/w") > 0 else { throw EngineError.unavailable("No decoded video") }
                for preset in PicturePreset.allCases {
                    let failures = engine.apply(preset.settings)
                    guard failures.isEmpty else { throw EngineError.unavailable("Preset \(preset.rawValue): \(failures)") }
                }
                let target = min(1.5, engine.number("duration") / 2)
                guard engine.command(["seek", "\(target)", "absolute+exact"]) >= 0 else { throw EngineError.unavailable("Seek failed") }
                let seekDeadline = Date().addingTimeInterval(5)
                while Date() < seekDeadline && abs(engine.number("time-pos") - target) > 0.6 {
                    engine.pollEvents(); probe?.draw(); Thread.sleep(forTimeInterval: 0.03)
                }
                guard abs(engine.number("time-pos") - target) <= 0.6 else { throw EngineError.unavailable("Seek position mismatch") }
                engine.set("pause", "yes")
                guard engine.string("pause") == "yes" else { throw EngineError.unavailable("Pause failed") }
                if let probe { try probe.verifyPictureOutput(file: file) }
                let report: [String: Any] = ["file": file.lastPathComponent, "engine": engine.libraryPath, "codec": engine.string("video-format") ?? "", "width": engine.number("video-params/w"), "height": engine.number("video-params/h"), "duration": engine.number("duration"), "tracks": engine.number("track-list/count"), "presets": "passed", "seek": "passed", "pause": "passed"]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
