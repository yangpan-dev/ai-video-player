#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-debug}"
mkdir -p .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c "$configuration" --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
binary_dir="$(swift build -c "$configuration" --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --show-bin-path)"
app="$PWD/build/staging/PandaPlayer.app"
if [ -d "$app" ]; then /usr/bin/python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$binary_dir/PandaPlayer" "$app/Contents/MacOS/PandaPlayer"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ] || [ Resources/PandaPlayer-icon.png -nt build/AppIcon.icns ]; then
    swift -module-cache-path "$PWD/.build/clang-cache" scripts/make-icon.swift "$PWD/build/AppIcon.iconset"
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/"
cp Resources/PandaPlayer-icon.png "$app/Contents/Resources/"
cp THIRD_PARTY.md "$app/Contents/Resources/THIRD_PARTY.md"
python3 scripts/bundle-ai.py "$app"
if [ "${BUNDLE_MPV:-0}" = "1" ]; then
    python3 scripts/bundle-mpv.py "$app" "${PANDAPLAYER_LIBMPV:-/opt/homebrew/lib/libmpv.2.dylib}"
fi
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [ -d "$PWD/build/PandaPlayer.app" ]; then /usr/bin/python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$PWD/build/PandaPlayer.app"; fi
mv "$app" "$PWD/build/PandaPlayer.app"
printf 'Built: %s\n' "$PWD/build/PandaPlayer.app"
