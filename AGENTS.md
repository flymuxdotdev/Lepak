# AGENTS.md

本项目 Lepak 是 Ulanzi AU05 键盘麦（官方叫 Vibe Key）的 macOS 菜单栏程序：读取 AU05 配置口上报的按键，把语音键转成 Fn（交给 Typeless 等语音输入），并代发确定、取消、旋钮等按键。

## 硬性规定：键盘监听只能用于调试

**键盘监听永远只用于调试。** 发给客户的程序，以及自己日常使用的程序，都不能带键盘监听。只在排查问题时临时打开，问题查清后关掉；调试稳定之后，要从最终打包的二进制里彻底删掉键盘监听相关代码。

### 什么算「键盘监听」

以下任何一种都算，都受本规定约束：

- 监听键盘事件的 CGEventTap（`keyDown` / `keyUp` / `flagsChanged`），不管是只听（`listenOnly`）还是能拦截的。
- 用 IOHIDManager 打开任何键盘、鼠标或消费类（媒体键）接口，包括 AU05 自己的键盘口。
- `NSEvent.addGlobalMonitorForEvents` / `addLocalMonitorForEvents` 监听按键。
- 申请或检查「输入监控」权限：`CGRequestListenEventAccess`、`CGPreflightListenEventAccess`。
- 把用户的按键内容写进日志或文件。

以下**不算**键盘监听，正式版可以用：

- 读写 AU05 配置口（Usage Page `0xFFFC`）：`DeviceSession`、`probe` 都只匹配这个接口。语音键、确定、取消、旋钮都从这里上报。
- 用 `CGEvent.post` 发出按键或滚轮事件（Fn、Return、Esc、退格、滚轮）。这是「发」，不是「听」，只需要「辅助功能」权限。
- **设置窗口里的快捷键录制框**（`Sources/menubar/ShortcutRecorder.swift`，用户 2026-11-12 确认）：只在用户点了录制框、并且它是本窗口的焦点时，通过本窗口自己的按键事件（响应链里的 `keyDown` / `performKeyEquivalent` / `flagsChanged`）读取一次组合键，录完立刻停止并交出焦点。不用 CGEventTap、NSEvent 监听或 IOHID，不申请「输入监控」，不写日志。

- **首页「洞察」的使用次数**（`Sources/menubar/Usage.swift`，用户 2026-11-12 确认「只记次数」）：只统计设备配置口上报的按键（语音键、确定、取消、旋钮）每天按了几次，按设备分开，存在本机 `~/Library/Application Support/Lepak/usage.json`。不记文字、不记电脑键盘、不记具体时间点，也不估算口述时长或字数。

用户定的界线：**不能监听整个系统的输入，也不能申请「输入监控」这类键盘监听权限**（用户对它很敏感）；在特定时机、只在本程序自己的窗口里读取按键是可以的。

### 规则

1. **正式版不包含键盘监听代码。** 发给客户或自己日常用的包里，不能编译进上面列出的任何监听代码，也不能申请「输入监控」权限。只是运行时关掉不够，代码不能在二进制里。
2. **功能不能依赖键盘监听。** 产品功能只能依赖 AU05 配置口和发事件。如果某个功能看起来必须监听键盘才能做，先停下来和用户确认，不要自己加。
3. **调试开关用专门的编译条件，不要用 `DEBUG`。** `scripts/package-app.sh` 目前用默认的 debug 配置打包，所以 `#if DEBUG` 挡不住正式包。调试代码用单独的编译条件包起来（例如 `#if LEPAK_KEY_DEBUG`），只在调试时通过 `swift build -Xswiftc -DLEPAK_KEY_DEBUG` 打开，打包脚本永远不传这个条件。
4. **用完就关。** 排查结束后，确认打包产物里没有监听代码，再交给用户日常使用；含按键内容的调试日志（`~/Library/Logs/Lepak.log`）用完删掉，不要提交、不要外传。
5. **稳定后删除。** 相关问题都调试稳定后，把 `KeyEcho`、`KeyboardMonitor` 以及 `main.swift` 里的接线和输入监控权限请求从代码中删掉。以后需要再排查，再临时加回来，照本规定走。
6. **打包前自查。** 打包后检查二进制里没有键盘监听：
   ```bash
   BIN="dist/Lepak.app/Contents/MacOS/Lepak"
   nm -u "$BIN" | grep -E 'CGEventTapCreate|CGRequestListenEventAccess|CGPreflightListenEventAccess'
   nm "$BIN" | grep -E 'KeyboardMonitor|KeyEcho'
   ```
   正式包这两条命令都应该没有任何输出。第二条是因为 `KeyboardMonitor` 和配置口用的是同一套 IOHIDManager 接口，第一条查不出来。

### 现状（2026-11-11）

排查「长按语音键冒出 Command+H」时加了调试用的键盘监听，**目前还是默认开启的，不符合本规定**，正式使用前必须先按第 3 条改成调试编译条件，或按第 5 条删掉：

- `Sources/menubar/KeyEcho.swift`：全系统按键监听（CGEventTap），日志里记录每个按键的来源进程。
- `Sources/LepakKit/KeyboardMonitor.swift`：监听 AU05 自己的键盘 / 鼠标 / 消费类接口。
- `Sources/menubar/main.swift`：启动上面两者，并申请「输入监控」权限。

当时的结论（不需要键盘监听也能成立）：AU05 超过约 3 秒收不到心跳，会认为没有配套程序，按语音键时改从自己的键盘口发 Win+H（Mac 上是 Command+H）。所以心跳必须保持每 1 秒一次，跟官方 Ulanzi Studio 一致。
