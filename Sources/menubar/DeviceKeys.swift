import ApplicationServices
import CoreGraphics
import Foundation

private final class DeviceKeyState: @unchecked Sendable {
    let lock = NSLock()
    /// 普通键：正按着的键 → 这次按下的编号，用来作废旧的兜底松开任务。
    var held: [CGKeyCode: Int] = [:]
    /// 短按/长按键：按下后还没松开、也还没触发长按的键 → 这次按下的编号。
    var pending: [CGKeyCode: Int] = [:]
    var generation = 0
    let queue = DispatchQueue(label: "local.vibe-key.keys")
    let source = CGEventSource(stateID: .hidSystemState)
}

/// 确定、取消和旋钮。
///
/// 本程序每秒发心跳时，AU05 认为有配套程序，就不再自己发键盘键，只通过配置口报告，
/// 所以要由本程序代发。基本按官方 Ulanzi Studio 的默认预设：
/// 确定 → Return，取消 → Esc，旋钮左转 → 滚轮向上，右转 → 滚轮向下，每格 3 行。
/// 旋钮按下：短按退格删一个字，按住 0.5 秒发 Command+退格，删到行首（光标在行尾时就是整行）。
enum DeviceKeys {
    private enum Action {
        /// 按下就按下，松开就松开。
        case key(CGKeyCode, name: String)
        /// 短按松开时发一次键；按住超过 `longPress` 发一次带修饰键的键。
        case tapOrHold(CGKeyCode, name: String, holdFlags: CGEventFlags, holdName: String)
        case scroll(Int32, name: String)
    }

    /// 物理 4 / 5 哪个是左转是按顺序推测的；方向反了就把这两行的数值对调。
    private static func action(for physicalIndex: Int) -> Action? {
        switch physicalIndex {
        case 1: return .key(36, name: "Return")
        case 2: return .key(53, name: "Esc")
        case 3: return .tapOrHold(51, name: "退格", holdFlags: .maskCommand, holdName: "Command+退格（整行删除）")
        case 4: return .scroll(3, name: "滚轮向上")
        case 5: return .scroll(-3, name: "滚轮向下")
        default: return nil
        }
    }

    private static let longPress: TimeInterval = 0.5
    /// 丢了松开包时的兜底：按住这么久还没收到松开就自动松开。
    private static let maxHold: TimeInterval = 8
    private static let state = DeviceKeyState()

    /// 返回写进日志的说明；不认识的键返回 nil。
    static func handle(physicalIndex: Int, status: Int) -> String? {
        guard let action = action(for: physicalIndex) else { return nil }
        guard FunctionKey.isTrusted else { return "辅助功能未允许，未发出" }
        switch action {
        case let .scroll(lines, name):
            guard status == 1 else { return nil }
            state.queue.async {
                postScroll(lines)
            }
            return "已发 \(name)"
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
        case let .tapOrHold(code, name, holdFlags, holdName):
            switch status {
            case 1:
                beginTapOrHold(code, holdFlags: holdFlags, holdName: holdName)
                return "按下（短按 \(name)，长按 \(holdName)）"
            case 0:
                return endTapOrHold(code) ? "短按，已发 \(name)" : "松开（长按已处理）"
            default:
                return nil
            }
        }
    }

    /// 配置口断开时调用，松开所有还按着的键，作废还没触发的长按。
    static func releaseAll() {
        state.lock.lock()
        let codes = Array(state.held.keys)
        state.held.removeAll()
        state.pending.removeAll()
        state.generation &+= 1
        state.lock.unlock()
        state.queue.async {
            for code in codes {
                postKey(code, down: false)
            }
        }
    }

    // MARK: 普通键

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

    // MARK: 短按 / 长按

    private static func beginTapOrHold(_ code: CGKeyCode, holdFlags: CGEventFlags, holdName: String) {
        state.lock.lock()
        state.generation &+= 1
        let generation = state.generation
        state.pending[code] = generation
        state.lock.unlock()
        state.queue.asyncAfter(deadline: .now() + longPress) {
            state.lock.lock()
            let fire = state.pending[code] == generation
            if fire {
                state.pending[code] = nil
            }
            state.lock.unlock()
            guard fire else { return }
            tap(code, flags: holdFlags)
            DebugLog.write("长按：已发 \(holdName)")
        }
    }

    /// 返回 true 表示是短按，发出了一次键；false 表示长按已经处理过了。
    private static func endTapOrHold(_ code: CGKeyCode) -> Bool {
        state.lock.lock()
        let shortPress = state.pending[code] != nil
        state.pending[code] = nil
        state.lock.unlock()
        if shortPress {
            state.queue.async {
                tap(code, flags: [])
            }
        }
        return shortPress
    }

    private static func tap(_ code: CGKeyCode, flags: CGEventFlags) {
        postKey(code, down: true, flags: flags)
        postKey(code, down: false, flags: flags)
    }

    // MARK: 发事件

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
