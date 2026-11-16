import AuthenticationServices
import Combine
import SwiftUI

/// 设置窗口，版式参考 Typeless：左边一条圆角侧栏（Logo、首页、「我的设备」列表、底部图标），
/// 右边是当前页，画布上有一层淡淡的点阵。按 AU05 上的键时，底部中间弹出「已发送 …」提示。
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let accent = Brand.accent
        HStack(spacing: 0) {
            Sidebar(model: model)
                .padding(8)
            ZStack(alignment: .bottom) {
                DotGrid()
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.25),
                        .init(color: .black, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
                Group {
                    switch model.section {
                    case .home: HomePage(model: model)
                    case .device(let kind): DevicePage(model: model, kind: kind)
                    case .general: GeneralPage(model: model)
                    }
                }
                // minWidth / minHeight 0 + clipped：页面内容再宽再高也只占右边这块，多出来的被裁掉，
                // 不会把整个窗口撑开、把侧栏挤出左边或往下推。
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
                if let action = model.flash {
                    FlashToast(action: action, accent: accent)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: model.flash?.id)
            // 重命名：系统对话框带一个输入框。和「移除」的确认框挂在不同的视图上，两个才都弹得出来。
            .alert(
                "重命名设备",
                isPresented: Binding(
                    get: { model.renamingDevice != nil },
                    set: { if !$0 { model.renamingDevice = nil } }
                ),
                presenting: model.renamingDevice
            ) { kind in
                TextField(kind.name, text: $model.renameText)
                Button("保存") { model.rename(kind, to: model.renameText) }
                Button("取消", role: .cancel) { model.renamingDevice = nil }
            } message: { kind in
                Text("最多 \(SettingsModel.maxNameLength) 个字。留空就用型号名「\(kind.name)」。")
            }
        }
        // 标题栏是透明的，内容一直铺到窗口最顶上，红黄绿按钮落在侧栏里。
        .ignoresSafeArea()
        .background(Palette.canvas.ignoresSafeArea())
        .tint(accent)
        .toggleStyle(ThemedSwitch(accent: accent))
        .frame(minWidth: 1000, minHeight: 660)
        .sheet(isPresented: Binding(
            get: { model.addDeviceStep != nil },
            set: { if !$0 { model.cancelAddDevice() } }
        )) {
            AddDeviceSheet(model: model)
        }
        .alert(
            model.removingDevice.map { "移除 \(model.displayName($0))？" } ?? "",
            isPresented: Binding(
                get: { model.removingDevice != nil },
                set: { if !$0 { model.removingDevice = nil } }
            ),
            presenting: model.removingDevice
        ) { kind in
            Button("移除", role: .destructive) { model.removeDevice(kind) }
            Button("取消", role: .cancel) { model.removingDevice = nil }
        } message: { kind in
            Text("Lepak 会断开 \(model.displayName(kind))，不再处理它的按键。名字和按键设置会保留，以后再添加回来还能接着用。")
        }
    }
}

// MARK: 侧栏

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: model.isFullScreen ? 18 : 50)   // 让开红黄绿按钮（全屏时没有）
            HStack(spacing: 8) {
                BrandMark()
                Text("LEPAK").font(.system(size: 21, weight: .bold))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 4) {
                NavItem(title: "首页", systemImage: "house", selected: model.section == .home) {
                    model.section = .home
                }
                // 用户添加过的设备，每台一行，圆点是连接状态；几台设备同时工作，点哪台只是看哪台的设置。
                // 右键一行可以重命名、移除；「添加设备」打开弹窗，不是一页。
                Text("我的设备")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                ForEach(model.config.devices) { kind in
                    let link = model.snapshot(of: kind).link
                    NavItem(title: model.displayName(kind), systemImage: kind.systemImage,
                            selected: model.section == .device(kind), status: link.color) {
                        model.section = .device(kind)
                    }
                    .help(link.text)
                    .contextMenu {
                        Button("重命名…") { model.beginRename(kind) }
                        Button("移除设备…") { model.removingDevice = kind }
                    }
                }
                NavItem(title: "添加设备", systemImage: "plus", selected: model.addDeviceStep != nil) {
                    model.beginAddDevice()
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 16)
            NavItem(title: "设置", systemImage: "gearshape", selected: model.section == .general) {
                model.section = .general
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            RowDivider().padding(.horizontal, 14)
            // 版本号和日志在「设置 → 关于」里，底部只放账号。
            // 点账号去「设置」：没登录在那里用 Apple 登录，登录了在那里退出。
            Button { model.section = .general } label: {
                AccountRow(account: model.account)
                    .padding(.horizontal, 8)
                    .frame(height: 50)
            }
            .buttonStyle(RowButtonStyle(radius: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 204)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.hairline))
    }
}

/// 侧栏 Logo：和菜单栏同一个六竖条图标，放大到 18pt 高。
private struct BrandMark: View {
    var body: some View {
        Image(nsImage: BrandIcon.image(height: 18))
            .renderingMode(.template)
            .foregroundStyle(.primary)
    }
}

private struct NavItem: View {
    let title: String
    let systemImage: String
    let selected: Bool
    /// 设备行右边的连接状态圆点。
    var status: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let status {
                    Circle().fill(status).frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Palette.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 侧栏底部的账号：头像、邮箱，下面一行是登录状态（不是操作）。
/// 账号登录还没做，没登录时只显示占位头像和「未登录」。
private struct AccountRow: View {
    let account: Account?

    var body: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                if let account {
                    Text(account.email ?? "Apple 账号")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("已登录").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("未登录")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .help(account.map { $0.email ?? "Apple 账号" } ?? "未登录")
    }

    /// 登录后是邮箱首字母的圆形头像（拿不到邮箱就是人形）；没登录是灰色人形占位。
    @ViewBuilder private var avatar: some View {
        if let account {
            Group {
                if let first = account.email?.first {
                    Text(String(first).uppercased()).font(.system(size: 13, weight: .bold))
                } else {
                    Image(systemName: "person.fill").font(.system(size: 13))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Brand.accent.gradient))
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.raised))
        }
    }
}

extension DeviceSnapshot.Link {
    var text: String {
        switch self {
        case .connected: return "已连接"
        case .connecting: return "正在连接…"
        case .disconnected: return "未连接"
        }
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .secondary
        }
    }
}

/// 「已发送 ⌘ ⌫ 删到行首」提示。
private struct FlashToast: View {
    let action: DeviceAction
    let accent: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
            Text(action.combo == nil ? action.control.title : "已发送").font(.system(size: 13, weight: .semibold))
            if let combo = action.combo {
                ComboKeycaps(combo: combo, small: true)
            }
            Text(action.title).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Capsule().fill(Palette.card))
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

// MARK: 首页

/// 首页：大标题和「洞察」（使用次数、连续天数、热力图、按设备），占满整页宽度。
/// 以后会接多台设备、遥控器等，首页只放统计，不再放某一台设备的快捷键和设备卡（在「按键」「设备」页看）。
/// 次数只从设备配置口的按键算（见 `Usage`），不读任何输入内容，所以没有「口述字数」这类数字。
private struct HomePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("说话，不用打字")
                    .font(.system(size: 44, weight: .heavy))
                InsightsSection(usage: model.usage, accent: Brand.accent, devices: model.config.devices,
                                name: { model.displayName($0) },
                                link: { model.snapshot(of: $0).link },
                                open: { model.section = .device($0) },
                                add: { model.beginAddDevice() })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 50)
            .padding(.bottom, 80)
        }
    }
}

private struct InsightsSection: View {
    let usage: UsageSummary
    let accent: Color
    let devices: [DeviceKind]
    let name: (DeviceKind) -> String
    let link: (DeviceKind) -> DeviceSnapshot.Link
    let open: (DeviceKind) -> Void
    let add: () -> Void

    private static let knob: [MappingControl] = [.knobPress, .knobTurn, .knobPressTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("洞察").font(.system(size: 26, weight: .bold)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                tile("语音键", [.voice])
                tile("确定", [.confirm])
                tile("取消", [.cancel])
                tile("旋钮", Self.knob)
            }
            StreakCard(usage: usage, accent: accent)
            DevicesCard(usage: usage, devices: devices, name: name, link: link, open: open, add: add)
        }
    }

    private func tile(_ title: String, _ controls: [MappingControl]) -> some View {
        let today = usage.todayCount(controls)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Self.compact(usage.total(controls))).font(.system(size: 30, weight: .bold))
                Text("次").font(.system(size: 13, weight: .semibold))
            }
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14)).foregroundStyle(.secondary)
                if today > 0 {
                    Text("今天 \(today) 次").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 20, radius: 18)
    }

    /// 5200 → 5.2K，和 Typeless 一样把大数字缩短。
    static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return k < 100 ? String(format: "%.1fK", k).replacingOccurrences(of: ".0K", with: "K") : "\(Int(k))K"
    }
}

/// 活跃天数、当前连续、最长连续，下面是按天的热力图（一列一周，最右一列是本周）。
private struct StreakCard: View {
    let usage: UsageSummary
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 0) {
                number(usage.activeDays, "活跃天数")
                number(usage.currentStreak, "当前连续天数")
                number(usage.longestStreak, "最长连续天数")
            }
            Heatmap(perDay: usage.perDay, accent: accent)
            HStack(spacing: 5) {
                Text("更少").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(0..<5) { level in
                    Heatmap.cell(level: level, accent: accent).frame(width: 11, height: 11)
                }
                Text("更多").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 20, radius: 18)
    }

    private func number(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(value)").font(.system(size: 28, weight: .bold))
                Text("天").font(.system(size: 13, weight: .semibold))
            }
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Heatmap: View {
    let perDay: [String: Int]
    let accent: Color

    private static let cellSize: CGFloat = 12
    private static let gap: CGFloat = 4
    private static let labelWidth: CGFloat = 18
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        GeometryReader { proxy in
            let weeks = max(4, Int((proxy.size.width - Self.labelWidth + Self.gap) / (Self.cellSize + Self.gap)))
            let columns = Self.columns(weeks: weeks)
            let maxCount = max(1, perDay.values.max() ?? 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: Self.gap) {
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(Self.weekdays[row])
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .frame(width: Self.labelWidth - Self.gap, height: Self.cellSize, alignment: .leading)
                        }
                    }
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { row in
                                if let day = column.days[row] {
                                    Self.cell(level: Self.level(perDay[day] ?? 0, max: maxCount), accent: accent)
                                        .frame(width: Self.cellSize, height: Self.cellSize)
                                        .help("\(day)：\(perDay[day] ?? 0) 次")
                                } else {
                                    Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: Self.gap) {
                    Color.clear.frame(width: Self.labelWidth - Self.gap, height: 1)
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        Color.clear
                            .frame(width: Self.cellSize, height: 12)
                            .overlay(alignment: .leading) {
                                if let month = column.monthLabel {
                                    Text(month).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                                }
                            }
                    }
                }
            }
        }
        .frame(height: 7 * Self.cellSize + 6 * Self.gap + 18)
    }

    struct Column {
        /// 周日到周六；今天之后的格子是 nil。
        var days: [String?]
        /// 这一列是新月份的开头时显示「11月」。
        var monthLabel: String?
    }

    static func columns(weeks: Int, now: Date = Date()) -> [Column] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today) - 1   // 0 = 周日
        guard let lastSunday = calendar.date(byAdding: .day, value: -weekday, to: today) else { return [] }
        var result: [Column] = []
        var previousMonth: Int?
        for week in 0..<weeks {
            guard let sunday = calendar.date(byAdding: .day, value: (week - weeks + 1) * 7, to: lastSunday) else { continue }
            var days: [String?] = []
            for offset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: sunday), date <= today else {
                    days.append(nil)
                    continue
                }
                days.append(Usage.dayKey(date))
            }
            let month = calendar.component(.month, from: sunday)
            let label = previousMonth != nil && month != previousMonth ? "\(month)月" : nil
            previousMonth = month
            result.append(Column(days: days, monthLabel: label))
        }
        return result
    }

    static func level(_ count: Int, max: Int) -> Int {
        guard count > 0 else { return 0 }
        let fraction = Double(count) / Double(max)
        switch fraction {
        case ...0.25: return 1
        case ...0.5: return 2
        case ...0.75: return 3
        default: return 4
        }
    }

    static func cell(level: Int, accent: Color) -> some View {
        let opacities: [Double] = [0, 0.3, 0.5, 0.75, 1]
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(level == 0 ? Palette.raised : accent.opacity(opacities[level]))
    }
}

/// 按设备分开的次数。只列「我的设备」里的（没用过的显示 0 次），点一行打开那台设备的页面；
/// 移除了的设备不再列出来（用户 2026-11-16），它以前的次数仍算在上面的总数和热力图里。
/// 一台都没添加时，只显示一张「添加设备」的提示。
private struct DevicesCard: View {
    let usage: UsageSummary
    let devices: [DeviceKind]
    let name: (DeviceKind) -> String
    let link: (DeviceKind) -> DeviceSnapshot.Link
    let open: (DeviceKind) -> Void
    let add: () -> Void

    var body: some View {
        let count = { (name: String) in usage.perDevice[name] ?? 0 }
        // 次数一样时保持添加顺序。
        let added = devices.enumerated()
            .sorted { (count($0.element.usageName), -$0.offset) > (count($1.element.usageName), -$1.offset) }
            .map(\.element)
        return VStack(alignment: .leading, spacing: 12) {
            if added.isEmpty {
                emptyCard
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(added.enumerated()), id: \.element) { index, kind in
                        if index > 0 { RowDivider() }
                        Button { open(kind) } label: { row(kind) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 0, radius: 18)
            }
        }
    }

    private var emptyCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("还没有添加设备").font(.system(size: 15, weight: .semibold))
                Text("添加设备后，Lepak 才会连接它、处理它的按键。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("添加设备", action: add)
                .buttonStyle(PillButtonStyle(kind: .accent(Brand.accent), height: 34))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
    }

    /// 标题用用户起的名字，改过名的下面补一句型号。次数按使用记录里的设备名（型号名）查。
    private func row(_ kind: DeviceKind) -> some View {
        let device = kind.usageName
        let title = name(kind)
        let detail = title == device ? lastUsed(device) : "\(device) · \(lastUsed(device))"
        return HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(link(kind).color).frame(width: 7, height: 7)
            Text("\(usage.perDevice[device] ?? 0) 次").font(.system(size: 15, weight: .bold))
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func lastUsed(_ device: String) -> String {
        guard let day = usage.deviceLastDay[device] else { return "还没有使用记录" }
        let today = Usage.dayKey(Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()).map(Usage.dayKey)
        if day == today { return "最近使用：今天" }
        if day == yesterday { return "最近使用：昨天" }
        return "最近使用：\(day)"
    }
}

// MARK: 设备

/// 一台设备的页面：顶上是设备名、连接和电量，右上角切换款式（AU05）；下面是按键映射展台。
/// 电量已经在标题旁边，电压、连接方式这类数字不再单独列（用户 2026-11-12）。
private struct DevicePage: View {
    @ObservedObject var model: SettingsModel
    let kind: DeviceKind

    /// AU05 跟着它的款式配色，别的设备用标准配色。
    private var theme: DeviceTheme { kind == .au05 ? model.theme : .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 46)
            if kind == .au05, model.ulanziRunning {
                UlanziBanner(model: model)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
            }
            KeysPage(model: model, ui: model.mappingUI, kind: kind)
        }
        // 设备页里的开关、选中状态用这台设备的主题色；窗口其他地方是固定的 `Brand.accent`。
        .tint(theme.accent)
        .toggleStyle(ThemedSwitch(accent: theme.accent))
    }

    private var header: some View {
        let device = model.snapshot(of: kind)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    // 名字太长时先缩小字号、再截短，状态、款式切换和右边的按钮保持完整。鼠标停在名字上显示型号。
                    Text(model.displayName(kind)).font(.system(size: 40, weight: .heavy)).lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .help(kind.name)
                    HStack(spacing: 6) {
                        Circle().fill(device.link.color).frame(width: 8, height: 8)
                        Text(statusText(device)).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                Spacer(minLength: 12)
                if kind == .au05 {
                    ThemeSwitcher(selection: $model.config.deviceTheme)
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    CircleIconButton(systemImage: "pencil", help: "重命名") { model.beginRename(kind) }
                    CircleIconButton(systemImage: "trash", help: "移除这台设备") { model.removingDevice = kind }
                }
            }
            HStack(spacing: 14) {
                Text(kind == .au05 ? "点设备上的键或两侧的卡片，设置它发什么。改动立即生效。"
                                   : "点设备上的键或右边的卡片，设置它发什么。改动立即生效，屏幕上的提示也会跟着变。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if kind == .passport {
                    MicBadge(status: model.passportMic)
                }
                if !model.keysAreDefault(kind) {
                    Button("恢复默认") { model.resetKeys(kind) }
                        .buttonStyle(PillButtonStyle(kind: .subtle, height: 32))
                }
            }
            .frame(height: 32)
        }
    }

    private func statusText(_ device: DeviceSnapshot) -> String {
        guard device.link == .connected else {
            return device.note.map { "\(device.link.text) · \($0)" } ?? device.link.text
        }
        guard let percent = device.percent else { return device.link.text }
        return "已连接 · 电量 \(percent)%\(device.charging ? " · 充电中" : "")"
    }
}

/// 设备页右上角的圆形图标按钮（重命名、移除），和款式切换一样高。
private struct CircleIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Palette.card))
                .overlay(Circle().strokeBorder(Palette.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// AI Passport 页上的一小块：Lepak 麦克风装没装、有没有程序在用。
private struct MicBadge: View {
    let status: PassportMic.Status

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status == .listening ? "mic.fill" : "mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Palette.raised))
        .help(help)
    }

    private var text: String {
        switch status {
        case .notInstalled: return "Lepak 麦克风未安装"
        case .ready: return "Lepak 麦克风已就绪"
        case .listening: return "麦克风使用中"
        }
    }

    private var color: Color {
        switch status {
        case .notInstalled: return .secondary
        case .ready: return .green
        case .listening: return .orange
        }
    }

    private var help: String {
        switch status {
        case .notInstalled: return "装好 Lepak 麦克风后，在 Typeless 里把麦克风选成「Lepak 麦克风」，就能对着 AI Passport 说话。"
        case .ready: return "在 Typeless 里把麦克风选成「Lepak 麦克风」。开始录音时设备自动开麦，录完自动关。"
        case .listening: return "有程序正在用 Lepak 麦克风，AI Passport 的麦克风开着。"
        }
    }
}

/// 设备页右上角的款式切换（AU05 有标准版和 WorkBuddy 版）：一条胶囊，每段是配色圆点和名字，选中的那段垫高一层。
/// 款式是这台设备自己的，所以放在设备页，不放在全局「设置」。
private struct ThemeSwitcher: View {
    @Binding var selection: DeviceTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DeviceTheme.allCases) { theme in
                let selected = selection == theme
                Button { selection = theme } label: {
                    HStack(spacing: 7) {
                        Circle().fill(theme.accent).frame(width: 9, height: 9)
                        Text(theme.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule().fill(selected ? Palette.raised : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.card))
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .help("选和你手上这台一样的款式，设备图和这一页的配色会跟着换。")
    }
}

/// 设备页顶上的一条提醒：Ulanzi Studio 也在运行。只在它运行时出现，占一行，不挤掉按键展台。
private struct UlanziBanner: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Ulanzi Studio 也在运行，同一个键可能被处理两次。")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("退出 Ulanzi Studio") { model.quitUlanzi() }
                .buttonStyle(PillButtonStyle(kind: .accent(.orange), height: 28))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: 添加设备（弹窗）

/// 「添加设备」弹窗，两步：先选型号（已添加的灰掉），再看着实时状态把它连上，点「完成」才加进「我的设备」。
/// 第二步一进来 Lepak 就开始连这台（见 `SettingsModel.activeDevices`），取消或返回就断开。
/// 以后支持的设备加在 `DeviceKind` 里，第一步自动多一张卡。
struct AddDeviceSheet: View {
    @ObservedObject var model: SettingsModel

    static let width: CGFloat = 620

    var body: some View {
        Group {
            switch model.addDeviceStep {
            case .connect(let kind): connectStep(kind)
            default: chooseStep
            }
        }
        .padding(28)
        .frame(width: Self.width)
        .background(Palette.canvas)
        .tint(Brand.accent)
    }

    // MARK: 第一步：选型号

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("添加设备").font(.system(size: 24, weight: .bold))
                Text("选择你要连接的设备。").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)
            VStack(spacing: 10) {
                ForEach(DeviceKind.allCases) { kind in
                    modelCard(kind)
                }
                moreCard
            }
            HStack {
                Spacer()
                Button("取消") { model.cancelAddDevice() }
                    .buttonStyle(PillButtonStyle(kind: .subtle, height: 34))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 22)
        }
    }

    private func modelCard(_ kind: DeviceKind) -> some View {
        let added = model.isAdded(kind)
        return Button { model.chooseDevice(kind) } label: {
            HStack(spacing: 16) {
                thumbnail(kind, height: 64)
                    .frame(width: 64, height: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.name).font(.system(size: 16, weight: .semibold))
                    Text(kind.connectionHint).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if added {
                    Text("已添加")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Palette.raised))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(SheetCardButtonStyle())
        .disabled(added)
        .opacity(added ? 0.6 : 1)
    }

    /// 虚线框：还没支持的设备。
    private var moreCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("更多设备").font(.system(size: 15, weight: .semibold))
                Text("遥控器等更多设备正在适配，支持后会出现在这里。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
    }

    // MARK: 第二步：连接

    private func connectStep(_ kind: DeviceKind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { model.addDeviceStep = .choose } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.raised))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("上一步")
                Text("连接 \(kind.name)").font(.system(size: 24, weight: .bold))
            }
            .padding(.bottom, 20)
            HStack(alignment: .top, spacing: 22) {
                thumbnail(kind, height: 150)
                    .frame(width: 112, height: 168)
                VStack(alignment: .leading, spacing: 16) {
                    status(kind)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(Self.steps(kind).enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Palette.raised))
                                Text(step)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .card(padding: 20, radius: 18)
            if kind == .au05, model.ulanziRunning {
                UlanziBanner(model: model)
                    .padding(.top, 12)
            }
            nameField(kind)
                .padding(.top, 16)
            HStack(spacing: 10) {
                Note(model.snapshot(of: kind).link == .connected
                     ? "已经连上了，点「完成」把它加进「我的设备」。"
                     : "还没连上也可以先点「完成」，设备开机后会自动连上。")
                Spacer(minLength: 12)
                Button("取消") { model.cancelAddDevice() }
                    .buttonStyle(PillButtonStyle(kind: .subtle, height: 34))
                    .keyboardShortcut(.cancelAction)
                Button("完成") { model.finishAddDevice() }
                    .buttonStyle(PillButtonStyle(kind: .accent(Brand.accent), height: 34))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
    }

    /// 给这台设备起个名字，默认是型号名；以后在设备页或侧栏右键还能改。
    private func nameField(_ kind: DeviceKind) -> some View {
        HStack(spacing: 14) {
            Text("名称").font(.system(size: 14, weight: .semibold))
            TextField(kind.name, text: $model.newDeviceName)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
                .onSubmit { model.finishAddDevice() }
            Text("以后也可以改").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// 实时连接状态：连上了是绿点和电量，没连上是转圈；蓝牙关着这类原因用橙色感叹号写出来。
    private func status(_ kind: DeviceKind) -> some View {
        let device = model.snapshot(of: kind)
        let connected = device.link == .connected
        return HStack(spacing: 8) {
            if connected {
                Circle().fill(Color.green).frame(width: 8, height: 8)
            } else if device.note != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(statusText(device)).font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(Palette.raised))
    }

    private func statusText(_ device: DeviceSnapshot) -> String {
        if device.link == .connected {
            return device.percent.map { "已连接 · 电量 \($0)%" } ?? "已连接"
        }
        return device.note ?? "正在寻找设备…"
    }

    private func thumbnail(_ kind: DeviceKind, height: CGFloat) -> some View {
        let theme = kind == .au05 ? model.theme : .standard
        let art = DeviceArt.of(kind, theme: theme)
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised.opacity(0.6))
            DeviceArtView(art: art, accent: theme.accent)
                .frame(width: height * art.aspect, height: height)
        }
    }

    private static func steps(_ kind: DeviceKind) -> [String] {
        switch kind {
        case .au05:
            return [
                "插上 AU05 的 USB 接收器，打开 AU05。",
                "如果装了 Ulanzi Studio，先退出它，免得两边同时接管 AU05。",
                "上面显示「已连接」，就是连上了。",
            ]
        case .passport:
            return [
                "先给 AI Passport 刷上社区固件（InputBetter 或 FoloVibe Key）。出厂的官方固件连不上 Lepak。",
                "打开 Mac 的蓝牙，给 AI Passport 开机。Lepak 会自己找到它并连上，第一次会问能不能使用蓝牙，点允许。",
                "如果开着 InputBetter 或 FoloVibe Key 的 App，先退出它：一台设备同时只能连一个程序。",
                "上面显示「已连接」，就是连上了。屏幕上会显示三个键现在发什么。",
            ]
        }
    }
}

/// 弹窗里整张可点的卡片：平时是卡片底色，按下深一层。
private struct SheetCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(configuration.isPressed ? Palette.raised : Palette.card)
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: 设置（启动、权限、关于）——只放和具体设备无关的；设备的外观主题在设备页「设备信息」里

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var colorScheme
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let accent = Brand.accent
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(title: "设置")
                group("账号") { account }
                group("启动") {
                    SettingRow(title: "登录时自动启动", detail: model.loginItemMessage) {
                        HStack(spacing: 10) {
                            if model.loginItemMessage != nil {
                                Button("打开登录项设置") { model.openLoginItemsSettings() }
                                    .buttonStyle(PillButtonStyle(kind: .subtle, height: 30))
                            }
                            AccentSwitch(isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            ), accent: accent)
                        }
                    }
                }
                group("权限") {
                    SettingRow(title: "辅助功能（必需）",
                               detail: "用来发出 Fn、回车、方向键等按键，并判断光标是不是在输入框里。不开启的话 AU05 的按键都不起作用。") {
                        permission(model.accessibilityTrusted, kind: .accent(accent), open: model.openAccessibilitySettings)
                    }
                }
                group("关于") {
                    SettingRow(title: "版本") {
                        Text(model.versionText).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    }
                    RowDivider()
                    SettingRow(title: "日志", detail: "排查问题时用。") {
                        Button("在 Finder 中显示") { model.revealLog() }
                            .buttonStyle(PillButtonStyle(kind: .subtle, height: 30))
                    }
                }
                Note("设置改动会立即生效，并自动保存。")
            }
            .padding(.horizontal, 28)
            .padding(.top, 46)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.refreshPermissions()
            model.refreshLoginItem()
        }
        .onReceive(refresh) { _ in model.refreshPermissions() }
    }

    /// 账号：没登录时是「用 Apple 登录」按钮（用 Apple 规定的样式，浅色窗口黑底、深色窗口白底）；
    /// 登录了显示头像、邮箱和「退出登录」。
    @ViewBuilder private var account: some View {
        if model.account != nil {
            HStack(spacing: 12) {
                AccountRow(account: model.account)
                Button("退出登录") { model.signOut() }
                    .buttonStyle(PillButtonStyle(kind: .subtle, height: 30))
            }
            .padding(.vertical, 14)
        } else {
            SettingRow(title: "用 Apple 登录", detail: model.accountMessage ?? "用你的 Apple 账号登录，不用另外设密码。") {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email]
                } onCompletion: { result in
                    model.completeSignIn(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                // 系统按钮只在创建时读一次样式；换浅色 / 深色时重建，不然会白按钮放在白卡片上。
                .id(colorScheme)
                .frame(width: 190, height: 32)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
                .card(padding: 0)
        }
    }

    @ViewBuilder private func permission(_ granted: Bool, kind: PillButtonStyle.Kind, open: @escaping () -> Void) -> some View {
        if granted {
            Label("已允许", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
        } else {
            Button("去开启", action: open)
                .buttonStyle(PillButtonStyle(kind: kind, height: 30))
        }
    }
}
