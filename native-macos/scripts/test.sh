#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/clang-cache .build/swift-cache .build/fixtures
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift run --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" PlayerCoreChecks
ffmpeg="${FFMPEG_BIN:-$PWD/../node_modules/ffmpeg-static/ffmpeg}"
if [ ! -x "$ffmpeg" ]; then ffmpeg="$(command -v ffmpeg)"; fi
fixtures="$PWD/.build/fixtures"
"$ffmpeg" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=24' -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 6 -c:v libx264 -pix_fmt yuv420p -c:a aac "$fixtures/h264.mp4"
"$ffmpeg" -hide_banner -loglevel error -y -i "$fixtures/h264.mp4" -c:v copy -c:a ac3 "$fixtures/h264-ac3.mkv"
"$ffmpeg" -hide_banner -loglevel error -y -i "$fixtures/h264.mp4" -an -c:v libx265 -x265-params log-level=error:pools=1 -pix_fmt yuv420p10le "$fixtures/hevc10.mkv"
"$ffmpeg" -hide_banner -loglevel error -y -i "$fixtures/h264.mp4" -an -c:v libvpx-vp9 -deadline realtime -cpu-used 8 "$fixtures/vp9.webm"
"$ffmpeg" -hide_banner -loglevel error -y -i "$fixtures/h264.mp4" -an -c:v mpeg4 "$fixtures/mpeg4.avi"
cat > "$fixtures/subtitle.srt" <<'SUBTITLE'
1
00:00:00,000 --> 00:00:05,800
PandaPlayer · 原生字幕测试
SUBTITLE
"$ffmpeg" -hide_banner -loglevel error -y -i "$fixtures/h264.mp4" -f lavfi -i 'sine=frequency=660:sample_rate=48000' -i "$fixtures/subtitle.srt" -map 0:v -map 0:a -map 1:a -map 2:s -t 6 -c:v copy -c:a aac -c:s ass -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn "$fixtures/multitrack-ass.mkv"
swift build --product PandaPlayer --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
binary="$(swift build --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --show-bin-path)/PandaPlayer"
"$binary" --smoke-test "$fixtures/h264.mp4" "$fixtures/h264-ac3.mkv" "$fixtures/hevc10.mkv" "$fixtures/vp9.webm" "$fixtures/mpeg4.avi" "$fixtures/multitrack-ass.mkv"
if [ "${PANDAPLAYER_RENDER_TEST:-0}" = "1" ]; then
    "$binary" --render-test "$fixtures/h264.mp4" "$fixtures/hevc10.mkv" "$fixtures/multitrack-ass.mkv"
fi
if [ "${PANDAPLAYER_WINDOW_TEST:-0}" = "1" ]; then
    PANDAPLAYER_STATE_DIR="$PWD/.build/window-test" "$binary" --window-test "$fixtures/h264-ac3.mkv"
fi

if [ "${PANDAPLAYER_FULLSCREEN_TEST:-0}" = "1" ]; then
    for resolution in 1920x1080 3840x2160; do
        "$ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=${resolution}:rate=24" -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 20 -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p -c:a aac "$fixtures/fullscreen-${resolution}.mp4"
        PANDAPLAYER_STATE_DIR="$PWD/.build/fullscreen-${resolution}" "$binary" --fullscreen-test "$fixtures/fullscreen-${resolution}.mp4"
    done
fi
