import Foundation

/// 首页「洞察」用的使用次数：每天、每台设备、每个控件按了几次。
///
/// 只记次数，不记任何文字、按键内容或时间点（AGENTS.md：不能把用户的按键内容写进文件）。
/// 次数只来自设备自己上报的按键（AU05 配置口的语音键、确定、取消、旋钮；AI Passport 蓝牙上报的三个键），和电脑键盘无关。
/// 存在 `~/Library/Application Support/Lepak/usage.json`，只在本机。
struct UsageData: Codable, Equatable, Sendable {
    /// 日期（yyyy-MM-dd，本地时区）→ 设备 → 控件（`MappingControl.rawValue`）→ 次数。
    var days: [String: [String: [String: Int]]] = [:]
}

/// 按控件和设备加总后的结果，首页直接拿来画。
struct UsageSummary: Equatable {
    var totals: [MappingControl: Int] = [:]
    var today: [MappingControl: Int] = [:]
    /// 每天的总次数（所有设备、所有控件）。
    var perDay: [String: Int] = [:]
    /// 设备 → 总次数。
    var perDevice: [String: Int] = [:]
    /// 设备 → 最近一次有记录的日期。
    var deviceLastDay: [String: String] = [:]
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0

    func total(_ controls: [MappingControl]) -> Int { controls.reduce(0) { $0 + (totals[$1] ?? 0) } }
    func todayCount(_ controls: [MappingControl]) -> Int { controls.reduce(0) { $0 + (today[$1] ?? 0) } }
}

final class Usage: @unchecked Sendable {
    static let shared = Usage()
    /// 每台设备用各自的名字记，首页按设备分开显示。这是 usage.json 里的键，不跟着界面上的型号名改，
    /// 改了以前的次数就对不上了（界面上显示的是 `DeviceKind.name`）。
    static let au05 = "Ulanzi AU05"
    static let passport = "AI Passport"

    private let lock = NSLock()
    private var data: UsageData
    private var saveScheduled = false
    private let queue = DispatchQueue(label: "local.lepak.usage")
    private var handler: (@Sendable (UsageData) -> Void)?

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lepak/usage.json")
    }

    private init() {
        if let raw = try? Data(contentsOf: Self.fileURL),
           let value = try? JSONDecoder().decode(UsageData.self, from: raw) {
            data = value
        } else {
            data = UsageData()
        }
    }

    var snapshot: UsageData {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    /// 有新次数时回调（任意线程）。
    func onChange(_ handler: @escaping @Sendable (UsageData) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// 记一次。可以在任意线程调用。
    func add(_ control: MappingControl, device: String = Usage.au05) {
        let day = Self.dayKey(Date())
        lock.lock()
        data.days[day, default: [:]][device, default: [:]][control.rawValue, default: 0] += 1
        let value = data
        let handler = handler
        let needsSave = !saveScheduled
        saveScheduled = true
        lock.unlock()
        handler?(value)
        if needsSave {
            // 连按时合并成一次写盘。
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.save() }
        }
    }

    private func save() {
        lock.lock()
        let value = data
        saveScheduled = false
        lock.unlock()
        guard let raw = try? JSONEncoder().encode(value) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? raw.write(to: url, options: .atomic)
    }

    /// 退出前把还没写盘的次数写下去。
    func flush() {
        queue.sync { save() }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func summarize(_ data: UsageData, now: Date = Date()) -> UsageSummary {
        var s = UsageSummary()
        let todayKey = dayKey(now)
        for (day, devices) in data.days {
            var dayTotal = 0
            for (device, controls) in devices {
                var deviceTotal = 0
                for (raw, count) in controls {
                    guard let control = MappingControl(rawValue: raw) else { continue }
                    s.totals[control, default: 0] += count
                    if day == todayKey { s.today[control, default: 0] += count }
                    deviceTotal += count
                }
                s.perDevice[device, default: 0] += deviceTotal
                if deviceTotal > 0, day > (s.deviceLastDay[device] ?? "") { s.deviceLastDay[device] = day }
                dayTotal += deviceTotal
            }
            if dayTotal > 0 { s.perDay[day] = dayTotal }
        }
        s.activeDays = s.perDay.count

        // 连续天数：按日历一天天往回数。
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func active(_ offset: Int) -> Bool {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return false }
            return s.perDay[dayKey(date)] != nil
        }
        // 今天还没用也不算断：从昨天开始数。
        var start = active(0) ? 0 : 1
        var streak = 0
        while active(start) { streak += 1; start += 1 }
        s.currentStreak = streak

        let sortedDays = s.perDay.keys.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for key in sortedDays {
            guard let date = date(from: key) else { continue }
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        s.longestStreak = longest
        return s
    }

    static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
