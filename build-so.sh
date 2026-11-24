#!/usr/bin/env bash
# 编译最小 NAPI 桥 libharbor_bridge.so（OHOS aarch64）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LLVM="$HOME/.harmonybrew/opt/ohos-sdk/native/llvm/bin"
SYS="$HOME/.harmonybrew/opt/ohos-sdk-native/sysroot"
SRC="$HERE/entry/src/main/cpp/harbor_bridge.c"
OUT="$HERE/entry/src/main/cpp/libs/arm64-v8a"
mkdir -p "$OUT"

"$LLVM/clang" \
  --target=aarch64-unknown-linux-ohos \
  --sysroot="$SYS" \
  -fPIC -shared -O0 -g \
  -I"$SYS/usr/include/napi" \
  -I"$SYS/usr/include" \
  "$SRC" \
  -L"$SYS/usr/lib/aarch64-linux-ohos" \
  -lace_napi.z \
  -Wl,-z,global \
  -o "$OUT/libharbor_bridge.so"

echo "built: $OUT/libharbor_bridge.so"
file "$OUT/libharbor_bridge.so"
