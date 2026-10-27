# 熊猫播放器 Homebrew Cask

本目录的 `Casks/ai-video-player.rb` 指向 GitHub Releases 中的原生 macOS 安装包，适用于 Apple Silicon、macOS 26 或以上。

在仓库根目录可安装此 Cask：

```bash
brew install --cask ./homebrew/Casks/ai-video-player.rb
```

也可将 Cask 放入自己的 Homebrew tap 仓库供其他人安装。发布新版本时，先运行 `native-macos/scripts/package-mac.sh`，上传 ZIP 至 GitHub Releases，再更新 Cask 中的版本和 ZIP SHA-256。

安装后的应用为「熊猫播放器.app」。AI 模型在设置中按需下载，或选择已有模型目录。当前安装包采用 ad-hoc 签名，尚未作 Apple 公证。
