import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlayerCore

enum Palette {
    static let background = Color(red: 15/255, green: 17/255, blue: 21/255)
    static let panel = Color(red: 23/255, green: 26/255, blue: 33/255)
    static let card = Color.white.opacity(0.045)
    static let accent = Color(red: 79/255, green: 140/255, blue: 1)
    static let muted = Color(red: 154/255, green: 161/255, blue: 181/255)
    static let border = Color(red: 42/255, green: 47/255, blue: 61/255)
}

struct ContentView: View {
    @ObservedObject var store: PlayerStore
    var body: some View {
        VStack(spacing: 0) {
            if !store.fullscreenLayout { titlebar; Divider() }
            HStack(spacing: 0) {
                if store.sidebarVisible && !store.fullscreenLayout {
                    sidebar.frame(width: 220)
                    Rectangle().fill(Palette.border).frame(width: 1)
                }
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        VideoSurface(store: store)
                        if store.current == nil { welcome }
                        if store.isLoading { ProgressView().controlSize(.large).padding(18).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)) }
                        if let notice = store.notice {
                            VStack { Spacer(); Text(notice).font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 20) }.allowsHitTesting(false)
                        }
                        if store.dropTargeted {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(12)
                                .overlay(Label("松开以添加", systemImage: "arrow.down.doc").font(.title3).padding(22).background(Palette.panel, in: RoundedRectangle(cornerRadius: 14)))
                        }
                        if store.fullscreenLayout {
                            transport.opacity(store.controlsVisible ? 1 : 0)
                                .allowsHitTesting(store.controlsVisible)
                                .accessibilityHidden(!store.controlsVisible)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .onDrop(of: [.fileURL], isTargeted: $store.dropTargeted, perform: drop)
                    if !store.fullscreenLayout { transport }
                    if !store.fullscreenLayout { AIStatusBar(store: store, ai: store.ai) }
                }.frame(minWidth: 440)
            }
        }
        // The custom titlebar already reserves its own height. Do not let AppKit's
        // changing native titlebar safe area add/remove another inset during fullscreen.
        .ignoresSafeArea()
        .background(Palette.background)
        .foregroundStyle(.white.opacity(0.9))
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $store.settingsVisible) { AppSettingsView(store: store, ai: store.ai) }
        .alert("播放提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private var titlebar: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 66, height: 12)
            iconButton("sidebar.left", help: "显示或隐藏播放列表（⌘1）") { store.sidebarVisible.toggle() }
            if let icon = AppAssets.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
            Text("熊猫播放器").font(.system(size: 12, weight: .semibold, design: .rounded))
            if let current = store.current {
                Text("/").foregroundStyle(Palette.border)
                Text(current.title).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            AIControlBar(store: store, ai: store.ai)
            iconButton("gearshape", help: "设置（⌘,）") { store.openSettings() }
        }.padding(.horizontal, 16).frame(height: 50).background(WindowDragArea())
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                libraryTab("列表", section: "playlist")
                libraryTab("最近", section: "recent")
                Spacer(minLength: 0)
                Menu {
                    Button("添加视频…") { store.openPanel(append: true) }
                    Button("添加文件夹…") { store.openPanel(folder: true) }
                    Divider()
                    Toggle("按名称排序", isOn: $store.sortByName)
                    Button("清空播放列表") { store.clearList() }.disabled(store.playlist.isEmpty)
                } label: { Image(systemName: "plus").font(.system(size: 12)).frame(width: 22, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().help("添加视频或文件夹，含全部子文件夹").disabled(store.isScanning)
            }.padding(.horizontal, 13).padding(.top, 18).padding(.bottom, 14)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Palette.muted)
                TextField("搜索", text: $store.search).textFieldStyle(.plain).font(.system(size: 11))
            }.padding(9).background(Palette.card, in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12).padding(.bottom, 12)
            if store.visibleItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack").font(.system(size: 23, weight: .light))
                    Text(store.search.isEmpty ? "还没有视频" : "没有匹配的视频").font(.system(size: 11))
                    if store.search.isEmpty {
                        Button("添加文件夹…") { store.openPanel(folder: true) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                    }
                }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.top, 32)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.visibleItems) { item in
                            Button { store.open(item) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: store.current?.id == item.id ? "waveform" : "play.rectangle")
                                        .font(.system(size: 14, weight: .light)).foregroundStyle(store.current?.id == item.id ? Palette.accent : Palette.muted).frame(width: 21)
                                    Text(item.title).font(.system(size: 11, weight: store.current?.id == item.id ? .medium : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 11).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.current?.id == item.id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).help(item.url.path)
                                .contextMenu {
                                    Button("播放") { store.open(item) }
                                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                    if store.selectedSection == "playlist" { Button("从列表移除") { store.remove(item) } }
                                }
                        }
                    }.padding(.horizontal, 8)
                }
            }
            if store.isScanning {
                HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("正在添加 · \(store.scanCount)").font(.system(size: 10)); Spacer() }
                    .foregroundStyle(Palette.muted).padding(14)
            } else {
                Text("\(store.selectedSection == "recent" ? store.recent.count : store.playlist.count) 个视频")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading).padding(15)
                    .help(store.importStatus)
            }
        }.background(Palette.panel.opacity(0.6))
    }
    private func libraryTab(_ title: String, section: String) -> some View {
        Button { store.selectedSection = section } label: {
            Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 6)
                .foregroundStyle(store.selectedSection == section ? .white.opacity(0.9) : Palette.muted)
                .background(store.selectedSection == section ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private var welcome: some View {
        VStack(spacing: 0) {
            if let icon = AppAssets.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 100, height: 100).padding(.bottom, 22) }
            Text("熊猫播放器").font(.system(size: 24, weight: .medium)).tracking(1)
            Text("拖入视频或文件夹即可开始").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 12)
            Button { store.openPanel() } label: {
                Label("打开视频", systemImage: "folder").font(.system(size: 12, weight: .medium)).padding(.horizontal, 22).padding(.vertical, 11)
                    .foregroundStyle(.white).background(Palette.accent, in: Capsule())
            }.buttonStyle(.plain).padding(.top, 26)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
    }
    private var transport: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(PlaybackTime.label(store.position)).frame(minWidth: 40, alignment: .leading)
                Slider(value: $store.position, in: 0...max(store.duration, 1), onEditingChanged: { editing in
                    store.isScrubbing = editing
                    if !editing { store.seek(store.position) }
                }).controlSize(.mini).disabled(store.current == nil)
                Text(PlaybackTime.label(store.duration)).foregroundStyle(Palette.muted).frame(minWidth: 40, alignment: .trailing)
            }.font(.system(size: 10, weight: .medium, design: .monospaced))
            HStack(spacing: 12) {
                Button { store.muted.toggle() } label: { Image(systemName: store.muted ? "speaker.slash" : "speaker.wave.2").frame(width: 18) }.buttonStyle(.plain).foregroundStyle(Palette.muted).help("静音")
                Slider(value: $store.volume, in: 0...100).controlSize(.mini).frame(width: 64).help("音量")
                Spacer(minLength: 8)
                iconButton("backward.end.fill", help: "上一个视频") { store.adjacent(-1) }
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16)).offset(x: store.isPlaying ? 0 : 1)
                        .foregroundStyle(.white).frame(width: 40, height: 40).background(Color.white.opacity(0.09), in: Circle())
                }.buttonStyle(.plain).help("播放或暂停（空格）")
                iconButton("forward.end.fill", help: "下一个视频") { store.adjacent(1) }
                Spacer(minLength: 8)
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2.0], id: \.self) { speed in Button("\(speed.formatted())×") { store.speed = speed } }
                } label: { Text("\(store.speed.formatted())×").font(.system(size: 11, weight: .medium, design: .monospaced)) }.menuStyle(.borderlessButton).fixedSize().help("播放速度")
                SubtitleQuickMenu(store: store, ai: store.ai)
                iconButton("arrow.up.left.and.arrow.down.right", help: "全屏（F）") { store.toggleFullscreen() }
            }
        }.padding(.horizontal, 22).padding(.top, 13).padding(.bottom, 16).background(Palette.panel.opacity(0.4))
    }
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup(), lock = NSLock()
        var urls = [URL]()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else { url = nil }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { store.add(urls) }
        return true
    }
}

enum AppAssets {
    static let icon: NSImage? = Bundle.main.url(forResource: "PandaPlayer-icon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
}

func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle()) }.buttonStyle(.plain).help(help).accessibilityLabel(help)
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class DragView: NSView { override var mouseDownCanMoveWindow: Bool { true } }
}
