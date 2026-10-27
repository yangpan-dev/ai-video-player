cask "ai-video-player" do
  version "0.3.1"
  sha256 "2b1f1369e085f09e4f5fe994061a2c35edb7e4fd3965d5b935867c1f1b224435"

  url "https://github.com/yangpan-dev/ai-video-player/releases/download/v#{version}/PandaPlayer-#{version}-arm64-mac.zip"
  name "熊猫播放器"
  desc "本地 AI 视频播放器：无字幕日语/英语视频实时生成原文 + 中文字幕（完全离线）"
  homepage "https://github.com/yangpan-dev/ai-video-player"

  # Apple Silicon 专用（whisper.cpp 为 arm64 Metal 构建）
  depends_on arch: :arm64
  depends_on macos: ">= 26"

  app "熊猫播放器.app"

  # 首次启动需要联网下载 Whisper 模型与 Qwen 翻译模型，后续离线可用
  caveats <<~EOS
    首次打开若被 Gatekeeper 拦截，右键点击 App →「打开」。
    首次使用需在应用内点击「下载模型」与「下载翻译模型」（约 4.4GB），之后离线可用。
  EOS

  zap trash: [
    "~/Library/Application Support/PandaPlayer",
    "~/Library/Caches/dev.panda.player"
  ]
end
