cmake_minimum_required(VERSION 3.16)

# hello 消息里的 "ver" 取自应用描述;固定版本号,不随 git describe 变化。
# Lepak 自己的固件版本(基于 FoloVibe Key 0.1.21)。改了要跑 scripts/release-passport-firmware.sh 并随 Lepak 发布。
set(PROJECT_VER "1.0.0")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(VibeKey-Passport)
