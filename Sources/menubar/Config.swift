import CoreGraphics
import Foundation

/// 一个按键组合：键码 + 修饰键。`none` 表示不发送任何键。
///
/// 主键也可以是修饰键本身（Fn、左 / 右 Shift 等），比如「Fn + 左 Shift」就是 fn = true、主键 = 左 Shift。
/// 这种组合发出去时真的一个个按下、按住一会儿再松开（见 `DeviceKeys.tapCombo`），
/// 因为 Typeless 这类软件是看「现在按住了哪些修饰键」来判断的。
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var command = false
    var shift = false
    var option = false
    var control = false
    /// Fn（地球仪键）。
    var fn = false

    static let none = KeyCombo(keyCode: 0xFFFF)
    /// 只按 Fn：语音键的默认值，Typeless 等语音输入用它开始和结束说话。
    static let fnKey = KeyCombo(keyCode: 63)

    var isNone: Bool { keyCode == KeyCombo.none.keyCode }

    /// 主键本身是修饰键（包括 Fn）：整个组合只有修饰键。
    var isModifierOnly: Bool { ModifierKey.all[keyCode] != nil }

    /// 发出去时要不要把修饰键一个个按下（有 Fn，或者主键是修饰键）。普通组合只发主键并带上修饰键标志。
    var needsKeySequence: Bool { fn || isModifierOnly }

    var flags: CGEventFlags {
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if option { flags.insert(.maskAlternate) }
        if control { flags.insert(.maskControl) }
        if fn { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// 例如「⌘⌫ 删到行首」。常用组合带中文说明，其他只显示符号。
    var title: String {
        if isNone { return "不发送" }
        let symbols = parts.joined(separator: parts.contains { $0.count > 1 } ? " " : "")
        if let label = KeyPresets.labels[self] {
            return "\(symbols)  \(label)"
        }
        return symbols
    }

    static func keyName(_ code: UInt16) -> String {
        KeyCatalog.names[code] ?? "键\(code)"
    }

    /// 拆成一个个键帽：修饰键各一个（Fn 在最前），再加主键。不发送时为空。
    var parts: [String] {
        guard !isNone else { return [] }
        return [fn && keyCode != 63 ? "Fn" : nil, control ? "⌃" : nil, option ? "⌥" : nil,
                shift ? "⇧" : nil, command ? "⌘" : nil]
            .compactMap { $0 } + [KeyCombo.keyName(keyCode)]
    }

    /// 常用组合的中文说明，比如「删到行首」；不是常用组合时为 nil。
    var label: String? { KeyPresets.labels[self] }
}

extension KeyCombo {
    // 写在扩展里，保留自动生成的逐成员初始化方法。旧配置里没有 fn 这个字段，读进来当作 false。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        command = try c.decodeIfPresent(Bool.self, forKey: .command) ?? false
        shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        option = try c.decodeIfPresent(Bool.self, forKey: .option) ?? false
        control = try c.decodeIfPresent(Bool.self, forKey: .control) ?? false
        fn = try c.decodeIfPresent(Bool.self, forKey: .fn) ?? false
    }
}

/// 能当主键的修饰键：键码 → 它按下时的标志（含区分左右的设备位，Typeless 能分出「左 Shift」）。
enum ModifierKey {
    static let fn: UInt16 = 63

    static let all: [UInt16: CGEventFlags] = [
        63: .maskSecondaryFn,
        56: [.maskShift, CGEventFlags(rawValue: 0x02)],         // 左 Shift
        60: [.maskShift, CGEventFlags(rawValue: 0x04)],         // 右 Shift
        59: [.maskControl, CGEventFlags(rawValue: 0x01)],       // 左 Control
        62: [.maskControl, CGEventFlags(rawValue: 0x2000)],     // 右 Control
        58: [.maskAlternate, CGEventFlags(rawValue: 0x20)],     // 左 Option
        61: [.maskAlternate, CGEventFlags(rawValue: 0x40)],     // 右 Option
        55: [.maskCommand, CGEventFlags(rawValue: 0x08)],       // 左 Command
        54: [.maskCommand, CGEventFlags(rawValue: 0x10)],       // 右 Command
    ]
}

/// 设置里能选的所有按键（Mac 虚拟键码，按美式键盘位置）。
enum KeyCatalog {
    struct Group: Identifiable {
        let title: String
        let keys: [(code: UInt16, name: String)]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "常用", keys: [
            (36, "↩"), (53, "Esc"), (51, "⌫"), (117, "⌦"), (48, "Tab"), (49, "空格"),
        ]),
        Group(title: "方向与翻页", keys: [
            (123, "←"), (124, "→"), (126, "↑"), (125, "↓"),
            (115, "Home"), (119, "End"), (116, "Page Up"), (121, "Page Down"),
        ]),
        Group(title: "字母", keys: [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
            (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"),
            (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        ]),
        Group(title: "数字", keys: [
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        ]),
        Group(title: "功能键", keys: [
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
            (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
        ]),
        Group(title: "符号", keys: [
            (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"), (41, ";"),
            (39, "'"), (43, ","), (47, "."), (44, "/"), (50, "`"),
        ]),
        // 只按修饰键也能当一个组合，比如 Fn、Fn + 左 Shift（语音输入软件常用）。
        Group(title: "修饰键", keys: [
            (63, "Fn"), (56, "左⇧"), (60, "右⇧"), (59, "左⌃"), (62, "右⌃"),
            (58, "左⌥"), (61, "右⌥"), (55, "左⌘"), (54, "右⌘"),
        ]),
    ]

    static let names: [UInt16: String] = Dictionary(
        groups.flatMap { $0.keys }.map { ($0.code, $0.name) },
        uniquingKeysWith: { first, _ in first }
    )
}

/// 设置里可选的常用组合。第一版先从列表里选，以后再加「录制组合键」。
enum KeyPresets {
    static let options: [(KeyCombo, String)] = [
        (KeyCombo.fnKey, "语音输入"),
        (KeyCombo(keyCode: 36), "回车"),
        (KeyCombo(keyCode: 36, shift: true), "换行"),
        (KeyCombo(keyCode: 36, command: true), "发送"),
        (KeyCombo(keyCode: 53), "Esc"),
        (KeyCombo(keyCode: 51), "退格"),
        (KeyCombo(keyCode: 51, option: true), "删除单词"),
        (KeyCombo(keyCode: 51, command: true), "删到行首"),
        (KeyCombo(keyCode: 117), "向后删除"),
        (KeyCombo(keyCode: 48), "Tab"),
        (KeyCombo(keyCode: 49), "空格"),
        (KeyCombo(keyCode: 6, command: true), "撤销"),
        (KeyCombo(keyCode: 6, command: true, shift: true), "重做"),
        (KeyCombo(keyCode: 0, command: true), "全选"),
        (KeyCombo(keyCode: 8, command: true), "复制"),
        (KeyCombo(keyCode: 9, command: true), "粘贴"),
        (KeyCombo(keyCode: 7, command: true), "剪切"),
    ]

    static let labels: [KeyCombo: String] = Dictionary(uniqueKeysWithValues: options)

    /// 列表里的选项；当前值不在列表里时也放进去，免得选择器显示空白。
    static func choices(including current: KeyCombo) -> [KeyCombo] {
        var list = options.map(\.0) + [KeyCombo.none]
        if !list.contains(current) { list.insert(current, at: 0) }
        return list
    }
}

/// 设置里显示哪个版本的 AU05 外观。两个版本按键布局一样，只是样子不同。
enum DeviceTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, workBuddy

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "标准版"
        case .workBuddy: return "WorkBuddy 版"
        }
    }
}

/// 语音 / 确定 / 取消键上可以另外开启的动作。默认都不开：不开时按键和以前完全一样（按下立刻发、松开立刻松）。
enum KeyGesture: String, CaseIterable, Identifiable, Sendable {
    case long, double

    var id: String { rawValue }
    var title: String {
        switch self {
        case .long: return "长按"
        case .double: return "双击"
        }
    }
}

/// 开了双击时，松手后等这么久没有第二下，才算单击。
let doubleClickWindow: TimeInterval = 0.25

/// 可以在设置里调整的所有选项。默认值就是改设置界面之前写死的行为。
struct AppConfig: Codable, Equatable, Sendable {
    var deviceTheme = DeviceTheme.standard
    /// 语音键单击。默认 Fn：没开长按 / 双击时和以前一样，按下就按下 Fn、松开就松开（见 `FunctionKey`）。
    var voice = KeyCombo.fnKey
    /// 语音键的长按、双击。nil = 没开启（默认）。
    var voiceLong: KeyCombo?
    var voiceDouble: KeyCombo?
    var confirm = KeyCombo(keyCode: 36)
    var cancel = KeyCombo(keyCode: 53)
    /// 确定 / 取消键的长按、双击。nil = 没开启（默认）。旧配置里没有这些字段，读进来就是没开启。
    var confirmLong: KeyCombo?
    var confirmDouble: KeyCombo?
    var cancelLong: KeyCombo?
    var cancelDouble: KeyCombo?
    var knobShortPress = KeyCombo(keyCode: 51)
    var knobLongPress = KeyCombo(keyCode: 51, command: true)
    var longPressSeconds = 0.5
    var scrollLines = 3
    var reverseScroll = false
    var caretInTextFields = true
    var reverseCaret = false
    var switchSpacesWhilePressed = true

    init() {}

    // 以后加新选项时，旧的配置文件里没有这个字段，用默认值补上，不至于整份配置失效。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        deviceTheme = try c.decodeIfPresent(DeviceTheme.self, forKey: .deviceTheme) ?? d.deviceTheme
        voice = try c.decodeIfPresent(KeyCombo.self, forKey: .voice) ?? d.voice
        voiceLong = try c.decodeIfPresent(KeyCombo.self, forKey: .voiceLong)
        voiceDouble = try c.decodeIfPresent(KeyCombo.self, forKey: .voiceDouble)
        confirm = try c.decodeIfPresent(KeyCombo.self, forKey: .confirm) ?? d.confirm
        cancel = try c.decodeIfPresent(KeyCombo.self, forKey: .cancel) ?? d.cancel
        confirmLong = try c.decodeIfPresent(KeyCombo.self, forKey: .confirmLong)
        confirmDouble = try c.decodeIfPresent(KeyCombo.self, forKey: .confirmDouble)
        cancelLong = try c.decodeIfPresent(KeyCombo.self, forKey: .cancelLong)
        cancelDouble = try c.decodeIfPresent(KeyCombo.self, forKey: .cancelDouble)
        knobShortPress = try c.decodeIfPresent(KeyCombo.self, forKey: .knobShortPress) ?? d.knobShortPress
        knobLongPress = try c.decodeIfPresent(KeyCombo.self, forKey: .knobLongPress) ?? d.knobLongPress
        longPressSeconds = try c.decodeIfPresent(Double.self, forKey: .longPressSeconds) ?? d.longPressSeconds
        scrollLines = try c.decodeIfPresent(Int.self, forKey: .scrollLines) ?? d.scrollLines
        reverseScroll = try c.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? d.reverseScroll
        caretInTextFields = try c.decodeIfPresent(Bool.self, forKey: .caretInTextFields) ?? d.caretInTextFields
        reverseCaret = try c.decodeIfPresent(Bool.self, forKey: .reverseCaret) ?? d.reverseCaret
        switchSpacesWhilePressed = try c.decodeIfPresent(Bool.self, forKey: .switchSpacesWhilePressed)
            ?? d.switchSpacesWhilePressed
    }

}

/// 可以设单击、长按、双击的三个键：语音键、确定键、取消键。
enum GestureKey: String, CaseIterable, Identifiable, Sendable {
    case voice, confirm, cancel

    var id: String { rawValue }

    /// AU05 配置口上报的物理键序号。
    var physicalIndex: Int {
        switch self {
        case .voice: return 0
        case .confirm: return 1
        case .cancel: return 2
        }
    }

    init?(physicalIndex: Int) {
        guard let key = Self.allCases.first(where: { $0.physicalIndex == physicalIndex }) else { return nil }
        self = key
    }

    /// 卡片和弹出设置里的名字。
    var title: String {
        switch self {
        case .voice: return "语音键"
        case .confirm: return "确定键"
        case .cancel: return "取消键"
        }
    }

    /// 日志和「已发送」提示里的短名字。
    var name: String {
        switch self {
        case .voice: return "语音"
        case .confirm: return "确定"
        case .cancel: return "取消"
        }
    }

    var singlePath: WritableKeyPath<AppConfig, KeyCombo> {
        switch self {
        case .voice: return \.voice
        case .confirm: return \.confirm
        case .cancel: return \.cancel
        }
    }

    func gesturePath(_ gesture: KeyGesture) -> WritableKeyPath<AppConfig, KeyCombo?> {
        switch (self, gesture) {
        case (.voice, .long): return \.voiceLong
        case (.voice, .double): return \.voiceDouble
        case (.confirm, .long): return \.confirmLong
        case (.confirm, .double): return \.confirmDouble
        case (.cancel, .long): return \.cancelLong
        case (.cancel, .double): return \.cancelDouble
        }
    }

    /// 刚开启某个手势时先给的组合，开启后马上弹出设置，可以再改。
    func suggestedCombo(_ gesture: KeyGesture) -> KeyCombo {
        switch (self, gesture) {
        case (.voice, .long): return .none                                      // 没有通用的，开启后自己选
        case (.voice, .double): return KeyCombo(keyCode: 56, fn: true)          // Fn + 左 Shift
        case (.confirm, .long): return KeyCombo(keyCode: 36, shift: true)       // ⇧↩ 换行
        case (.confirm, .double): return KeyCombo(keyCode: 36, command: true)   // ⌘↩ 发送
        case (.cancel, .long): return KeyCombo(keyCode: 51, command: true)      // ⌘⌫ 删到行首
        case (.cancel, .double): return KeyCombo(keyCode: 6, command: true)     // ⌘Z 撤销
        }
    }
}

private final class ConfigBox: @unchecked Sendable {
    let lock = NSLock()
    var value: AppConfig
    init(_ value: AppConfig) { self.value = value }
}

/// 当前配置。按键处理在后台队列里读，设置界面在主线程里写，所以加锁；写的时候同时存进 UserDefaults。
enum Config {
    private static let defaultsKey = "config.v1"
    private static let box = ConfigBox(load())

    static var current: AppConfig {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.value
    }

    static func update(_ value: AppConfig) {
        box.lock.lock()
        box.value = value
        box.lock.unlock()
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// 以前用过的 Bundle ID（新的在前）：local.lepak 是正式开发者 ID 之前的临时 ID，local.vibe-key 是改名前的。
    /// 当前 ID 下还没有配置时，从这里把旧配置搬过来一次。
    private static let legacyDomains = ["local.lepak", "local.vibe-key"]

    private static func load() -> AppConfig {
        var data = UserDefaults.standard.data(forKey: defaultsKey)
        if data == nil {
            for domain in legacyDomains where domain != Bundle.main.bundleIdentifier {
                guard let old = UserDefaults(suiteName: domain)?.data(forKey: defaultsKey) else { continue }
                UserDefaults.standard.set(old, forKey: defaultsKey)
                data = old
                break
            }
        }
        guard let data, let value = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return value
    }
}
