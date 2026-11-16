#!/bin/bash
# 安装（或更新）虚拟麦克风驱动：复制到 /Library/Audio/Plug-Ins/HAL，重启系统音频服务。
# 要管理员密码；重启音频服务时声音会断一两秒。卸载：scripts/install-mic-driver.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="/Library/Audio/Plug-Ins/HAL/LepakMic.driver"

if [[ "${1:-}" == "--uninstall" ]]; then
    sudo rm -rf "$TARGET"
    sudo killall coreaudiod
    echo "已卸载 Lepak 麦克风"
    exit 0
fi

./scripts/test-mic-driver.sh
sudo rm -rf "$TARGET"
sudo cp -R dist/LepakMic.driver "$TARGET"
sudo chown -R root:wheel "$TARGET"
# coreaudiod 被结束后系统会自动重新启动它，并加载新驱动。
sudo killall coreaudiod
sleep 3
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Lepak 麦克风"; then
    echo "已安装：系统里能看到「Lepak 麦克风」了"
else
    echo "已复制，但系统里还没看到「Lepak 麦克风」，等几秒再看，或者重启电脑" >&2
fi
