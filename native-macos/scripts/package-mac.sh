#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${PANDAPLAYER_LIBMPV:-}" ]; then
    for candidate in /opt/homebrew/lib/libmpv.2.dylib /usr/local/lib/libmpv.2.dylib /Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib; do
        if [ -f "$candidate" ]; then export PANDAPLAYER_LIBMPV="$candidate"; break; fi
    done
fi
: "${PANDAPLAYER_LIBMPV:?No libmpv found. Install mpv or set PANDAPLAYER_LIBMPV.}"
export PANDAPLAYER_ARCH="${PANDAPLAYER_ARCH:-$(uname -m)}"
CONFIGURATION=release BUNDLE_MPV=1 ./scripts/build-app.sh
app="$PWD/build/PandaPlayer.app"
python3 scripts/verify-bundle.py "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
name="PandaPlayer-${version}-${PANDAPLAYER_ARCH}-mac"
mkdir -p dist build/pandaplayer-dmg-root
if [ -d build/pandaplayer-dmg-root/PandaPlayer.app ]; then python3 -c 'import shutil; shutil.rmtree("build/pandaplayer-dmg-root/PandaPlayer.app")'; fi
cp -R "$app" build/pandaplayer-dmg-root/PandaPlayer.app
if [ ! -L build/pandaplayer-dmg-root/Applications ]; then ln -s /Applications build/pandaplayer-dmg-root/Applications; fi
cat > build/pandaplayer-dmg-root/安装说明.txt <<'NOTICE'
将 PandaPlayer.app 拖入 Applications（应用程序）文件夹，即可安装。
此包已包含播放引擎，无需安装 IINA、Homebrew 或 mpv。
适用：Apple Silicon（M 系列）Mac，macOS 26 或以上。
此为本机签名、未公证的本地测试包。
NOTICE
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/${name}.zip"
hdiutil create -volname "PandaPlayer ${version}" -srcfolder "$PWD/build/pandaplayer-dmg-root" -ov -format UDZO "$PWD/dist/${name}.dmg"
hdiutil verify "$PWD/dist/${name}.dmg"
shasum -a 256 "$PWD/dist/${name}.zip" "$PWD/dist/${name}.dmg" > dist/SHA256SUMS.txt
printf 'Packaged: %s\n' "$PWD/dist/${name}.dmg" "$PWD/dist/${name}.zip"
