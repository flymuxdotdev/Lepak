#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product menubar
BIN="$(swift build --product menubar --show-bin-path)/menubar"
APP="dist/Vibe Key.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VibeKey"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Support/MenuBarIcon.png Support/MenuBarIcon@2x.png Support/DeviceArt.png Support/DeviceArtWorkBuddy.png "$APP/Contents/Resources/"
xattr -cr "$APP"
# 临时签名默认按二进制哈希认 App，每次重建辅助功能/输入监控权限都会失效。
# 改成按 Bundle ID 认，重建后权限还在。代价：本机同 ID 的临时签名程序也会被当成它。
codesign --force --sign - --requirements '=designated => identifier "local.vibe-key"' "$APP"
