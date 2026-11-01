#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --product PandaPlayer --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
fixture_dir="$(mktemp -d "$PWD/.build/translation-fixture-XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/models"
python3 - "$fixture_dir/models/Qwen2.5-7B-Instruct-Q4_K_M.gguf" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(bytes(100_001))
PY
PANDAPLAYER_TRANSLATION_TEST_DIR="$fixture_dir" \
PANDAPLAYER_STATE_DIR="$fixture_dir" \
PANDAPLAYER_MODELS="$fixture_dir/models" \
PANDAPLAYER_AI_BIN="$PWD/Tests/Fixtures" \
.build/debug/PandaPlayer --translation-controller-test
