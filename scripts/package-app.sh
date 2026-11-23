#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_CONFIG="${LEPAK_BUILD_CONFIG:-debug}"
swift build -c "$BUILD_CONFIG" --product menubar
BIN="$(swift build -c "$BUILD_CONFIG" --product menubar --show-bin-path)/menubar"
APP="dist/Lepak.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lepak"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${LEPAK_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LEPAK_VERSION" "$APP/Contents/Info.plist"
fi
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Support/DeviceArt.png Support/DeviceArtWorkBuddy.png "$APP/Contents/Resources/"
# Lepak 麦克风驱动跟着 App 走，设置里点「安装」时由 Lepak 复制到 /Library/Audio/Plug-Ins/HAL（见 MicDriver.swift）。
./scripts/build-mic-driver.sh >/dev/null
mkdir -p "$APP/Contents/PlugIns"
cp -R dist/LepakMic.driver "$APP/Contents/PlugIns/"
# 给 AI Passport 装固件用的 esptool（乐鑫官方独立版，自带乐鑫的签名，不重新签），见 PassportFirmware.swift。
ESPTOOL_DIR="$(./scripts/fetch-esptool.sh)"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp "$ESPTOOL_DIR/esptool" "$APP/Contents/Helpers/esptool"
cp "$ESPTOOL_DIR/LICENSE" "$APP/Contents/Resources/Licenses/esptool-LICENSE.txt"
# Lepak 自己的 AI Passport 固件（带蓝牙配对保护）：用提交在仓库里的发布版，跟着 Lepak 一起发布、升级。
# 设备页「固件」从这里安装。发新固件见 scripts/release-passport-firmware.sh。
if [[ ! -f Firmware/Passport/release/manifest.json ]]; then
    echo "没有 Firmware/Passport/release/：先跑 scripts/release-passport-firmware.sh" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Resources/Firmware"
cp Firmware/Passport/release/manifest.json Firmware/Passport/release/bootloader.bin \
   Firmware/Passport/release/partition-table.bin Firmware/Passport/release/app.bin \
   "$APP/Contents/Resources/Firmware/"
cp Firmware/Passport/LICENSE "$APP/Contents/Resources/Licenses/passport-firmware-LICENSE.txt"
xattr -cr "$APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

# 「用 Apple 登录」只能在用开发者证书签名、带登录权限和描述文件的 App 里用。设置下面两个环境变量就这样签：
#   LEPAK_SIGN_IDENTITY  钥匙串里的签名证书，例如 "Developer ID Application: 名字 (TEAMID)" 或 "Apple Development: …"
#   LEPAK_PROFILE        开发者网站下载的 .provisionprofile：App ID 开了 Sign in with Apple，Bundle ID 和 Info.plist 一致
# 不设置就和以前一样临时签名，Apple 登录会被系统拒绝（设置里会提示）。
if [[ -n "${LEPAK_SIGN_IDENTITY:-}" && -n "${LEPAK_PROFILE:-}" ]]; then
    PROFILE_PLIST="$(mktemp)"
    ENTITLEMENTS="$(mktemp)"
    trap 'rm -f "$PROFILE_PLIST" "$ENTITLEMENTS"' EXIT
    security cms -D -i "$LEPAK_PROFILE" > "$PROFILE_PLIST"
    TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
    APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
    if [[ "$APP_ID" != "$TEAM.$BUNDLE_ID" ]]; then
        echo "描述文件的 App ID（$APP_ID）和 Info.plist 的 Bundle ID（$BUNDLE_ID）对不上" >&2
        exit 1
    fi
    if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.applesignin' "$PROFILE_PLIST" >/dev/null 2>&1; then
        echo "描述文件里没有 Sign in with Apple：先在开发者网站给这个 App ID 打开它，再重新下载描述文件" >&2
        exit 1
    fi
    cat > "$ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key>
    <string>$APP_ID</string>
    <key>com.apple.developer.team-identifier</key>
    <string>$TEAM</string>
    <key>com.apple.developer.applesignin</key>
    <array>
        <string>Default</string>
    </array>
</dict>
</plist>
EOF
    cp "$LEPAK_PROFILE" "$APP/Contents/embedded.provisionprofile"
    # 里面的驱动先用同一个证书签好，外面的 App 签名才认它。
    codesign --force --options runtime --sign "$LEPAK_SIGN_IDENTITY" "$APP/Contents/PlugIns/LepakMic.driver"
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$LEPAK_SIGN_IDENTITY" "$APP"
else
    # 临时签名默认按二进制哈希认 App，每次重建辅助功能/输入监控权限都会失效。
    # 改成按 Bundle ID 认，重建后权限还在。代价：本机同 ID 的临时签名程序也会被当成它。
    codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
