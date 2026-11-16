#!/bin/bash
# 不安装，在本进程里加载 dist/LepakMic.driver 自测一遍（见 Driver/LepakMic/SelfTest.c）。
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-mic-driver.sh >/dev/null
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
clang -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -framework CoreAudio -framework CoreFoundation \
    -o "$TMP/SelfTest" Driver/LepakMic/SelfTest.c
"$TMP/SelfTest" "$PWD/dist/LepakMic.driver"
