#!/bin/bash
# 下载 Espressif 官方的 esptool 独立版（macOS arm64），给 AI Passport 装固件用（见 PassportFirmware.swift）。
# 版本和 SHA-256 写死在这里，压缩包对不上就停止；下载过就直接用 .build/esptool/ 里的。
# 只留 esptool 本体和它的 LICENSE（GPL-2.0，作为独立程序调用，随 App 附上许可证）。
#
# 用法：scripts/fetch-esptool.sh   输出 esptool 所在的文件夹
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="v5.6.0"
ASSET="esptool-${VERSION}-macos-arm64.tar.gz"
SHA256="08a58829a3f14bb08f2e39f4cad48dcb14b7000384268e7f06689836332d6e25"
OUT=".build/esptool/${VERSION}"

if [[ ! -x "$OUT/esptool" || ! -f "$OUT/LICENSE" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL -o "$TMP/$ASSET" "https://github.com/espressif/esptool/releases/download/${VERSION}/${ASSET}"
    ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
    if [[ "$ACTUAL" != "$SHA256" ]]; then
        echo "esptool 压缩包校验失败：$ACTUAL" >&2
        exit 1
    fi
    mkdir -p "$TMP/x"
    tar -xzf "$TMP/$ASSET" -C "$TMP/x"
    DIR="$(dirname "$(find "$TMP/x" -type f -name esptool -perm -u+x | head -n 1)")"
    if [[ ! -x "$DIR/esptool" || ! -f "$DIR/LICENSE" ]]; then
        echo "esptool 压缩包里没找到 esptool 或 LICENSE" >&2
        exit 1
    fi
    rm -rf "$OUT"
    mkdir -p "$OUT"
    cp "$DIR/esptool" "$DIR/LICENSE" "$OUT/"
    chmod +x "$OUT/esptool"
fi
echo "$OUT"
