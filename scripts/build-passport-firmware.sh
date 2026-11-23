#!/bin/bash
# 编译 Lepak 自己的 AI Passport 固件（Firmware/Passport，基于 FoloVibe Key，MIT）。
# 需要 ESP-IDF v5.5.3，装在 ~/Library/esp（工具也在里面，不碰 Homebrew）。没装的话：
#   mkdir -p ~/Library/esp && cd ~/Library/esp
#   git clone --depth 1 --branch v5.5.3 --recursive --shallow-submodules https://github.com/espressif/esp-idf.git esp-idf-v5.5.3
#   cd esp-idf-v5.5.3 && PATH=/usr/bin:$PATH IDF_TOOLS_PATH=~/Library/esp/.espressif ./install.sh esp32c3
#   PATH=/usr/bin:$PATH IDF_TOOLS_PATH=~/Library/esp/.espressif /usr/bin/python3 tools/idf_tools.py install cmake ninja
# 用系统自带的 Python 3.9（/usr/bin 放在 PATH 最前面）：Homebrew 的新版 Python ESP-IDF 还不支持。
# 产物在 Firmware/Passport/build/（VibeKey-Passport.bin 等），不烧录。
set -euo pipefail
cd "$(dirname "$0")/../Firmware/Passport"
export IDF_PATH="$HOME/Library/esp/esp-idf-v5.5.3"
export IDF_TOOLS_PATH="$HOME/Library/esp/.espressif"
export PATH="/usr/bin:$PATH"
if [[ ! -f "$IDF_PATH/export.sh" ]]; then
    echo "没找到 ESP-IDF：$IDF_PATH（安装方法见本脚本开头）" >&2
    exit 1
fi
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" >/dev/null
if [[ ! -f sdkconfig ]]; then
    idf.py set-target esp32c3
fi
idf.py build
