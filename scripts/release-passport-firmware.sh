#!/bin/bash
# 发布 Lepak 的 AI Passport 固件：编译 Firmware/Passport，把三段镜像和清单放进 Firmware/Passport/release/。
# release/ 要提交进仓库；scripts/package-app.sh 把它原样复制进 Lepak.app，固件跟着 Lepak 的版本一起发布、升级
# （用户 2026-11-16 定的：不单独架服务器）。
#
# 发新固件：先改 Firmware/Passport/CMakeLists.txt 里的 PROJECT_VER，再跑这个脚本，然后提交、打包发布 Lepak。
# 清单格式和设备页「固件」安装器读的一样（见 Sources/LepakKit/PassportFirmware.swift），另加 "pair": 1：
# 这版固件蓝牙必须配对，安装器据此拒绝装回没有配对保护的固件。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/Firmware/Passport"
OUT="$FW/release"

"$ROOT/scripts/build-passport-firmware.sh" >/dev/null

VERSION="$(sed -n 's/^set(PROJECT_VER "\(.*\)")$/\1/p' "$FW/CMakeLists.txt")"
[[ -n "$VERSION" ]] || { echo "没找到 PROJECT_VER" >&2; exit 1; }
# 构建号：固件 ELF 的 SHA-256 前 8 位，和设备 hello 里报的 build 一样。
BUILD="$(shasum -a 256 "$FW/build/VibeKey-Passport.elf" | cut -c1-8)"
# 核对：esptool 把它写在应用镜像 0xB0 处（esp_app_desc 的 app_elf_sha256）。
IN_IMAGE="$(xxd -s 0xB0 -l 4 -p "$FW/build/VibeKey-Passport.bin")"
[[ "$BUILD" == "$IN_IMAGE" ]] || { echo "构建号对不上：ELF $BUILD，镜像里 $IN_IMAGE" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$FW/build/bootloader/bootloader.bin" "$OUT/bootloader.bin"
cp "$FW/build/partition_table/partition-table.bin" "$OUT/partition-table.bin"
cp "$FW/build/VibeKey-Passport.bin" "$OUT/app.bin"

entry() {   # offset 文件名
    local size sha
    size="$(stat -f %z "$OUT/$2")"
    sha="$(shasum -a 256 "$OUT/$2" | cut -d' ' -f1)"
    printf '    {"offset": "%s", "path": "%s", "size": %s, "sha256": "%s"}' "$1" "$2" "$size" "$sha"
}

{
    echo '{'
    echo '  "name": "Lepak AI Passport",'
    echo "  \"version\": \"$VERSION\","
    echo "  \"build\": \"$BUILD\","
    echo '  "proto": 1,'
    echo '  "pair": 1,'
    echo '  "chip": "ESP32-C3",'
    echo '  "flashSize": "8MB",'
    echo '  "images": ['
    entry 0x0 bootloader.bin; echo ','
    entry 0x8000 partition-table.bin; echo ','
    entry 0x10000 app.bin; echo
    echo '  ]'
    echo '}'
} > "$OUT/manifest.json"

/usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT/manifest.json"
echo "已发布固件 $VERSION（$BUILD）到 $OUT"
