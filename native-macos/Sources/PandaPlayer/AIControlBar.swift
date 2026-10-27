import SwiftUI
import PlayerCore

struct AIControlBar: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var ai: AIController
    var body: some View {
        Button {
            if ai.running { ai.cancel() }
            else if !ai.modelReady || !ai.translationReady { store.openSettings(.subtitles) }
            else { store.startAI() }
        } label: {
            HStack(spacing: 6) {
                if ai.running { ProgressView().controlSize(.mini) }
                else { Image(systemName: ai.cues.isEmpty ? "captions.bubble" : "captions.bubble.fill") }
                Text(ai.running ? "停止生成" : "AI 字幕")
            }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 7)
                .foregroundStyle(Palette.accent).background(Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(store.current == nil || ai.downloading)
            .help(ai.running ? "取消字幕任务，保留已生成字幕" : "识别语音并翻译为中文字幕")
    }
}

struct SubtitleQuickMenu: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var ai: AIController
    var body: some View {
        Menu {
            if ai.cues.isEmpty {
                Toggle("显示字幕", isOn: Binding(get: { ai.display != .off }, set: { ai.display = $0 ? .bilingual : .off }))
            } else {
                Picker("显示方式", selection: $ai.display) { ForEach(SubtitleDisplay.allCases) { Text($0.title).tag($0) } }
            }
            Divider()
            Button("导入字幕…") { store.subtitlePanel() }.disabled(store.current == nil)
            Button("翻译已有字幕") {
                if ai.translationReady { store.translateSubtitles() } else { store.openSettings(.subtitles) }
            }.disabled(ai.cues.isEmpty || ai.running)
            Button("导出字幕…") { store.exportSubtitles() }.disabled(ai.cues.isEmpty)
            Divider()
            Button("字幕设置…") { store.openSettings(.subtitles) }
        } label: { Label("字幕", systemImage: "captions.bubble").labelStyle(.iconOnly).font(.system(size: 13)).frame(width: 24, height: 26) }
        .menuStyle(.borderlessButton).fixedSize().help("字幕显示、导入与导出").accessibilityLabel("字幕")
    }
}

struct AIStatusBar: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var ai: AIController
    var body: some View {
        if ai.running || ai.downloading || ai.failure != nil {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(message).font(.system(size: 11)).foregroundStyle(ai.failure == nil ? Palette.muted : .red).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if ai.running { Text("\(Int(ai.percent))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
                    if ai.downloading { Text("\(Int(ai.downloadPercent))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
                    if ai.failure != nil {
                        Button("设置") { store.openSettings(.subtitles) }.buttonStyle(.plain).font(.system(size: 11))
                        Button { ai.failure = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("关闭提示")
                    }
                }
                if ai.running || ai.downloading { ProgressView(value: ai.downloading ? ai.downloadPercent : ai.percent, total: 100).progressViewStyle(.linear) }
            }.padding(.horizontal, 20).padding(.vertical, 10).background(Palette.panel)
        }
    }
    private var message: String {
        if let failure = ai.failure { return failure }
        if ai.downloading { return "正在下载模型，可在设置中查看" }
        if ai.status.contains("加载") { return "正在准备字幕引擎…" }
        if ai.status.contains("翻译") { return "正在翻译 · 已完成 \(ai.translatedCount) 句" }
        return "正在识别 · 已生成 \(ai.cues.count) 句"
    }
}
