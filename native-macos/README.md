# PandaPlayer · 原生 macOS 视频播放器

独立于 Electron 版本的 Swift 工程。使用 SwiftUI / AppKit 构建界面，libmpv 实时解码和渲染视频，不需要先把整部电影转换为 MP4。

## 当前功能

- 多格式播放：MKV、MP4、AVI、MOV、WebM、TS/M2TS、WMV、FLV、MPEG、VOB、RMVB、MXF 等入口。实际编码支持由加载的 libmpv / FFmpeg 决定；不保证所有损坏、加密或特殊编码文件都能播放。
- 播放列表、文件夹递归导入、自然排序、搜索、最近播放、观看进度恢复、自动下一集、单片循环。
- 播放 / 暂停、精确拖动、倍速、音量、静音、全屏、窗口置顶、画面比例和 PNG 截图。
- 多音轨、内嵌字幕、外部 SRT/ASS/SSA/VTT/PGS 字幕、字幕大小和时间偏移。
- 五种画面预设：原片、清晰自然、影院、动画、低清优化。
- EWA Lanczos 高质量放大、轻度锐化、去色带、hqdn3d 降噪、去隔行、亮度 / 对比度 / 饱和度 / Gamma。
- HDR → SDR 色调映射；当前视频输出为 SDR，不输出原生 EDR / Dolby Vision。
- 原片对比和画面设置记忆。所有处理只影响观看，不修改视频文件。
- 参考 Vue 版的深色与蓝色主题，左侧播放列表 / 历史、主工具栏保留 AI 字幕入口，任务状态仅在运行时显示。
- 后台递归扫描多层子文件夹，按完整路径自然排序，重叠目录与重复文件自动去重，无 10,000 文件截断。
- Whisper + Qwen 完全本地识别翻译：流式逐段、整片批量、导入 SRT/VTT 后翻译，双语 / 原文 / 中文字幕及 SRT/VTT 导出。
- 识别语言选择、模型下载与目录选择、字幕缓存恢复、切换视频取消旧任务、退出清理 AI 进程。
- PandaPlayer 熊猫播放图标（PNG 与 ICNS），兼容旧版已有模型与 Lumen 播放列表。

画质增强是实时缩放和画面后处理，**尚未包含神经网络超分辨率、补帧或 AI 修复**。识别和翻译已迁入；AI 引擎与 FFmpeg 随应用打包，模型首次按需下载，或复用旧版已下载模型，不将视频上传到网络。

## 构建运行

完整安装包要求 Apple Silicon + macOS 26 或以上：当前复用的 Whisper / llama.cpp 原生二进制最低部署版本为 26.0，构建会验证此约束。界面源码的 SwiftPM 目标仍为 macOS 14，但要支持旧系统的完整 AI 功能，需要另外重编译兼容版本的引擎。只需要包含 macOS SDK 的 Swift 工具链 / Command Line Tools；也可用 Xcode 打开本目录的 `Package.swift`。

首次克隆仓库时，先在**仓库根目录**准备引擎与构建依赖。`resources/bin`、模型、安装包和构建缓存均不进入 Git：

```bash
# 已安装 Xcode Command Line Tools、Node.js 和 pnpm 的前提下
brew install cmake mpv
pnpm install
pnpm run build:whisper
pnpm run build:llama
node scripts/prepare-mac-resources.mjs
```

以上命令复用仓库已有的引擎构建脚本；`pnpm install` 同时准备 FFmpeg。AI 模型无需预先放入源码目录，运行应用后可在「设置 → 字幕与 AI」中下载，或选择已有模型目录。然后构建原生应用：

```bash
cd native-macos
./scripts/build-app.sh
open build/PandaPlayer.app
```

构建产物：`native-macos/build/PandaPlayer.app`。首次编译系统 SwiftUI 模块可能需要较长时间。

播放器动态寻找引擎，顺序为：

1. `PANDAPLAYER_LIBMPV` 指定的库。
2. App 内 `Contents/Frameworks/libmpv.2.dylib`。
3. Apple Silicon / Intel 的 Homebrew libmpv。
4. **仅 Debug 构建**：本机已安装 IINA 的 `Contents/Frameworks/libmpv.2.dylib`。

当前机器已安装 IINA，Debug 版可直接运行；不会修改 IINA，也不会复制它的二进制。其他机器可通过 `brew install mpv` 准备引擎。使用自定义库时，应让依赖的 `@rpath` 能正确解析。

构建脚本使用 SwiftPM 原生构建后端，兼容当前机器只安装 Command Line Tools 时的构建环境，无需下载第三方 Swift 包。

## 独立安装包

一键生成包含播放引擎的 Release 应用、DMG 和 ZIP：

```bash
./scripts/package-mac.sh
```

产物位于 `dist/PandaPlayer-0.2.1-arm64-mac.dmg` 和同名 ZIP。默认优先查找 Homebrew 的 libmpv，本机没有时使用已安装 IINA 的播放运行库。安装后不再依赖 IINA、旧版播放器或 Homebrew。仅复制所需动态库，保留来源与依赖致谢，并检查包内链接和签名。当前完整包面向 Apple Silicon，最低 macOS 26；未作 Apple 公证。

准备自己可再分发的 libmpv 构建，然后：

```bash
CONFIGURATION=release BUNDLE_MPV=1 \
  PANDAPLAYER_LIBMPV=/opt/homebrew/lib/libmpv.2.dylib \
  ./scripts/build-app.sh
```

脚本递归打包非系统 dylib、调整加载路径，并作本机 ad-hoc 签名。**公开发布前**需要检查 mpv / FFmpeg 等实际构建的许可证、附上所需许可和源码材料，并完成 Developer ID 签名与公证。现有仓库的 MIT 声明不能覆盖这些依赖；详见 [THIRD_PARTY.md](THIRD_PARTY.md)。一键打包只在本地生成文件，不上传或发布。

## 简洁界面（0.2.1）

主界面保留视频、播放列表、播放控制和 AI 字幕按钮。顶部参数栏、常驻模型信息、媒体信息行与重复说明已收起，空闲时不显示任务状态。

- 右上角齿轮或 `⌘,` 打开设置，分为「字幕与 AI、画面、声音、播放」。
- 模型管理、识别模式、原声语言、字幕大小 / 偏移、画质增强、音轨、窗口置顶、循环和媒体信息统一放入设置。
- 底部字幕图标快速切换显示方式、导入 / 翻译 / 导出字幕。
- 列表右上角 `+` 添加视频或文件夹，包含全部子文件夹；排序和清空也在此菜单。
- 快进 / 后退保留键盘方向键，截图可从设置或文件菜单访问。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 打开视频 / 文件夹 | ⌘O / ⇧⌘O |
| 播放 / 暂停 | 空格，或点击画面 |
| 快进 / 后退 | ← / →（视频获得焦点时 Shift 为 30 秒） |
| 音量 | ↑ / ↓（视频获得焦点时） |
| 全屏 | ⌃⌘F，或双击画面；视频获得焦点时 F |
| 上 / 下一个 | ⌘[ / ⌘] |
| 加载字幕 | ⌘L |
| 字幕提前 / 延后 | [ / ]（视频获得焦点时） |
| 保存截图 | ⇧⌘S |
| 原片对比 | ⌘B |
| 播放列表 / 画面设置 | ⌘1 / ⌘2 |
| 设置 | ⌘, |

## 验证

```bash
./scripts/test.sh
```

包括 36 项核心逻辑检查，以及用仓库现有 FFmpeg 生成真实 H.264/AAC、H.264/AC-3 MKV、HEVC 10-bit、VP9 WebM、MPEG-4 AVI、多音轨和 ASS 字幕测试片。集成测试直接调用 libmpv，验证解码、时长、跳转、暂停和画面预设属性。

在可访问图形服务的登录会话中，可追加 GPU 和窗口集成测试：

```bash
PANDAPLAYER_RENDER_TEST=1 PANDAPLAYER_WINDOW_TEST=1 ./scripts/test.sh
```

GPU 测试将真实视频渲染到离屏帧缓冲，检查有效画面、调节后的像素变化以及原片恢复。窗口测试会打开原生窗口、播放生成的 MKV，验证视频视图确实产生帧，随后自动退出；使用独立测试资料库。它们不截取用户桌面。菜单点击、拖放与全屏交互仍需在本机进行人工验收。

## 工程结构

```text
Sources/
  PlayerCore/        媒体类型、预设、属性校验、时间与恢复策略
  CMPV/              libmpv 稳定 C ABI 的最小动态桥接
  PandaPlayer/
    MPVEngine.swift  引擎加载、命令、事件与播放状态
    VideoSurface.swift  原生 OpenGL 视频视图、Retina、键盘和全屏鼠标
    PlayerStore.swift   播放列表、持久化、画面设置和字幕音轨
    ContentView.swift   主窗口与播放控制
    AppSettingsView.swift  字幕与 AI / 画面 / 声音 / 播放设置
    PictureInspector.swift  画面设置内容
Tests/PlayerCoreTests/
Resources/Info.plist
scripts/              构建、依赖打包、测试
```

视频通过 libmpv 的稳定 OpenGL render API 嵌入 AppKit；该 API 对应 mpv 的 `gpu` 渲染路径。OpenGL 在 macOS 已弃用，但当前仍可用。这一版优先验证格式兼容性和实际观看能力；未来可单独替换视频渲染层，不影响资料库和播放业务逻辑。

数据存放于 `~/Library/Application Support/PandaPlayer/library.json`，偏好存放于应用的 UserDefaults。测试可用 `PANDAPLAYER_STATE_DIR` 指定独立资料库目录。
