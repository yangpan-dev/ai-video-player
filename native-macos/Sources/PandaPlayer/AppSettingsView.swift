import SwiftUI
import PlayerCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case subtitles, picture, audio, playback
    var id: String { rawValue }
    var title: String {
        switch self { case .subtitles: "字幕与 AI"; case .picture: "画面"; case .audio: "声音"; case .playback: "播放" }
    }
}

struct AppSettingsView: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var ai: AIController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成") { store.settingsVisible = false }.keyboardShortcut(.cancelAction).controlSize(.small)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
            Picker("设置分类", selection: $store.settingsSection) {
                ForEach(SettingsSection.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch store.settingsSection {
                    case .subtitles: subtitleSettings
                    case .picture: PictureInspector(store: store)
                    case .audio: audioSettings
                    case .playback: playbackSettings
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.id(store.settingsSection)
        }
        .frame(width: 620, height: 590)
        .background(Palette.panel)
        .foregroundStyle(.white.opacity(0.9))
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
    }
    @ViewBuilder private var subtitleSettings: some View {
        settingsGroup("生成字幕") {
            settingRow("识别模式") {
                Picker("识别模式", selection: $ai.mode) { ForEach(RecognitionMode.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 230)
            }
            settingRow("原声语言") {
                Picker("原声语言", selection: $ai.language) {
                    Text("自动检测").tag("auto"); Text("日语").tag("ja"); Text("英语").tag("en"); Text("中文").tag("zh")
                }.labelsHidden().frame(width: 230)
            }
            if ai.mode == .stream { Toggle("从当前播放位置开始识别", isOn: $ai.fromCurrentPosition).toggleStyle(.switch).controlSize(.mini) }
        }.disabled(ai.running)
        settingsGroup("本地模型") {
            settingRow("语音识别") {
                Picker("语音识别模型", selection: $ai.selectedModel) {
                    ForEach(RecognitionModel.all) { model in Text("\(model.label)\(AIRuntime.model(model.filename) != nil ? " ✓" : "")").tag(model.id) }
                }.labelsHidden().frame(width: 230)
            }
            HStack {
                readiness(ai.modelReady, ready: "识别模型已就绪", missing: "尚未下载识别模型")
                Spacer()
                if !ai.modelReady { Button("下载识别模型") { ai.download() }.disabled(ai.downloading) }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("中文翻译").font(.system(size: 12))
                    Text("Qwen2.5-7B · 约 4.4 GB").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if ai.translationReady { readiness(true, ready: "已就绪", missing: "") }
                else { Button("下载翻译模型") { ai.download(translation: true) }.disabled(ai.downloading) }
            }
            HStack {
                Text("首次准备后可离线使用").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button("选择已有模型目录…") { ai.chooseModelsDirectory() }
            }
            if ai.downloading {
                HStack { Text("\(ai.downloadLabel) · \(Int(ai.downloadPercent))%").font(.system(size: 10)); Spacer(); Button("取消下载") { ai.cancelDownload() } }
                ProgressView(value: ai.downloadPercent, total: 100)
            }
        }.disabled(ai.running)
        settingsGroup("字幕显示") {
            settingRow("显示方式") {
                Picker("显示方式", selection: $ai.display) { ForEach(SubtitleDisplay.allCases) { Text($0.title).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width: 270)
            }
            Picker("字幕轨", selection: Binding(get: { store.subtitleID }, set: { store.selectSubtitle($0) })) {
                Text("关闭字幕").tag(0)
                ForEach(store.subtitleTracks) { Text($0.label).tag($0.id) }
            }
            adjustment("字号", value: $store.subtitleSize, range: 20...70)
            adjustment("时间偏移", value: $store.subtitleDelay, range: -5...5, suffix: "秒", decimals: 1)
            HStack(spacing: 10) {
                Button("导入字幕…") { store.subtitlePanel() }.disabled(store.current == nil)
                Button("翻译已有字幕") { store.translateSubtitles() }.disabled(ai.cues.isEmpty || ai.running || !ai.translationReady)
                Spacer()
                Button("导出字幕…") { store.exportSubtitles() }.disabled(ai.cues.isEmpty)
            }
        }
        if ai.running || ai.failure != nil {
            Text(ai.failure ?? ai.status).font(.system(size: 11)).foregroundStyle(ai.failure == nil ? Palette.muted : .red).textSelection(.enabled)
        }
    }
    @ViewBuilder private var audioSettings: some View {
        settingsGroup("声音") {
            Picker("音轨", selection: Binding(get: { store.audioID }, set: { store.selectAudio($0) })) {
                if store.audioTracks.isEmpty { Text("无音轨").tag(0) }
                ForEach(store.audioTracks) { Text($0.label).tag($0.id) }
            }
            adjustment("音量", value: $store.volume, range: 0...100, suffix: "%")
            Toggle("静音", isOn: $store.muted).toggleStyle(.switch).controlSize(.mini)
        }
    }
    @ViewBuilder private var playbackSettings: some View {
        settingsGroup("播放") {
            settingRow("播放速度") {
                Picker("播放速度", selection: $store.speed) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2.0], id: \.self) { Text("\($0.formatted())×").tag($0) }
                }.labelsHidden().frame(width: 180)
            }
            settingRow("画面比例") {
                Picker("画面比例", selection: $store.aspect) { Text("自动").tag("-1"); Text("16:9").tag("16:9"); Text("4:3").tag("4:3"); Text("2.35:1").tag("2.35:1") }.labelsHidden().frame(width: 180)
            }
            Toggle("自动播放下一个", isOn: $store.autoNext)
            Toggle("单个视频循环", isOn: $store.repeatFile)
            Toggle("窗口置顶", isOn: $store.alwaysOnTop)
        }.toggleStyle(.switch).controlSize(.mini)
        settingsGroup("其他") {
            Button("保存当前画面…") { store.screenshot() }.disabled(store.current == nil)
            DisclosureGroup("媒体信息", isExpanded: $store.mediaDetailsExpanded) {
                VStack(spacing: 11) {
                    information("画面尺寸", store.resolution)
                    information("视频编码", store.codec)
                    information("解码方式", store.hardware == "no" ? "软件解码" : store.hardware)
                    information("帧率", store.fps > 0 ? String(format: "%.2f fps", store.fps) : "")
                    information("丢帧数", store.current == nil ? "" : "\(Int(store.droppedFrames))")
                }.padding(.top, 14)
            }.disabled(store.current == nil)
        }
    }
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 16, content: content).padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        }.font(.system(size: 12)).controlSize(.small)
    }
    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack { Text(title); Spacer(minLength: 16); content() }
    }
    private func readiness(_ ready: Bool, ready message: String, missing: String) -> some View {
        Label(ready ? message : missing, systemImage: ready ? "checkmark.circle" : "arrow.down.circle").font(.system(size: 10)).foregroundStyle(ready ? Palette.muted : .orange)
    }
    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = "", decimals: Int = 0) -> some View {
        HStack(spacing: 16) {
            Text(title).frame(width: 65, alignment: .leading)
            Slider(value: value, in: range).controlSize(.mini)
            Text(String(format: "%.*f%@", decimals, value.wrappedValue, suffix)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 48, alignment: .trailing)
        }
    }
    private func information(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Palette.muted); Spacer(); Text(value.isEmpty ? "—" : value).lineLimit(1) }.font(.system(size: 11))
    }
}
