import Foundation
import PlayerCore

enum TranslationChecks {
    @MainActor static func run() async throws -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            checks += 1
        }
        struct QualityCase: Decodable { let source: String; let translation: String; let usable: Bool }
        let qualityURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/translation-quality.json")
        let qualityCases = try JSONDecoder().decode([QualityCase].self, from: Data(contentsOf: qualityURL))
        for item in qualityCases {
            expect(SubtitleTranslation.isUsable(item.translation, for: item.source) == item.usable, "translation quality: \(item.translation)")
        }
        let lines = [TranslationLine(id: "a", text: "First"), TranslationLine(id: "b", text: "Second"), TranslationLine(id: "c", text: "Third")]
        let reordered = try SubtitleTranslation.parse(#"{"translations":{"c":"丙","a":" 甲 ","b":"乙"}}"#, lines: lines)
        expect(reordered == ["a": "甲", "b": "乙", "c": "丙"], "map reordered translations by ID and trim whitespace")
        let partial = try SubtitleTranslation.parse(#"{"translations":{"a":"甲","b":" \n ","c":null,"context":"不应写入"}}"#, lines: lines)
        expect(partial == ["a": "甲"], "keep valid entries, reject blank/null entries and ignore unknown IDs")
        let wrongType = try SubtitleTranslation.parse(#"{"translations":{"a":17,"b":"乙"}}"#, lines: lines)
        expect(wrongType == ["b": "乙"], "a bad entry must not discard other valid translations")
        do {
            _ = try SubtitleTranslation.parse(#"{"translations":["甲","丙"]}"#, lines: lines)
            expect(false, "reject ambiguous positional output")
        } catch is TranslationOutputError { expect(true, "reject ambiguous positional output") }
        do {
            _ = try SubtitleTranslation.parse(#"{"translations":{"a":"甲""#, lines: lines, finishReason: "length")
            expect(false, "detect truncated JSON")
        } catch TranslationOutputError.truncated { expect(true, "detect truncated JSON") }

        var calls = [[String]](), saved = [String: String](), retryCount = 0
        let missing = try await SubtitleTranslation.resolve(lines, check: {}, request: { items, retry in
            calls.append(items.map(\.id))
            if !retry { return ["a": "甲", "b": " ", "c": "丙"] }
            expect(saved["a"] == "甲" && saved["c"] == "丙", "save successful batch entries before retrying")
            retryCount += 1
            return retryCount == 1 ? [:] : ["b": "乙"]
        }, accept: { saved.merge($0) { _, new in new } })
        expect(missing.isEmpty && saved == reordered, "recover a blank item without losing valid translations")
        expect(calls == [["a", "b", "c"], ["b"], ["b"]], "retry only the incomplete subtitle, with a finite budget")

        calls = []; saved = [:]
        let remaining = try await SubtitleTranslation.resolve(lines, check: {}, request: { items, retry in
            calls.append(items.map(\.id))
            if !retry { throw TranslationOutputError.truncated }
            return items[0].id == "a" ? [:] : [items[0].id: "有效译文"]
        }, accept: { saved.merge($0) { _, new in new } })
        expect(remaining == ["a"], "report an exhausted item instead of looping or inventing a translation")
        expect(saved["b"] != nil && saved["c"] != nil, "a permanently invalid item must not prevent later subtitles from translating")
        expect(calls.count == 5, "truncated batch uses bounded per-item retries")

        enum TransportFailure: Error { case offline }
        saved = [:]; calls = []
        do {
            _ = try await SubtitleTranslation.resolve(lines, check: {}, request: { items, retry in
                calls.append(items.map(\.id))
                if retry { throw TransportFailure.offline }
                return ["a": "已保存"]
            }, accept: { saved.merge($0) { _, new in new } })
            expect(false, "surface engine/transport failures")
        } catch TransportFailure.offline {
            expect(saved == ["a": "已保存"] && calls.count == 2, "preserve successful entries and surface transport errors without blindly retrying")
        }
        var cancelled = false
        saved = [:]
        do {
            _ = try await SubtitleTranslation.resolve(lines, check: { if cancelled { throw CancellationError() } }, request: { _, _ in
                cancelled = true
                return ["a": "过期结果"]
            }, accept: { saved.merge($0) { _, new in new } })
            expect(false, "respect cancellation after a response")
        } catch is CancellationError { expect(saved.isEmpty, "cancelled or replaced jobs must not publish late translations") }
        saved = [:]; calls = []
        _ = try await SubtitleTranslation.resolve(lines, check: {}, request: { items, retry in
            calls.append(items.map(\.id))
            return retry ? ["a": "甲"] : ["a": "用户提供了一些额外的信息，我将根据这些信息进行翻译。", "b": "乙", "c": "丙"]
        }, accept: { values in
            expect(!values.values.contains(where: { $0.contains("用户提供") }), "never publish commentary while retrying")
            saved.merge(values) { _, new in new }
        })
        expect(saved == reordered && calls == [["a", "b", "c"], ["a"]], "replace model commentary by retrying only the contaminated cue")
        let badCue = SubtitleCue(start: 1, end: 2, text: "Hello", translation: "以下是翻译结果：你好。")
        let cleaned = SubtitleTranslation.removingCommentary(from: [badCue])
        expect(cleaned[0].translation.isEmpty && cleaned[0].text == badCue.text && cleaned[0].id == badCue.id, "clean cached commentary while preserving original text, ID and timing")
        return checks
    }
}
