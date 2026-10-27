import Foundation
import PlayerCore

enum AIIntegrationTest {
    static func run() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else { fputs("Supply a speech video file\n", stderr); exit(2) }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        Task { @MainActor in
            let controller = AIController()
            controller.switchVideo(file); controller.language = "en"; controller.fromCurrentPosition = false
            if CommandLine.arguments.contains("--batch") { controller.mode = .batch }
            do {
                if CommandLine.arguments.contains("--translation-only") {
                    controller.importCues([SubtitleCue(start: 0, end: 3, text: "Welcome to Panda Player."), SubtitleCue(start: 3, end: 6, text: "This player can translate English subtitles into Chinese.")], video: file)
                    controller.translateExisting(video: file)
                } else {
                    let engine = try MPVEngine(headless: true); defer { engine.shutdown() }
                    var loaded = false; engine.onFileLoaded = { loaded = true }; engine.open(file)
                    let deadline = Date().addingTimeInterval(15)
                    while !loaded && Date() < deadline { engine.pollEvents(); try await Task.sleep(nanoseconds: 30_000_000) }
                    guard loaded else { throw SubtitleError.invalid("Test video failed to load") }
                    let duration = engine.number("duration")
                    controller.start(video: file, duration: duration, position: 0)
                }
                var previous = ""
                let deadline = Date().addingTimeInterval(420)
                while controller.running && Date() < deadline {
                    if controller.status != previous { print(controller.status); previous = controller.status; fflush(stdout) }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                guard !controller.running else { controller.cancel(); throw SubtitleError.invalid("AI test timed out") }
                if let failure = controller.failure { throw SubtitleError.invalid(failure) }
                guard !controller.cues.isEmpty, controller.translatedCount == controller.cues.count,
                      controller.cues.contains(where: { $0.translation.range(of: #"\p{Han}"#, options: .regularExpression) != nil }) else { throw SubtitleError.invalid("Missing recognized/translated subtitles") }
                let output = AIRuntime.appSupport.appendingPathComponent("integration-result.srt")
                try SubtitleCodec.encode(controller.cues).write(to: output, atomically: true, encoding: .utf8)
                print("AI PASS: \(controller.cues.count) cues; \(controller.translatedCount) Chinese translations; \(output.path)")
                print(SubtitleCodec.encode(controller.cues))
                controller.shutdown(); exit(0)
            } catch { controller.shutdown(); fputs("AI FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }
}
