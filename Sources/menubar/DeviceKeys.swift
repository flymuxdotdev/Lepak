import ApplicationServices
import CoreGraphics
import Foundation

/// 一次旋钮按下（物理 3）的状态。按下到松开之间只记录，松开时才决定做什么。
private struct KnobPress {
    let serial: Int
    let pressedAt: DispatchTime
    /// 按住期间切换过桌面：松开时就什么都不删。
    var switchedSpace = false
    /// 正在累计的转动方向（方向键键码）、格数和上一格的时间。
    var tickArrow: CGKeyCode?
    var tickCount = 0
    var lastTick: DispatchTime?
    /// 切换一次桌面后，这个时间之前的格子都忽略，等切换动画走完。
    var cooldownUntil: DispatchTime?
}

private final class DeviceKeyState: @unchecked Sendable {
    let lock = NSLock()
    /// Return / Esc：正按着的键 → 这次按下的编号，用来作废旧的兜底松开任务。
    var held: [CGKeyCode: Int] = [:]
    var generation = 0
    let queue = DispatchQueue(label: "local.vibe-key.keys")
    let source = CGEventSource(stateID: .hidSystemState)
    // 以下只在 queue 上读写：旋钮的按下、转动、松开都排在同一个串行队列里，保证先后顺序。
    var knobPress: KnobPress?
    var knobPressSerial = 0
    /// 普通转动：上一格的时间和这一轮的判断结果（true = 移动光标）。
    var lastKnobTick: DispatchTime?
    var knobMovesCaret = false
}

/// 确定、取消和旋钮。
///
/// 本程序每秒发心跳时，AU05 认为有配套程序，就不再自己发键盘键，只通过配置口报告，
/// 所以要由本程序代发。基本按官方 Ulanzi Studio 的默认预设：
/// - 确定 → Return，取消 → Esc。
/// - 旋钮转动：在输入框里（有焦点且鼠标停在上面）移动光标；其他地方滚动，每格 3 行。
///   每一轮连续转动只在第一格判断一次（见 `TextFocus`），后面的格子沿用结果。
/// - 旋钮按下：按下时什么都不发，松开时才决定——
///   按住期间转过旋钮（切换过桌面）→ 不删字；否则不到 0.5 秒 → 退格；0.5 秒以上 → Command+退格（删到行首）。
/// - 按住旋钮再转：切换桌面（Control + 左/右）。旋钮很灵敏，转一下就是几十格，
///   所以同方向连续 2 格才切一次（过滤按下时手抖带出的单格），切完等 0.4 秒再切下一次。
enum DeviceKeys {
    private enum Action {
        /// 按下就按下，松开就松开。
        case key(CGKeyCode, name: String)
        /// 旋钮按下（物理 3）。
        case knobPress
        /// 旋钮一格。arrow 是这个方向对应的方向键：光标移动和切换桌面都用它。
        case knob(lines: Int32, arrow: CGKeyCode, name: String)
    }

    private static func action(for physicalIndex: Int) -> Action? {
        switch physicalIndex {
        case 1: return .key(36, name: "Return")
        case 2: return .key(53, name: "Esc")
        case 3: return .knobPress
        // 滚动方向用户已确认；光标方向实测要和滚动反过来：滚轮向上那一侧对应光标右移。
        case 4: return .knob(lines: 3, arrow: 124, name: "左转")    // 光标右移 / 滚轮向上 / 切到右边的桌面
        case 5: return .knob(lines: -3, arrow: 123, name: "右转")   // 光标左移 / 滚轮向下 / 切到左边的桌面
        default: return nil
        }
    }

    private static let backspace: CGKeyCode = 51
    private static let longPress: TimeInterval = 0.5
    /// 丢了松开包时的兜底：按住这么久还没收到松开就作废。
    private static let maxHold: TimeInterval = 8
    /// 切桌面：同方向连续几格才算、两格之间最长间隔、切完后的冷却时间。
    private static let spaceTicks = 2
    private static let spaceTickGap: UInt64 = 300_000_000
    private static let spaceCooldown: TimeInterval = 0.4
    /// 普通转动：两格之间超过这个间隔，就算新一轮转动，重新判断光标还是滚动。
    private static let knobBurstGap: UInt64 = 350_000_000
    private static let state = DeviceKeyState()

    /// 返回写进日志的说明；不认识的键返回 nil。
    static func handle(physicalIndex: Int, status: Int) -> String? {
        guard let action = action(for: physicalIndex) else { return nil }
        guard FunctionKey.isTrusted else { return "辅助功能未允许，未发出" }
        switch action {
        case let .knob(lines, arrow, name):
            guard status == 1 else { return nil }
            state.queue.async {
                knobTick(lines: lines, arrow: arrow)
            }
            return "旋钮\(name)"
        case .knobPress:
            switch status {
            case 1:
                state.queue.async { beginKnobPress() }
                return "旋钮按下（松开时决定）"
            case 0:
                state.queue.async { endKnobPress() }
                return "旋钮松开"
            default:
                return nil
            }
        case let .key(code, name):
            switch status {
            case 1:
                press(code)
                return "已按下 \(name)"
            case 0:
                release(code, generation: nil)
                return "已松开 \(name)"
            default:
                return nil
            }
        }
    }

    /// 配置口断开时调用，松开所有还按着的键，作废还没松开的旋钮按下。
    static func releaseAll() {
        state.lock.lock()
        let codes = Array(state.held.keys)
        state.held.removeAll()
        state.generation &+= 1
        state.lock.unlock()
        state.queue.async {
            state.knobPress = nil
            for code in codes {
                postKey(code, down: false)
            }
        }
    }

    // MARK: Return / Esc

    private static func press(_ code: CGKeyCode) {
        state.lock.lock()
        let wasHeld = state.held[code] != nil
        state.generation &+= 1
        let generation = state.generation
        state.held[code] = generation
        state.lock.unlock()
        state.queue.async {
            if wasHeld {
                // 上一次的松开包丢了，先补一个松开。
                postKey(code, down: false)
            }
            postKey(code, down: true)
        }
        state.queue.asyncAfter(deadline: .now() + maxHold) {
            release(code, generation: generation)
        }
    }

    /// generation 为 nil 时松开当前这次按下；否则只在还是那一次按下时才松开。
    private static func release(_ code: CGKeyCode, generation: Int?) {
        state.lock.lock()
        let current = state.held[code]
        let matches = current != nil && (generation == nil || current == generation)
        if matches {
            state.held[code] = nil
        }
        state.lock.unlock()
        guard matches else { return }
        state.queue.async {
            postKey(code, down: false)
        }
    }

    // MARK: 旋钮按下（只在 state.queue 上调用）

    private static func beginKnobPress() {
        state.knobPressSerial &+= 1
        let serial = state.knobPressSerial
        state.knobPress = KnobPress(serial: serial, pressedAt: .now())
        state.queue.asyncAfter(deadline: .now() + maxHold) {
            guard state.knobPress?.serial == serial else { return }
            state.knobPress = nil
            DebugLog.write("旋钮按下超过 \(Int(maxHold)) 秒没收到松开，已作废")
        }
    }

    private static func endKnobPress() {
        guard let press = state.knobPress else {
            DebugLog.write("旋钮松开：这次按下已作废，不做任何事")
            return
        }
        state.knobPress = nil
        if press.switchedSpace {
            DebugLog.write("旋钮松开：按住时切换过桌面，不删字")
            return
        }
        let held = Double(DispatchTime.now().uptimeNanoseconds - press.pressedAt.uptimeNanoseconds) / 1e9
        if held < longPress {
            tap(backspace, flags: [])
            DebugLog.write(String(format: "旋钮松开：短按 %.2f 秒，已发退格", held))
        } else {
            tap(backspace, flags: .maskCommand)
            DebugLog.write(String(format: "旋钮松开：长按 %.2f 秒，已发 Command+退格（删到行首）", held))
        }
    }

    // MARK: 旋钮转动（只在 state.queue 上调用）

    private static func knobTick(lines: Int32, arrow: CGKeyCode) {
        let now = DispatchTime.now()
        if var press = state.knobPress {
            spaceTick(&press, arrow: arrow, now: now)
            state.knobPress = press
            return
        }
        let sameBurst = state.lastKnobTick.map { now.uptimeNanoseconds - $0.uptimeNanoseconds < knobBurstGap } ?? false
        if !sameBurst {
            let decision = TextFocus.decide()
            state.knobMovesCaret = decision.moveCaret
            DebugLog.write("旋钮：\(decision.moveCaret ? "移动光标" : "滚动")（\(decision.reason)）")
        }
        state.lastKnobTick = now
        if state.knobMovesCaret {
            tap(arrow, flags: [])
        } else {
            postScroll(lines)
        }
    }

    /// 按住旋钮时的一格：同方向连续 `spaceTicks` 格切一次桌面，切完冷却 `spaceCooldown`。
    private static func spaceTick(_ press: inout KnobPress, arrow: CGKeyCode, now: DispatchTime) {
        let continues = press.tickArrow == arrow
            && (press.lastTick.map { now.uptimeNanoseconds - $0.uptimeNanoseconds < spaceTickGap } ?? false)
        if !continues {
            press.tickArrow = arrow
            press.tickCount = 0
        }
        press.lastTick = now
        if let until = press.cooldownUntil, now < until {
            press.tickCount = 0
            return
        }
        press.tickCount += 1
        guard press.tickCount >= spaceTicks else { return }
        press.tickCount = 0
        press.switchedSpace = true
        press.cooldownUntil = now + spaceCooldown
        // 系统「向左/向右移动一个空间」快捷键是 Control + 方向键；方向键在 Mac 上自带 Fn 标志，
        // 系统记录的快捷键也带着它，不加的话可能对不上。
        tap(arrow, flags: [.maskControl, .maskSecondaryFn])
        DebugLog.write("按住旋钮转动：切换到\(arrow == 124 ? "右" : "左")边的桌面")
    }

    // MARK: 发事件

    private static func tap(_ code: CGKeyCode, flags: CGEventFlags) {
        postKey(code, down: true, flags: flags)
        postKey(code, down: false, flags: flags)
    }

    /// 修饰键必须显式给出。新事件默认继承系统记录的修饰键状态，Typeless 用 Command+V
    /// 粘贴后这个状态可能残留 Command，退格就会意外变成 Command+退格。
    private static func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: state.source, virtualKey: code, keyDown: down) else {
            return
        }
        event.flags = flags.union(.maskNonCoalesced)
        event.setIntegerValueField(.eventSourceUserData, value: FunctionKey.marker)
        event.post(tap: .cghidEventTap)
    }

    private static func postScroll(_ lines: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: state.source,
            units: .line,
            wheelCount: 1,
            wheel1: lines,
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }
        // 同上，免得残留的 Command 让滚动变成缩放。
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: FunctionKey.marker)
        event.post(tap: .cghidEventTap)
    }
}
