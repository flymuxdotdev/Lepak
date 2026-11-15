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

/// 开了长按或双击的语音 / 确定 / 取消键：一轮按键（双击就是两下）的状态。按下时先不发，等判断出是哪种再发。
private struct GesturePress {
    let serial: Int
    let key: GestureKey
    /// 哪台设备上的键（报告、日志用）。
    let device: DeviceKind
    /// 按下第一下时的设置，这一轮都照它判断（中途改了设置也不会乱）。
    let single: KeyCombo
    let long: KeyCombo?
    let double: KeyCombo?
    /// 第几下（1 或 2）。
    var clicks = 1
    var isDown = true
    /// 这一轮已经发过长按或双击，后面的松开什么都不发。
    var done = false
}

private final class DeviceKeyState: @unchecked Sendable {
    let lock = NSLock()
    /// 没开长按 / 双击、设成只有修饰键的键：物理键 → 这次按下发出的组合和编号。松开时照这个松开
    /// （按住期间改了设置也不会松错键），编号用来作废旧的兜底松开任务。普通键按下就点一下，不记在这里。
    var held: [Int: (combo: KeyCombo, generation: Int)] = [:]
    var generation = 0
    /// 哪个物理键这次按下直接交给了 `FunctionKey`（设成只发 Fn、没开长按 / 双击），它松开时也要交给 `FunctionKey`。
    var functionKeyPhysical: Int?
    let queue = DispatchQueue(label: "local.lepak.keys")
    let source = CGEventSource(stateID: .hidSystemState)
    // 以下只在 queue 上读写：旋钮的按下、转动、松开都排在同一个串行队列里，保证先后顺序。
    var knobPress: KnobPress?
    var knobPressSerial = 0
    /// 开了长按 / 双击的键：物理键 → 正在进行的这一轮。
    var gestures: [Int: GesturePress] = [:]
    var gestureSerial = 0
    /// 普通转动：上一格的时间和这一轮的判断结果（true = 移动光标）。
    var lastKnobTick: DispatchTime?
    var knobMovesCaret = false
}

/// 语音键、确定、取消和旋钮。具体发什么键、旋钮怎么转都从 `Config.current` 读，设置里改了立即生效。
///
/// 本程序每秒发心跳时，AU05 认为有配套程序，就不再自己发键盘键，只通过配置口报告，
/// 所以要由本程序代发。默认值按官方 Ulanzi Studio 的默认预设：
/// - 语音键 → Fn，交给 `FunctionKey`（按下就按下 Fn、松开就松开，按住时长有上下限）。
/// - 确定 → Return，取消 → Esc。一按下就点一下（keyDown 紧跟 keyUp），不等 AU05 报松开：
///   它偶尔很晚才报，跟着按住会让系统里的 Esc 一直按着，挡住 Typeless 的 Fn。
///   只有设成纯修饰键（比如别的软件按住说话用的右 ⌥）时才跟着手按住、松开。
/// - 这三个键在设置里开了长按或双击，才改成判断手势（见 `gesturePress`），没开的键不受影响。
/// - 旋钮转动：在输入框里（有焦点且鼠标停在上面）移动光标；其他地方滚动，每格 3 行。
///   每一轮连续转动只在第一格判断一次（见 `TextFocus`），后面的格子沿用结果。
/// - 旋钮按下：按下时什么都不发，松开时才决定——
///   按住期间转过旋钮（切换过桌面）→ 不发；否则按时长发短按键（默认退格）或长按键（默认 Command+退格，删到行首）。
/// - 按住旋钮再转：切换桌面（Control + 左/右）。旋钮很灵敏，转一下就是几十格，
///   所以同方向连续 2 格才切一次（过滤按下时手抖带出的单格），切完等 0.4 秒再切下一次。
/// 按键处理实际做了什么，报告给设置界面（卡片闪一下、弹出「已发送」、记进最近操作）。
private final class ActionReporter: @unchecked Sendable {
    let lock = NSLock()
    var handler: (@Sendable (DeviceKind, MappingControl, String, KeyCombo?) -> Void)?
}

enum DeviceKeys {
    private static let reporter = ActionReporter()

    /// 设置执行动作后的回调。回调可能在任意线程被调用。
    static func setActionHandler(_ handler: @escaping @Sendable (DeviceKind, MappingControl, String, KeyCombo?) -> Void) {
        reporter.lock.lock()
        reporter.handler = handler
        reporter.lock.unlock()
    }

    static func report(_ control: MappingControl, _ title: String, _ combo: KeyCombo?, device: DeviceKind = .au05) {
        // 转动只在开了「输入框里移动光标」时才报告，所以转动次数在 knobTick 里单独记。
        if control != .knobTurn { Usage.shared.add(control, device: device.usageName) }
        reporter.lock.lock()
        let handler = reporter.handler
        reporter.lock.unlock()
        handler?(device, control, title, combo)
    }

    private enum Action {
        /// 语音 / 确定 / 取消：没开长按、双击时按下就发（纯修饰键跟着手按住）；开了就判断手势。
        case key(GestureKey)
        /// 旋钮按下（物理 3）。
        case knobPress
        /// 旋钮一格。arrow 是这个方向对应的方向键：光标移动和切换桌面都用它。
        case knob(lines: Int32, arrow: CGKeyCode, name: String)
    }

    private static func action(for physicalIndex: Int) -> Action? {
        let config = Config.current
        // 滚动方向用户已确认；光标方向实测要和滚动反过来：滚轮向上那一侧对应光标右移。
        let lines = Int32(config.scrollLines) * (config.reverseScroll ? -1 : 1)
        let (rightArrow, leftArrow): (CGKeyCode, CGKeyCode) = config.reverseCaret ? (123, 124) : (124, 123)
        if let key = GestureKey(physicalIndex: physicalIndex) { return .key(key) }
        switch physicalIndex {
        case 3: return .knobPress
        case 4: return .knob(lines: lines, arrow: rightArrow, name: "左转")    // 默认：光标右移 / 滚轮向上 / 切到右边的桌面
        case 5: return .knob(lines: -lines, arrow: leftArrow, name: "右转")   // 默认：光标左移 / 滚轮向下 / 切到左边的桌面
        default: return nil
        }
    }

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
        case let .key(key):
            return handleKey(key, slot: physicalIndex, device: .au05, status: status)
        }
    }

    /// AI Passport 的三个键：OK 当语音键、上当确定键、下当取消键，用它自己那一份设置。
    static func handle(passportKey key: GestureKey, pressed: Bool) -> String? {
        guard FunctionKey.isTrusted else { return "辅助功能未允许，未发出" }
        return handleKey(key, slot: passportSlot + key.physicalIndex, device: .passport, status: pressed ? 1 : 0)
    }

    /// 内部记录按键状态用的编号：AU05 用它上报的物理序号（0–5），AI Passport 从这里往后排，两台同时按也不会混。
    private static let passportSlot = 100

    /// 语音 / 确定 / 取消一类的键。slot 是这个键在 `state` 里的编号。
    private static func handleKey(_ key: GestureKey, slot: Int, device: DeviceKind, status: Int) -> String? {
        let name = key.name(on: device)
        switch status {
        case 1:
            let config = Config.current
            let single = config[keyPath: key.singlePath(device)]
            let long = config[keyPath: key.gesturePath(.long, device)]
            let double = config[keyPath: key.gesturePath(.double, device)]
            if long != nil || double != nil {
                let press = GesturePress(serial: 0, key: key, device: device, single: single, long: long, double: double)
                let seconds = config.longPressSeconds
                state.queue.async { gesturePress(slot, press, longSeconds: seconds) }
                return "\(name)按下（开了\(long != nil ? "长按" : "")\(long != nil && double != nil ? "、" : "")\(double != nil ? "双击" : "")，等判断）"
            }
            guard !single.isNone else { return "\(name)：设为不发送" }
            if single == .fnKey {
                // 只发 Fn（语音键默认）：直接交给 FunctionKey，按住时长有上下限。
                state.queue.async { flushPendingClicks(except: slot) }
                guard FunctionKey.handle(pressed: true) else { return "Fn 未发出" }
                state.lock.lock()
                state.functionKeyPhysical = slot
                state.lock.unlock()
                report(key.control, single.label ?? name, single, device: device)
                return "已按下 Fn"
            }
            if single.isModifierOnly {
                // 只有修饰键（比如别的软件「按住说话」用的右 ⌥）：跟着手按住，松开再松开。
                press(slot, single)
                report(key.control, single.label ?? name, single, device: device)
                return "已按下 \(name)（\(single.title)）"
            }
            // 普通键（回车、Esc、⌘↩ 等）：一按下就点一下（按下并马上松开），不跟着手按住。
            // AU05 偶尔很晚才报松开（实测有晚 25 秒的），跟着按住的话系统里 Esc 一直按着，
            // 这段时间 Typeless 按 Fn 都没反应。程序发出的按键本来也不会自动连发，按住没有用处。
            state.queue.async {
                flushPendingClicks(except: slot)
                tapCombo(single)
            }
            report(key.control, single.label ?? name, single, device: device)
            return "已发 \(name)（\(single.title)）"
        case 0:
            state.lock.lock()
            let usesFunctionKey = state.functionKeyPhysical == slot
            if usesFunctionKey {
                state.functionKeyPhysical = nil
            }
            state.lock.unlock()
            if usesFunctionKey {
                _ = FunctionKey.handle(pressed: false)
                return nil
            }
            if release(slot, generation: nil) { return "已松开 \(name)" }
            state.queue.async { gestureRelease(slot) }
            return nil
        default:
            return nil
        }
    }

    /// 配置口断开时调用，松开所有还按着的键，作废还没松开的旋钮按下。
    static func releaseAll() {
        state.lock.lock()
        let keys = Array(state.held.values)
        state.held.removeAll()
        state.generation &+= 1
        state.functionKeyPhysical = nil   // Fn 本身由调用方 FunctionKey.reset() 松开
        state.lock.unlock()
        state.queue.async {
            state.knobPress = nil
            state.gestures.removeAll()
            for key in keys {
                comboUp(key.combo)
            }
        }
    }

    // MARK: 没开长按 / 双击、设成纯修饰键的语音 / 确定 / 取消（跟着手按住）

    private static func press(_ physical: Int, _ combo: KeyCombo) {
        state.lock.lock()
        let previous = state.held[physical]
        state.generation &+= 1
        let generation = state.generation
        state.held[physical] = (combo, generation)
        state.lock.unlock()
        state.queue.async {
            flushPendingClicks(except: physical)
            if let previous {
                // 上一次的松开包丢了，先补一个松开。
                comboUp(previous.combo)
            }
            comboDown(combo)
        }
        state.queue.asyncAfter(deadline: .now() + maxHold) {
            _ = release(physical, generation: generation)
        }
    }

    /// generation 为 nil 时松开当前这次按下；否则只在还是那一次按下时才松开。返回是否真的松开了。
    private static func release(_ physical: Int, generation: Int?) -> Bool {
        state.lock.lock()
        let current = state.held[physical]
        let matches = current != nil && (generation == nil || current?.generation == generation)
        if matches {
            state.held[physical] = nil
        }
        state.lock.unlock()
        guard matches, let current else { return false }
        state.queue.async {
            comboUp(current.combo)
        }
        return true
    }

    // MARK: 长按 / 双击（只在 state.queue 上调用）
    //
    // 只开了长按：按下先不发；按住到时长发长按，没到就松手，松手时发单击。
    // 开了双击：松手后等 `doubleClickWindow`，没有第二下才发单击；第二下一按下就发双击。
    // 只开了双击时，按住超过 `clickMaxHold` 不松手也直接发单击。
    // 两个都开：先看长按，没到时长就松手的再看双击。
    // 单击、长按、双击都是「按一下就松开」地发出去（不再跟着手按住）。

    private static func gesturePress(_ physical: Int, _ initial: GesturePress, longSeconds: Double) {
        flushPendingClicks(except: physical)
        if var round = state.gestures[physical] {
            if !round.isDown, !round.done, round.clicks == 1, let double = round.double {
                // 等第二下的时候按下了：双击。
                round.clicks = 2
                round.isDown = true
                round.done = true
                state.gestures[physical] = round
                send(double, round, .double)
                return
            }
            // 上一轮的松开包丢了：作废上一轮，重新开始。
            DebugLog.write("\(round.key.name(on: round.device))：上一轮没收到松开，已作废")
        }
        state.gestureSerial &+= 1
        let serial = state.gestureSerial
        let round = GesturePress(serial: serial, key: initial.key, device: initial.device,
                                 single: initial.single, long: initial.long, double: initial.double)
        state.gestures[physical] = round
        if round.long != nil {
            state.queue.asyncAfter(deadline: .now() + longSeconds) {
                guard var round = state.gestures[physical], round.serial == serial,
                      round.isDown, round.clicks == 1, !round.done, let long = round.long
                else { return }
                round.done = true
                state.gestures[physical] = round
                send(long, round, .long)
            }
        } else if round.double != nil {
            // 只开了双击：按住不放就不是双击，不等松手，到 `clickMaxHold` 就发单击，松手时什么都不发。
            state.queue.asyncAfter(deadline: .now() + clickMaxHold) {
                guard var round = state.gestures[physical], round.serial == serial,
                      round.isDown, round.clicks == 1, !round.done
                else { return }
                round.done = true
                state.gestures[physical] = round
                send(round.single, round, nil)
            }
        }
        state.queue.asyncAfter(deadline: .now() + maxHold) {
            guard let round = state.gestures[physical], round.serial == serial, round.isDown else { return }
            state.gestures[physical] = nil
            DebugLog.write("\(round.key.name(on: round.device))按住超过 \(Int(maxHold)) 秒没收到松开，已作废")
        }
    }

    private static func gestureRelease(_ physical: Int) {
        guard var round = state.gestures[physical], round.isDown else { return }
        round.isDown = false
        if round.done {
            state.gestures[physical] = nil
            return
        }
        guard round.double != nil else {
            // 只开了长按，没到时长就松手：单击。
            state.gestures[physical] = nil
            send(round.single, round, nil)
            return
        }
        state.gestures[physical] = round
        let serial = round.serial
        state.queue.asyncAfter(deadline: .now() + doubleClickWindow) {
            guard let round = state.gestures[physical], round.serial == serial,
                  !round.isDown, !round.done, round.clicks == 1
            else { return }
            state.gestures[physical] = nil
            send(round.single, round, nil)
        }
    }

    /// 另一个键或旋钮动了：还在等第二下的键马上按单击发出去，免得发出去的顺序和按的顺序反了。
    private static func flushPendingClicks(except physical: Int?) {
        for (key, round) in state.gestures where key != physical && !round.isDown && !round.done {
            state.gestures[key] = nil
            send(round.single, round, nil)
        }
    }

    /// gesture 为 nil 表示单击。
    private static func send(_ combo: KeyCombo, _ round: GesturePress, _ gesture: KeyGesture?) {
        let kind = gesture?.title ?? "单击"
        let name = round.key.name(on: round.device)
        if combo.isNone {
            DebugLog.write("\(name)\(kind)：设为不发送")
            return
        }
        tapCombo(combo)
        let label = combo.label ?? (gesture == nil ? name : "自定义快捷键")
        report(round.key.control, gesture.map { "\($0.title) · \(label)" } ?? label, combo, device: round.device)
        DebugLog.write("\(name)\(kind)：已发 \(combo.title)")
    }

    // MARK: 旋钮按下（只在 state.queue 上调用）

    private static func beginKnobPress() {
        flushPendingClicks(except: nil)
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
        let config = Config.current
        let held = Double(DispatchTime.now().uptimeNanoseconds - press.pressedAt.uptimeNanoseconds) / 1e9
        let isLong = held >= config.longPressSeconds
        let combo = isLong ? config.knobLongPress : config.knobShortPress
        if !combo.isNone {
            tapCombo(combo)
            report(.knobPress, combo.label ?? (isLong ? "长按" : "短按"), combo)
        }
        DebugLog.write(String(format: "旋钮松开：%@ %.2f 秒，%@", isLong ? "长按" : "短按", held,
                              combo.isNone ? "设为不发送" : "已发 \(combo.title)"))
    }

    // MARK: 旋钮转动（只在 state.queue 上调用）

    private static func knobTick(lines: Int32, arrow: CGKeyCode) {
        flushPendingClicks(except: nil)
        let now = DispatchTime.now()
        let config = Config.current
        if config.switchSpacesWhilePressed, var press = state.knobPress {
            spaceTick(&press, arrow: arrow, now: now)
            state.knobPress = press
            return
        }
        let sameBurst = state.lastKnobTick.map { now.uptimeNanoseconds - $0.uptimeNanoseconds < knobBurstGap } ?? false
        if !sameBurst {
            Usage.shared.add(.knobTurn)   // 一轮连续转动记一次
            if config.caretInTextFields {
                let decision = TextFocus.decide()
                state.knobMovesCaret = decision.moveCaret
                DebugLog.write("旋钮：\(decision.moveCaret ? "移动光标" : "滚动")（\(decision.reason)）")
                report(.knobTurn, decision.moveCaret ? "移动光标" : "滚动", nil)
            } else {
                state.knobMovesCaret = false
            }
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
        report(.knobPressTurn, arrow == 124 ? "切到右边桌面" : "切到左边桌面", KeyCombo(keyCode: arrow, control: true))
        DebugLog.write("按住旋钮转动：切换到\(arrow == 124 ? "右" : "左")边的桌面")
    }

    // MARK: 发事件

    private static func tap(_ code: CGKeyCode, flags: CGEventFlags) {
        postKey(code, down: true, flags: flags)
        postKey(code, down: false, flags: flags)
    }

    /// 只有修饰键的组合（比如 Fn + 左 Shift）按住多久再松开。Typeless 这类软件隔一会儿才看一次
    /// 「现在按住了哪些修饰键」，按得太短它看不到；也不能太长（超过 0.6 秒 Typeless 会当成按住不放）。
    private static let modifierHold: TimeInterval = 0.15

    /// 点一下一个组合（长按 / 双击 / 单击判断出来之后、旋钮按下松开时用）。只在 state.queue 上调用。
    private static func tapCombo(_ combo: KeyCombo) {
        if combo == .fnKey {
            // 只按 Fn：和语音键一样交给 FunctionKey，按住 0.18 秒再松开，Typeless 才认得出来。
            FunctionKey.tap()
            return
        }
        comboDown(combo)
        if combo.isModifierOnly {
            state.queue.asyncAfter(deadline: .now() + modifierHold) { comboUp(combo) }
        } else {
            comboUp(combo)
        }
    }

    /// 按下一个组合。普通组合（没有 Fn、主键也不是修饰键）和以前一样：只发主键，带上修饰键标志。
    /// 有 Fn 或主键是修饰键的，照真键盘的样子一个个按下：Fn → ⌃ → ⌥ → ⇧ → ⌘ → 主键。
    private static func comboDown(_ combo: KeyCombo) {
        guard combo.needsKeySequence else {
            postKey(combo.keyCode, down: true, flags: combo.flags)
            return
        }
        var flags: CGEventFlags = []
        for key in modifierSequence(combo) {
            flags.formUnion(key.flags)
            postKey(key.code, down: true, flags: flags)
        }
        if ModifierKey.all[combo.keyCode] == nil {
            postKey(combo.keyCode, down: true, flags: flags)
        }
    }

    /// 松开一个组合：倒过来一个个松开，每松开一个，标志里就去掉它（Typeless 靠标志判断松开了没有）。
    private static func comboUp(_ combo: KeyCombo) {
        guard combo.needsKeySequence else {
            postKey(combo.keyCode, down: false, flags: combo.flags)
            return
        }
        var remaining = modifierSequence(combo)
        func held() -> CGEventFlags { remaining.reduce(CGEventFlags()) { $0.union($1.flags) } }
        if ModifierKey.all[combo.keyCode] == nil {
            postKey(combo.keyCode, down: false, flags: held())
        }
        while let key = remaining.popLast() {
            postKey(key.code, down: false, flags: held())
        }
    }

    /// 要一个个按下的修饰键和它们的标志，按按下的顺序：Fn、⌃、⌥、⇧、⌘（都按左边那个），最后是当主键的修饰键。
    private static func modifierSequence(_ combo: KeyCombo) -> [(code: CGKeyCode, flags: CGEventFlags)] {
        var codes: [UInt16] = []
        if combo.fn { codes.append(ModifierKey.fn) }
        if combo.control { codes.append(59) }
        if combo.option { codes.append(58) }
        if combo.shift { codes.append(56) }
        if combo.command { codes.append(55) }
        if ModifierKey.all[combo.keyCode] != nil, !codes.contains(combo.keyCode) { codes.append(combo.keyCode) }
        return codes.compactMap { code in ModifierKey.all[code].map { (CGKeyCode(code), $0) } }
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
