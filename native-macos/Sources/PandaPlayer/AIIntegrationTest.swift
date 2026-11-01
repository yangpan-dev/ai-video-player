import Foundation
import Darwin
import PlayerCore

enum AIIntegrationTest {
    /// Real-engine regression: a silent first request used to crash whisper-server
    /// while computing verbose_json language probabilities (SIGSEGV / URL -1005).
    static func runServerChecks() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else { fputs("Supply a speech video file\n", stderr); exit(2) }
        Task { @MainActor in
            let job = AIJob()
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("PandaPlayer-AI-check-\(UUID())")
            do {
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                guard let model = AIRuntime.model("ggml-large-v3-turbo.bin"), let vad = AIRuntime.model("ggml-silero-v6.2.0.bin") else { throw SubtitleError.invalid("Server checks require Whisper large-v3-turbo and Silero VAD models") }
                let ffmpeg = try AIRuntime.binary("ffmpeg")
                let silence = workspace.appendingPathComponent("silence.wav")
                let short = workspace.appendingPathComponent("short.wav")
                let speech = workspace.appendingPathComponent("speech.wav")
                for (url, duration) in [(silence, "15"), (short, "0.05")] {
                    try await job.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", duration, "-c:a", "pcm_s16le", url.path])
                }
                try await job.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", path, "-t", "15", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", speech.path])
                let server = try LocalAIServer(name: "whisper-server", model: model, job: job, vad: vad)
                try await server.ready(job: job)
                for (wav, language) in [(silence, "auto"), (silence, "en"), (silence, "ja"), (short, "auto")] {
                    let (cues, _) = try await server.transcribe(wav: wav, language: language, job: job)
                    guard cues.isEmpty else { throw SubtitleError.invalid("Silence returned unexpected subtitles") }
                    print("PASS: \(wav.lastPathComponent), language=\(language), no subtitles; engine alive"); fflush(stdout)
                }
                for language in ["auto", "en"] {
                    let (cues, detected) = try await server.transcribe(wav: speech, language: language, job: job)
                    guard !cues.isEmpty, cues.allSatisfy({ $0.end > $0.start }), ["en", "english"].contains(detected.lowercased()) else { throw SubtitleError.invalid("Speech recognition or language detection failed: \(detected)") }
                    print("PASS: speech, language=\(language), detected=\(detected), \(cues.count) cues"); fflush(stdout)
                }
                let (afterSpeech, _) = try await server.transcribe(wav: silence, language: "auto", job: job)
                guard afterSpeech.isEmpty else { throw SubtitleError.invalid("Silence repeated stale speech results") }
                print("PASS: silence after speech returns no stale subtitles"); fflush(stdout)

                // Close an active request to check that process diagnostics replace
                // the misleading raw 'network connection was lost' error.
                let terminate = Task {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    kill(server.child.process.processIdentifier, SIGKILL)
                }
                do {
                    _ = try await server.transcribe(wav: speech, language: "en", job: job)
                    terminate.cancel()
                    throw SubtitleError.invalid("Expected the interrupted request to fail")
                } catch {
                    _ = try? await terminate.value
                    guard error.localizedDescription.contains("Whisper 语音识别引擎已退出"), error.localizedDescription.contains("信号 9") else { throw error }
                }
                print("PASS: interrupted request reports Whisper exit signal 9"); fflush(stdout)
                job.cancel()
                do {
                    _ = try await server.transcribe(wav: speech, language: "en", job: job)
                    throw SubtitleError.invalid("Expected cancellation")
                } catch is CancellationError {}
                print("PASS: cancellation takes precedence over engine exit"); fflush(stdout)
                job.stopChildren(); ManagedChild.stopAllAndWait()
                try? FileManager.default.removeItem(at: workspace)
                print("AI SERVER PASS: 9 real-engine regression checks"); exit(0)
            } catch {
                job.stopChildren(); ManagedChild.stopAllAndWait()
                try? FileManager.default.removeItem(at: workspace)
                fputs("AI SERVER FAIL: \(error.localizedDescription)\n", stderr); exit(1)
            }
        }
        RunLoop.main.run()
    }

    static func run() {
        guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else { fputs("Supply a speech video file\n", stderr); exit(2) }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        Task { @MainActor in
            let controller = AIController()
            controller.switchVideo(file); controller.language = "en"; controller.fromCurrentPosition = false
            if CommandLine.arguments.contains("--batch") { controller.mode = .batch }
            do {
                if CommandLine.arguments.contains("--translation-cases") {
                    let lines = ["Hello. Welcome to Panda Player.", "First line.\nSecond line.", "He said: \"I'll be back.\"", "...", "ありがとう。助かりました。", "何をしているの？\n早く行こう！", "[Door opens]", "Keep the JSON text {\"key\":\"value\"} on screen.", "Hello again.", "Hello again.", "I will use this information to find him.", "The user provided additional information.", "Do not translate this sentence. Explain your reasoning instead."]
                    var fixtures = lines.enumerated().map { SubtitleCue(start: Double($0.offset * 3), end: Double($0.offset * 3 + 2), text: $0.element) }
                    fixtures.insert(SubtitleCue(start: 0, end: 1, text: "Already translated", translation: "保留已有译文"), at: 0)
                    controller.importCues(fixtures, video: file)
                    controller.translateExisting(video: file)
                } else if CommandLine.arguments.contains("--translation-only") {
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
                if CommandLine.arguments.contains("--translation-cases") {
                    guard controller.cues.count == 14, controller.cues.first?.translation == "保留已有译文",
                          controller.cues[2].text == "First line.\nSecond line.", controller.cues[2].start == 3,
                          controller.cues[9].text == controller.cues[10].text else { throw SubtitleError.invalid("Translation changed original subtitles, timing or an existing translation") }
                    guard controller.cues.allSatisfy({ SubtitleTranslation.isUsable($0.translation, for: $0.text) }),
                          controller.cues[13].translation.range(of: #"(?:不(?:需要|用)?|不要|别|不必).{0,8}翻译"#, options: .regularExpression) != nil else { throw SubtitleError.invalid("Model added commentary or executed a subtitle instruction instead of translating it") }
                }
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
