import Foundation

public struct TranslationLine: Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public enum TranslationOutputError: LocalizedError {
    case invalid, truncated
    public var errorDescription: String? {
        switch self {
        case .invalid: "翻译模型返回的字幕格式无效"
        case .truncated: "翻译模型的输出被截断"
        }
    }
}

public enum SubtitleTranslation {
    private struct CommentaryRule {
        let output: NSRegularExpression
        let source: [NSRegularExpression]
        init(_ output: String, source: [String]) {
            self.output = try! NSRegularExpression(pattern: output, options: [.caseInsensitive, .dotMatchesLineSeparators])
            self.source = source.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators]) }
        }
    }
    private static let translationTerms = #"翻译|译文|字幕|原文|上下文|translat|subtitles?|context|翻訳|訳す|訳して|文脈"#
    private static let commentaryRules = [
        CommentaryRule(#"(?:用户|使用者|user).{0,18}(?:提供|补充|给出|provided|supplied).{0,24}(?:信息|资讯|内容|上下文|information|context|details)"#,
                       source: [#"用户|使用者|ユーザー|利用者|\buser\b"#, #"信息|资讯|内容|上下文|information|context|details|情報|補足"#]),
        CommentaryRule(#"(?:我|我们).{0,8}(?:将|会|可以).{0,8}(?:根据|结合|参考|利用|使用).{0,10}(?:这些|上述|以上|额外|提供的).{0,6}(?:信息|资料|内容)|\bI (?:will|can).{0,12}(?:use|consider|take into account).{0,20}(?:information|context)\b"#,
                       source: [#"information|details|context|data|资料|信息|内容|情報|資料"#]),
        CommentaryRule(#"(?:用户|user).{0,18}(?:想要|要求|希望|需要|requests?|wants?).{0,24}(?:翻译|translat)"#,
                       source: [#"用户|ユーザー|利用者|\buser\b"#, translationTerms]),
        CommentaryRule(#"(?:我|我们|助手).{0,8}(?:将|会|需要|可以|来|先|现在).{0,32}(?:翻译|译成|译为|译文|逐句|逐条|字幕|原文|上下文)|\bI\s+(?:will|need to|should)\s+(?:translate|provide a translation|analy[sz]e)\b"#,
                       source: [translationTerms]),
        CommentaryRule(#"(?:^|[\n。！？.!?])\s*(?:好的[，,。！!\s]*)?(?:(?:以下|下面|这里是|这是).{0,12}(?:译文|中文翻译|翻译结果|字幕翻译)|翻译如下|(?:译文|翻译(?:结果)?|中文翻译)\s*[:：])|(?:^|\n)\s*(?:here (?:is|are)|the following is).{0,15}(?:translation|translated text)"#,
                       source: [translationTerms]),
        CommentaryRule(#"(?:根据|结合|从).{0,12}(?:上下文|用户.{0,8}信息).{0,20}(?:我|我们|可以看出|可知|这句话)|(?:这段|该段|这句|该句).{0,8}(?:文本|字幕|原文).{0,20}(?:意思是|可以译为|应译为)"#,
                       source: [#"上下文|原文|字幕|文本|句子|context|text|sentence|subtitle|文脈|テキスト|翻訳"#]),
        CommentaryRule(#"作为(?:一个|一名)?\s*(?:AI|人工智能|语言模型|翻译助手)|\bas an? (?:AI|language model)\b"#,
                       source: [#"\bAI\b|artificial intelligence|language model|人工智能|语言模型|人工知能|言語モデル|翻译助手"#]),
        CommentaryRule(#"(?:请|需要).{0,10}(?:提供|补充|给出).{0,20}(?:原文|文本|待翻译|上下文)|(?:无法|不能).{0,12}(?:翻译|提供.{0,8}译文)|(?:缺少|缺乏).{0,12}(?:上下文|原文|文本)"#,
                       source: [translationTerms + "|text|文本|テキスト"]),
        CommentaryRule(#"<\s*/?\s*(?:think|analysis|reasoning)\b|(?:^|\n)\s*(?:analysis|reasoning|思考过程|推理过程)\s*[:：]"#,
                       source: [#"<\s*/?\s*(?:think|analysis|reasoning)\b|(?:analysis|reasoning|思考过程|推理过程)\s*[:：]"#])
    ]

    /// Detect assistant commentary, not film dialogue about users, information
    /// or translation. Such dialogue is allowed when it is present in the source.
    public static func isUsable(_ translation: String, for source: String) -> Bool {
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return !commentaryRules.contains { rule in
            matches(rule.output, translation) && !rule.source.allSatisfy { matches($0, source) }
        }
    }

    public static func removingCommentary(from cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.map { cue in
            var result = cue
            if !cue.translation.isEmpty && !isUsable(cue.translation, for: cue.text) { result.translation = "" }
            return result
        }
    }

    /// Fixed object keys keep subtitles associated with their IDs even if the
    /// model reorders its output. The engine turns this schema into a grammar.
    public static func schema(for lines: [TranslationLine]) -> [String: Any] {
        let properties = lines.reduce(into: [String: Any]()) { $0[$1.id] = ["type": "string", "minLength": 1] }
        return ["type": "object", "properties": ["translations": ["type": "object", "properties": properties,
                "required": lines.map(\.id), "additionalProperties": false]],
                "required": ["translations"], "additionalProperties": false]
    }

    public static func parse(_ content: String, lines: [TranslationLine], finishReason: String? = nil) throws -> [String: String] {
        // Never guess positions or pad an array: one missing entry would shift
        // every later translation onto the wrong subtitle/time range.
        guard let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let translations = object["translations"] as? [String: Any] else {
            throw finishReason == "length" ? TranslationOutputError.truncated : TranslationOutputError.invalid
        }
        var result = [String: String]()
        for line in lines {
            if let value = translations[line.id] as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if isUsable(text, for: line.text) { result[line.id] = text }
            }
        }
        return result
    }

    /// Publish each valid result immediately. Only incomplete IDs are retried,
    /// twice individually, without context. Exhausted items remain untranslated
    /// for a later user retry; transport/engine failures and cancellation escape.
    @MainActor public static func resolve(
        _ lines: [TranslationLine],
        check: () throws -> Void,
        request: ([TranslationLine], Bool) async throws -> [String: String],
        accept: ([String: String]) -> Void
    ) async throws -> Set<String> {
        var pending = Set(lines.map(\.id))
        func attempt(_ items: [TranslationLine], retry: Bool) async throws {
            try check()
            let values: [String: String]
            do { values = try await request(items, retry) }
            catch is TranslationOutputError { try check(); return }
            try check()
            var valid = [String: String]()
            for item in items where pending.contains(item.id) {
                if let text = values[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines), isUsable(text, for: item.text) { valid[item.id] = text }
            }
            if !valid.isEmpty { accept(valid); pending.subtract(valid.keys) }
        }
        if lines.isEmpty { return pending }
        try await attempt(lines, retry: false)
        for line in lines where pending.contains(line.id) {
            for _ in 0..<2 {
                try await attempt([line], retry: true)
                if !pending.contains(line.id) { break }
            }
        }
        return pending
    }
}
