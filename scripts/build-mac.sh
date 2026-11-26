#!/usr/bin/env bash
# macOS 一键打包：编译 AI 引擎 → 构建 .app → ad-hoc 签名 → 归档 ZIP → 输出校验和。
# 必须在 macOS（Apple Silicon）上运行，Windows / Linux 无法产出可用的 mac 包。
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "❌ 只能在 macOS 上运行：Electron 的 mac 目标依赖 hdiutil / codesign / otool，且 AI 引擎需要编译成 Mach-O。" >&2
  exit 1
fi

echo "== 1/5 检查工具链 =="
if ! xcode-select -p >/dev/null 2>&1; then
  echo "❌ 缺少 Xcode Command Line Tools，请先运行：xcode-select --install" >&2
  exit 1
fi
command -v cmake >/dev/null 2>&1 || { echo "❌ 缺少 cmake，请先安装：brew install cmake" >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { echo "❌ 缺少 pnpm，请先安装：corepack enable && corepack prepare pnpm@10 --activate" >&2; exit 1; }

echo "== 2/5 安装依赖（已有 node_modules 则跳过）=="
if [[ ! -d node_modules ]]; then
  pnpm install
fi

echo "== 3/5 编译 whisper.cpp / llama.cpp（darwin-$(uname -m)）=="
# 脚本内部已固定 GGML_NATIVE=OFF，产出的二进制不绑定编译机的指令集。
pnpm run build:whisper
pnpm run build:llama

echo "== 4/5 构建应用并发起 ad-hoc 签名 =="
pnpm run build:mac:release

echo "== 5/5 生成校验和 =="
shopt -s nullglob
artifacts=(dist/*.zip dist/*.dmg)
if (( ${#artifacts[@]} == 0 )); then
  echo "❌ 没有在 dist/ 下找到 zip 或 dmg 产物" >&2
  exit 1
fi
shasum -a 256 "${artifacts[@]}" | tee dist/SHA256SUMS.txt

echo
echo "✅ 完成，产物："
for f in "${artifacts[@]}"; do
  echo "   $root/$f"
done
echo
echo "提示：ad-hoc 签名未做 Apple 公证，分发给他人时对方首次打开需右键「打开」或执行"
echo "      xattr -dr com.apple.quarantine /Applications/熊猫播放器.app"
