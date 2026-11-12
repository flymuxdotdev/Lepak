import CoreGraphics
import Foundation

/// 一个按键组合：键码 + 修饰键。`none` 表示不发送任何键。
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var command = false
    var shift = false
    var option = false
    var control = false

    static let none = KeyCombo(keyCode: 0xFFFF)

    var isNone: Bool { keyCode == KeyCombo.none.keyCode }

    var flags: CGEventFlags {
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if option { flags.insert(.maskAlternate) }
        if control { flags.insert(.maskControl) }
        return flags
    }

    /// 例如「⌘⌫ 删到行首」。常用组合带中文说明，其他只显示符号。
    var title: String {
        if isNone { return "不发送" }
        let symbols = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + KeyCombo.keyName(keyCode)
        if let label = KeyPresets.labels[self] {
            return "\(symbols)  \(label)"
        }
        return symbols
    }

    static func keyName(_ code: UInt16) -> String {
        if code == 63 { return "Fn" }
        return KeyCatalog.names[code] ?? "键\(code)"
    }

    /// 拆成一个个键帽：修饰键各一个，再加主键。不发送时为空。
    var parts: [String] {
        guard !isNone else { return [] }
        return [control ? "⌃" : nil, option ? "⌥" : nil, shift ? "⇧" : nil, command ? "⌘" : nil]
            .compactMap { $0 } + [KeyCombo.keyName(keyCode)]
    }

    /// 常用组合的中文说明，比如「删到行首」；不是常用组合时为 nil。
    var label: String? { KeyPresets.labels[self] }
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
    ]

    static let names: [UInt16: String] = Dictionary(
        groups.flatMap { $0.keys }.map { ($0.code, $0.name) },
        uniquingKeysWith: { first, _ in first }
    )
}

/// 设置里可选的常用组合。第一版先从列表里选，以后再加「录制组合键」。
enum KeyPresets {
    static let options: [(KeyCombo, String)] = [
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

/// 可以在设置里调整的所有选项。默认值就是改设置界面之前写死的行为。
struct AppConfig: Codable, Equatable, Sendable {
    var deviceTheme = DeviceTheme.standard
    var confirm = KeyCombo(keyCode: 36)
    var cancel = KeyCombo(keyCode: 53)
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
        confirm = try c.decodeIfPresent(KeyCombo.self, forKey: .confirm) ?? d.confirm
        cancel = try c.decodeIfPresent(KeyCombo.self, forKey: .cancel) ?? d.cancel
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

    private static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return value
    }
}
