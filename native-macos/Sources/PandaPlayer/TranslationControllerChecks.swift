import Foundation
import PlayerCore

enum TranslationControllerChecks {
    static func run() {
        guard let statePath = ProcessInfo.processInfo.environment["PANDAPLAYER_TRANSLATION_TEST_DIR"] else { fputs("Use scripts/test-translation.sh\n", stderr); exit(2) }
        Task { @MainActor in
            let controller = AIController()
            let root = URL(fileURLWithPath: statePath), video = root.appendingPathComponent("fixture.mp4")
            do {
                func expect(_ condition: Bool, _ message: String) throws {
                    if !condition { throw SubtitleError.invalid(message) }
                }
                func waitForTranslation() async throws {
                    let deadline = Date().addingTimeInterval(20)
                    while controller.running && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                    try expect(!controller.running, "Translation did not terminate within its retry budget")
                }
                func requests() throws -> [[String: Any]] {
                    let text = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                    return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
                }
                try Data("fixture".utf8).write(to: video)
                let texts = ["First", "Retry twice", "Permanent failure", "Fourth", "Malformed batch", "Last"]
                let fixtures = [SubtitleCue(start: 0, end: 1, text: "Keep", translation: "保留已有译文")] + texts.enumerated().map { SubtitleCue(start: Double($0.offset + 1), end: Double($0.offset + 2), text: $0.element) }
                controller.switchVideo(video); controller.importCues(fixtures, video: video)
                var published = [Int]()
                var publishedCommentary = false
                controller.onCuesChanged = { cues in
                    published.append(cues.filter { !$0.translation.isEmpty }.count)
                    publishedCommentary = publishedCommentary || cues.contains { !$0.translation.isEmpty && !SubtitleTranslation.isUsable($0.translation, for: $0.text) }
                }
                controller.translateExisting(video: video)
                try await waitForTranslation()
                try expect(controller.translatedCount == 6 && controller.cues.count == 7, "One bad line blocked later translations or changed cue count")
                try expect(controller.failure?.contains("1 条字幕") == true && controller.status.contains("待重试"), "Partial completion was reported as fully translated")
                try expect(published.contains(3) && zip(published, published.dropFirst()).allSatisfy { $0 <= $1 }, "Valid partial translations were discarded during retries")
                try expect(!publishedCommentary, "Model commentary was briefly displayed or saved before retry")
                // Simulate an old cache produced before the commentary guard.
                let cache = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("subtitles"), includingPropertiesForKeys: nil).first!
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
                var cachedCues = object["cues"] as! [[String: Any]]
                cachedCues[3]["translation"] = "用户提供了一些额外的信息，我将根据这些信息进行翻译。"
                object["cues"] = cachedCues
                try JSONSerialization.data(withJSONObject: object).write(to: cache)
                let restored = AIController(); restored.switchVideo(video)
                try expect(restored.cues == controller.cues, "Partial results were not saved to the subtitle cache")
                let cleanedCache = try String(contentsOf: cache, encoding: .utf8)
                try expect(!cleanedCache.contains("用户提供"), "Old cached commentary was not removed from disk")
                restored.shutdown()
                let beforeRetry = try requests().count
                try Data().write(to: root.appendingPathComponent("allow-retry"))
                controller.translateExisting(video: video)
                try await waitForTranslation()
                try expect(controller.failure == nil && controller.translatedCount == 7, "Retry did not complete the missing translation")
                let retried = try requests().dropFirst(beforeRetry)
                try expect(retried.count == 1 && retried.allSatisfy { row in
                    let lines = row["lines"] as? [[String: String]] ?? []
                    return lines.count == 1 && lines[0]["id"] == fixtures[3].id.uuidString
                }, "Retry submitted already translated subtitles")
                try expect(zip(fixtures, controller.cues).allSatisfy { a, b in a.id == b.id && a.start == b.start && a.end == b.end && a.text == b.text }, "Translation changed subtitle IDs, original text or timing")
                try expect(controller.cues[0].translation == "保留已有译文", "Existing translation was overwritten")
                controller.shutdown(); ManagedChild.stopAllAndWait()
                print("TRANSLATION CONTROLLER PASS: commentary rejected before display, cached commentary cleaned, partial results, bounded retries and retry only missing IDs")
                exit(0)
            } catch {
                controller.shutdown(); ManagedChild.stopAllAndWait()
                fputs("TRANSLATION CONTROLLER FAIL: \(error.localizedDescription)\n", stderr); exit(1)
            }
        }
        RunLoop.main.run()
    }
}
