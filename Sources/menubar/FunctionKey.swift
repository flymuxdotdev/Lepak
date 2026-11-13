import ApplicationServices
import CoreGraphics
import Foundation

private final class FunctionKeyState: @unchecked Sendable {
    let lock = NSLock()
    var isDown = false
    var downAt = DispatchTime.now()
    /// 每次按下或重置都加一，用来作废已经排好的旧松开任务。
    var generation = 0
    let poster = DispatchQueue(label: "local.lepak.fn")
    let source: CGEventSource?

    init() {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        if let source {
            source.setLocalEventsFilterDuringSuppressionState(
                CGEventFilterMask(rawValue: 0x0000_0007),
                state: .eventSuppressionStateSuppressionInterval
            )
        }
        self.source = source
    }
}

/// 语音键 → Fn。
///
/// 跟官方 Ulanzi Studio 一样：语音键按下时按下 Fn，松开时松开 Fn。
/// 另外限定 Fn 的按住时长，让 Typeless 稳定地认成「点一下」：
/// - Typeless 是异步读取「当前按住了哪些键」的，按得太短，按下状态可能还没被它看到就没了，
///   所以至少按住 `minHold`。
/// - Typeless 把超过 600 毫秒的按住当成长按，会提示「不要按住」并丢掉这次录音。
///   它刚开始录音时自己会卡一下，松开事件可能晚到几百毫秒，所以最多按住 `maxHold`
///   就自动松开，留足余量。这也保证丢了松开包时不会卡住。
/// 实测：按住 120～260 毫秒都能触发；按住 450 毫秒时三次里失败了两次。
enum FunctionKey {
    static let marker: Int64 = 0x5646_4B31
    static let virtualKey: CGKeyCode = 63
    private static let minHold: TimeInterval = 0.12
    private static let maxHold: TimeInterval = 0.25
    private static let state = FunctionKeyState()

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func reset() {
        state.lock.lock()
        state.isDown = false
        state.generation &+= 1
        state.lock.unlock()
        state.poster.sync {
            _ = post(keyDown: false)
        }
    }

    /// 返回 true 表示这次按下或松开会发出 Fn。
    static func handle(pressed: Bool) -> Bool {
        guard isTrusted else { return false }
        state.lock.lock()
        defer { state.lock.unlock() }
        if pressed {
            guard !state.isDown else { return false }
            state.isDown = true
            state.downAt = .now()
            state.generation &+= 1
            let generation = state.generation
            state.poster.async {
                _ = post(keyDown: true)
            }
            state.poster.asyncAfter(deadline: state.downAt + maxHold) {
                release(generation)
            }
            return true
        }
        guard state.isDown else { return false }
        let generation = state.generation
        let releaseAt = max(state.downAt + minHold, DispatchTime.now())
        state.poster.asyncAfter(deadline: releaseAt) {
            release(generation)
        }
        return true
    }

    /// 点一下 Fn：按下，按住 `minHold` 再松开。语音键开了长按 / 双击、或者别的键设成 Fn 时用。
    static func tap() {
        guard handle(pressed: true) else { return }
        _ = handle(pressed: false)
    }

    private static func release(_ generation: Int) {
        state.lock.lock()
        let current = state.isDown && state.generation == generation
        if current {
            state.isDown = false
        }
        state.lock.unlock()
        if current {
            _ = post(keyDown: false)
        }
    }

    private static func post(keyDown: Bool) -> Bool {
        guard isTrusted, let source = state.source else { return false }
        source.localEventsSuppressionInterval = 0
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else {
            return false
        }
        // 松开时必须去掉 Fn 标志，Typeless 靠这个标志判断 Fn 是按下还是松开。
        event.flags = keyDown ? [.maskSecondaryFn, .maskNonCoalesced] : [.maskNonCoalesced]
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
        DebugLog.write("注入 Fn \(keyDown ? "按下" : "松开")")
        return true
    }
}
