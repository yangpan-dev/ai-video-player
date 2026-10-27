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
app="$PWD/build/熊猫播放器.app"
python3 scripts/verify-bundle.py "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
name="PandaPlayer-${version}-${PANDAPLAYER_ARCH}-mac"
mkdir -p dist
# Recreate this generated staging folder so renamed apps cannot leak into a new DMG.
python3 -c 'import shutil; shutil.rmtree("build/pandaplayer-dmg-root", ignore_errors=True)'
mkdir -p build/pandaplayer-dmg-root
cp -R "$app" build/pandaplayer-dmg-root/熊猫播放器.app
if [ ! -L build/pandaplayer-dmg-root/Applications ]; then ln -s /Applications build/pandaplayer-dmg-root/Applications; fi
cat > build/pandaplayer-dmg-root/安装说明.txt <<'NOTICE'
将 熊猫播放器.app 拖入 Applications（应用程序）文件夹，即可安装。
此包已包含播放引擎，无需安装 IINA、Homebrew 或 mpv。
适用：Apple Silicon（M 系列）Mac，macOS 26 或以上。
此包采用 ad-hoc 签名，未作 Apple 公证。首次打开请在系统设置 → 隐私与安全性中允许。
NOTICE
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/${name}.zip"
hdiutil create -volname "熊猫播放器 ${version}" -srcfolder "$PWD/build/pandaplayer-dmg-root" -ov -format UDZO "$PWD/dist/${name}.dmg"
hdiutil verify "$PWD/dist/${name}.dmg"
(cd dist && shasum -a 256 "${name}.zip" "${name}.dmg") > dist/SHA256SUMS.txt
printf 'Packaged: %s\n' "$PWD/dist/${name}.dmg" "$PWD/dist/${name}.zip"
