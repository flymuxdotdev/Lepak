#!/bin/bash
# 编译虚拟麦克风驱动 dist/LepakMic.driver（Apple 芯片和 Intel 都能用），临时签名。
# 安装用 scripts/install-mic-driver.sh（要管理员密码）。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="dist/LepakMic.driver"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp Driver/LepakMic/Info.plist "$OUT/Contents/Info.plist"
clang -bundle -O2 -Wall -Wextra -Werror \
    -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -fvisibility=hidden \
    -framework CoreAudio -framework CoreFoundation \
    -o "$OUT/Contents/MacOS/LepakMic" Driver/LepakMic/LepakMic.c
xattr -cr "$OUT"
codesign --force --sign - "$OUT"
echo "已编译：$OUT"
