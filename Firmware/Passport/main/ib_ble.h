// main/ib_ble.h: BLE 链路:NimBLE GATT 外设,广播名 "AI Passport"。
//
// Lepak:必须配对。LE Secure Connections + 设备屏幕显示 6 位配对码(Mac 上输入),防中间人;配对记录存 NVS。
// - 链路用配对过的密钥加密之后,才收命令、发事件和声音;否则几秒后断开(不让别人的 Mac 占着设备)。
// - 没配对过任何 Mac 时,谁都可以发起配对;配对过以后,只有「配对窗口」开着时才接受新的 Mac
//   (设备上长按 ▼,或 USB 发 {"cmd":"pair","op":"open"}),配好一台就关。
#pragma once

#include "esp_err.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// 每收到完整一行命令调用一次,运行在 NimBLE host 任务中,必须快速返回。
typedef void (*ib_ble_line_cb_t)(const char *line, size_t len);
// Mac 订阅 / 取消订阅事件特征(含断开连接)时调用,运行在 NimBLE host 任务中。
typedef void (*ib_ble_link_cb_t)(bool subscribed);

// 配对码:要显示时 code 为 0..999999,配对结束(成功、失败、断开)时为 -1。运行在 NimBLE host 任务中,必须快速返回。
typedef void (*ib_ble_pair_cb_t)(int32_t code);

// 初始化 NimBLE,注册 GATT 服务并开始可连接广播。on_pair 可为 NULL。
esp_err_t ib_ble_start(ib_ble_line_cb_t on_line, ib_ble_link_cb_t on_link, ib_ble_pair_cb_t on_pair);

// 打开配对窗口 seconds 秒,这段时间里新的 Mac 可以配对;配好一台就关。任意任务可调用。
void ib_ble_open_pairing(uint32_t seconds);

// 删掉所有配对过的 Mac(并断开当前连接);之后谁先配对就是谁的。任意任务可调用。
void ib_ble_forget_all(void);

// 现在能不能配对新的 Mac(没配对过任何 Mac,或配对窗口开着)。任意任务可调用。
bool ib_ble_pairing_open(void);

// 有没有配对过的 Mac。任意任务可调用。
bool ib_ble_is_paired(void);

// 通过 Events 特征 Notify 一行 JSON,按 MTU 分片;未连接或未订阅时丢弃。任意任务可调用。
void ib_ble_send(const char *data, size_t len);

// 通过 Audio In 特征 Notify 一个二进制帧(含帧头,须不超过 MTU-3);未订阅时丢弃,不重试。任意任务可调用。
void ib_ble_send_audio(const uint8_t *frame, size_t len);

// 麦克风上行期间把从机延迟降到 0,结束后恢复省电参数。任意任务可调用。
void ib_ble_set_audio_mode(bool on);

// 切到 30 秒快速广播(USB 拔线后让 Mac 尽快发现设备);已连接时忽略。任意任务可调用。
void ib_ble_boost_advertising(void);

// 当前协商的 ATT MTU;未连接返回 0。
uint16_t ib_ble_mtu(void);
