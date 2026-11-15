#!/usr/bin/env bash
# 在 macOS 上编译 ParadigmMod（arm64, iOS 15+）
# 产物：
#   build/ParadigmMod.framework        —— 注入 App 用
#   build/ParadigmMod.dylib            —— 直接注入 UnityFramework 用
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="build"
mkdir -p "$OUT/ParadigmMod.framework"
rm -f "$OUT/ParadigmMod.framework/ParadigmMod" "$OUT/ParadigmMod.dylib"

SRC=(
  Sources/PMBootstrap.mm
  Sources/PMCore.mm
  Sources/PMOverlay.mm
)

COMMON=(
  -arch arm64
  -miphoneos-version-min=15.0
  -isysroot "$SDK"
  -std=c++17
  -fobjc-arc
  -O2
  -dynamiclib
  # 老版本签名工具（ldid / 全能签等）对 chained fixups 支持不好，退回经典 bind opcodes
  -Wl,-no_fixup_chains
  -framework Foundation
  -framework UIKit
  -framework CoreGraphics
)

# 1) framework 形式（LC_LOAD_DYLIB 指向 @loader_path/../ParadigmMod.framework/ParadigmMod）
xcrun --sdk iphoneos clang++ "${COMMON[@]}" \
  -install_name "@rpath/ParadigmMod.framework/ParadigmMod" \
  -o "$OUT/ParadigmMod.framework/ParadigmMod" "${SRC[@]}"
cp Resources/Info.plist "$OUT/ParadigmMod.framework/Info.plist"

# 2) 独立 dylib（放到 App/Frameworks/ParadigmMod.dylib 时可直接加载）
xcrun --sdk iphoneos clang++ "${COMMON[@]}" \
  -install_name "@executable_path/Frameworks/ParadigmMod.dylib" \
  -o "$OUT/ParadigmMod.dylib" "${SRC[@]}"

codesign --force --sign - "$OUT/ParadigmMod.framework/ParadigmMod"
codesign --force --sign - "$OUT/ParadigmMod.dylib"

echo "built:"
ls -l "$OUT/ParadigmMod.dylib" "$OUT/ParadigmMod.framework/ParadigmMod"
