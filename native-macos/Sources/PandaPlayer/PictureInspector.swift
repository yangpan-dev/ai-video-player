import SwiftUI
import PlayerCore

struct PictureInspector: View {
    @ObservedObject var store: PlayerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 24) { pictureControls }
    }
    @ViewBuilder private var pictureControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            eyebrow("画面风格", trailing: "实时生效")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 8) {
                ForEach(PicturePreset.allCases) { preset in
                    Button { store.setPreset(preset) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: preset.symbol).font(.system(size: 15, weight: .light))
                            Text(preset.title).font(.system(size: 11, weight: .medium))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .foregroundStyle(store.preset == preset ? Palette.accent : .white.opacity(0.65))
                            .background(store.preset == preset ? Palette.accent.opacity(0.09) : Palette.card, in: RoundedRectangle(cornerRadius: 9))
                            .overlay { RoundedRectangle(cornerRadius: 9).stroke(store.preset == preset ? Palette.accent.opacity(0.4) : Palette.border, lineWidth: 1) }
                    }.buttonStyle(.plain).help(preset.detail)
                }
            }
            Text(store.preset.detail).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("细节增强")
            settingToggle("高质量缩放", detail: "Lanczos 放大，保留边缘细节", value: $store.picture.highQualityScaling)
            adjustment("锐化", value: $store.picture.sharpness, range: 0...1, suffix: "", scale: 100)
            settingToggle("平滑色阶", detail: "减少天空与暗部的色带", value: $store.picture.deband)
            settingToggle("轻度降噪", detail: "适合老片或低码率片源", value: $store.picture.denoise)
            settingToggle("隔行扫描修复", detail: "改善旧录像中的梳齿边缘", value: $store.picture.deinterlace)
        }.disabled(store.compareOriginal)
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("色彩与光线")
            adjustment("亮度", value: $store.picture.brightness, range: -30...30)
            adjustment("对比度", value: $store.picture.contrast, range: -30...30)
            adjustment("饱和度", value: $store.picture.saturation, range: -30...30)
            adjustment("暗部提亮", value: $store.picture.gamma, range: -30...30)
            settingToggle("HDR 色调映射", detail: "将 HDR 明暗映射到 SDR 画面", value: $store.picture.toneMapping)
        }.disabled(store.compareOriginal)
        VStack(spacing: 12) {
            Toggle(isOn: $store.compareOriginal) { Label("对比原片", systemImage: "circle.lefthalf.filled").font(.system(size: 11, weight: .medium)) }.toggleStyle(.switch).controlSize(.mini)
            Button { store.compareOriginal = false; store.setPreset(.balanced) } label: { Label("恢复默认画面", systemImage: "arrow.counterclockwise").font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 9).background(Palette.card, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).foregroundStyle(Palette.muted)
        }
        Text("优化效果取决于片源。锐化和放大可以改善观感，但无法还原片源中不存在的细节。降噪会增加解码负担。")
            .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
    }
    private func eyebrow(_ text: String, trailing: String = "") -> some View {
        HStack { Text(text).font(.system(size: 10, weight: .semibold)); Spacer(); Text(trailing).font(.system(size: 9)).foregroundStyle(Palette.accent.opacity(0.7)) }.foregroundStyle(Palette.muted)
    }
    private func settingToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 11, weight: .medium)); Text(detail).font(.system(size: 9)).foregroundStyle(Palette.muted) }
        }.toggleStyle(.switch).controlSize(.mini)
    }
    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = "", scale: Double = 1, decimals: Int = 0) -> some View {
        VStack(spacing: 9) {
            HStack { Text(title).font(.system(size: 11)); Spacer(); Text(String(format: "%.*f%@", decimals, value.wrappedValue * scale, suffix)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Palette.muted) }
            Slider(value: value, in: range).controlSize(.mini)
        }
    }
    private func info(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Palette.muted); Spacer(); Text(value.isEmpty ? "—" : value).lineLimit(1) }.font(.system(size: 10))
    }
}
