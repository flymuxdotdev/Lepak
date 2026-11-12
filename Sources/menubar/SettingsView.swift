import Combine
import SwiftUI

/// 设置窗口，版式参考 Typeless：左边一条圆角侧栏（Logo、首页 / 按键 / 设备、设备状态卡、底部图标），
/// 右边是当前页，画布上有一层淡淡的点阵。按 AU05 上的键时，底部中间弹出「已发送 …」提示。
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let theme = model.theme
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
                    case .keys: KeysPage(model: model, ui: model.mappingUI)
                    case .device: DevicePage(model: model)
                    case .general: GeneralPage(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if let action = model.flash {
                    FlashToast(action: action, accent: theme.accent)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: model.flash?.id)
        }
        // 标题栏是透明的，内容一直铺到窗口最顶上，红黄绿按钮落在侧栏里。
        .ignoresSafeArea()
        .background(Palette.canvas.ignoresSafeArea())
        .tint(theme.accent)
        .toggleStyle(ThemedSwitch(accent: theme.accent))
        .frame(minWidth: 1000, minHeight: 660)
    }
}

// MARK: 侧栏

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let accent = model.theme.accent
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 50)   // 让开红黄绿按钮
            HStack(spacing: 8) {
                BrandMark().frame(width: 22, height: 22)
                Text("Vibe Key").font(.system(size: 21, weight: .bold))
                Badge(text: "AU05", color: accent)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 22)
            VStack(spacing: 4) {
                ForEach(SettingsSection.navigation) { item in
                    NavItem(section: item, selected: model.section == item) { model.section = item }
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 16)
            DeviceStatusCard(model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            RowDivider().padding(.horizontal, 14)
            HStack(spacing: 2) {
                Text(model.versionText)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
                IconButton(systemImage: "doc.text", help: "在 Finder 中显示日志") { model.revealLog() }
                IconButton(systemImage: "gearshape", help: "设置", selected: model.section == .general) {
                    model.section = .general
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 50)
        }
        .frame(width: 204)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.hairline))
    }
}

/// 侧栏 Logo：菜单栏用的键帽麦克风图标。直接 swift run 时没有这张图，用系统符号代替。
private struct BrandMark: View {
    var body: some View {
        if let image = NSImage(named: "MenuBarIcon") {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: "mic.fill").resizable().scaledToFit()
        }
    }
}

private struct NavItem: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(section.title).font(.system(size: 15, weight: selected ? .semibold : .regular))
                Spacer()
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

private struct IconButton: View {
    let systemImage: String
    let help: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Palette.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 侧栏底部的设备卡：连接状态、电量条；需要处理的问题（没开辅助功能、Ulanzi Studio 在运行）直接给按钮。
private struct DeviceStatusCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let accent = model.theme.accent
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(model.device.link.color).frame(width: 7, height: 7)
                Text(model.device.link.text).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if let percent = model.device.percent {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.device.charging ? "电量 \(percent)% · 充电中" : "电量 \(percent)%")
                        .font(.system(size: 13, weight: .semibold))
                    LevelBar(fraction: Double(percent) / 100)
                }
            }
            if !model.accessibilityTrusted {
                Text("辅助功能未允许，按键发不出去").font(.system(size: 12)).foregroundStyle(.orange)
                Button("开启辅助功能") { model.openAccessibilitySettings() }
                    .buttonStyle(PillButtonStyle(kind: .accent(accent), fill: true, height: 36))
            } else if model.ulanziRunning {
                Text("Ulanzi Studio 正在运行，可能抢按键").font(.system(size: 12)).foregroundStyle(.orange)
                Button("退出 Ulanzi Studio") { model.quitUlanzi() }
                    .buttonStyle(PillButtonStyle(kind: .accent(accent), fill: true, height: 36))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, radius: 14)
    }
}

extension DeviceSnapshot.Link {
    var text: String {
        switch self {
        case .connected: return "AU05 已连接"
        case .connecting: return "正在连接 AU05…"
        case .disconnected: return "AU05 未连接"
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

private struct HomePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Vibe Coding，用说的")
                    .font(.system(size: 44, weight: .heavy))
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 28) {
                        ShortcutsCard(model: model)
                        RecentSection(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HomeSideColumn(model: model)
                        .frame(width: 224)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 50)
            .padding(.bottom, 80)
        }
    }
}

/// AU05 上每个动作现在做什么，一行一个；点一行跳到按键页改它。
private struct ShortcutsCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let accent = model.theme.accent
        VStack(spacing: 0) {
            ForEach(Array(KeyFunction.allCases.enumerated()), id: \.offset) { index, function in
                if index > 0 {
                    RowDivider().padding(.horizontal, 16)
                }
                let summary = function.summary(model.config)
                let lit = model.flash?.control == function.control
                Button {
                    model.open(function.control)
                } label: {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.action).font(.system(size: 16, weight: .bold))
                            Text(summary.detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 270, alignment: .leading)
                        HStack(spacing: 14) {
                            ForEach(Array(summary.combos.enumerated()), id: \.offset) { _, combo in
                                ComboKeycaps(combo: combo)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent.opacity(lit ? 0.12 : 0))
                    )
                }
                .buttonStyle(RowButtonStyle())
                .animation(.easeOut(duration: 0.2), value: lit)
            }
        }
        .card(padding: 6)
    }
}

/// 最近操作：AU05 上按过什么、做了什么。
private struct RecentSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("最近操作")
            if model.recentActions.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "hand.tap").font(.system(size: 20)).foregroundStyle(.secondary)
                    Note("按一下 AU05 上的键，这里会显示它做了什么。")
                    Spacer()
                }
                .card(padding: 20)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                        ForEach(model.recentActions) { action in
                            RecentTile(action: action, now: context.date, accent: model.theme.accent)
                        }
                    }
                }
            }
        }
    }
}

private struct RecentTile: View {
    let action: DeviceAction
    let now: Date
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: action.control.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(accent.opacity(0.14)))
                Spacer()
                Text(Self.relative(action.date, now: now)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(action.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
            if let combo = action.combo {
                ComboKeycaps(combo: combo, small: true)
            } else {
                Text(action.control.title).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16, radius: 18)
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 10 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }
}

/// 首页右边一列：设备数字、设备卡、冲突提醒、版本。
private struct HomeSideColumn: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let theme = model.theme
        let device = model.device
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 18) {
                stat(device.link == .connected ? "dot.radiowaves.left.and.right" : "wifi.slash",
                     device.link == .connected ? "已连接" : device.link == .connecting ? "连接中" : "未连接", nil)
                stat(batteryIcon, device.percent.map(String.init) ?? "—", "% 电量")
                stat("bolt", device.millivolts.map { String(format: "%.2f", Double($0) / 1000) } ?? "—", "V 电压")
                stat("hand.tap", "\(model.actionCount)", "次操作")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 20)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    let art = DeviceArt.of(theme)
                    DeviceArtView(art: art, accent: theme.accent)
                        .frame(width: 100 * art.aspect, height: 100)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AU05 Vibe Key").font(.system(size: 15, weight: .bold))
                        Text(theme.title).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("USB 接收器").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Button("设备详情") { model.section = .device }
                    .buttonStyle(PillButtonStyle(kind: .inverse, fill: true))
            }
            .card(padding: 18)

            if model.ulanziRunning {
                UlanziWarning(model: model)
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text("版本 \(model.versionText)").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("查看日志") { model.revealLog() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .underline()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 8)
        }
    }

    private var batteryIcon: String {
        if model.device.charging { return "battery.100percent.bolt" }
        guard let percent = model.device.percent else { return "battery.0percent" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func stat(_ icon: String, _ value: String, _ unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(value).font(.system(size: 22, weight: .bold))
            if let unit {
                Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Ulanzi Studio 和 Vibe Key 同时运行时的提醒卡。
private struct UlanziWarning: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ulanzi Studio 正在运行", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
            Note("它和 Vibe Key 会同时接管 AU05，同一个键可能被处理两次。")
            Button("退出 Ulanzi Studio") { model.quitUlanzi() }
                .buttonStyle(PillButtonStyle(kind: .accent(.orange), fill: true, height: 34))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18, fill: Color.orange.opacity(0.12))
    }
}

// MARK: 设备

private struct DevicePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let theme = model.theme
        let art = DeviceArt.of(theme)
        let device = model.device
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(title: "设备", subtitle: "Vibe Key 每秒向 AU05 发一次心跳；一直收到心跳，AU05 就把按键交给 Vibe Key 处理。")
                HStack(alignment: .top, spacing: 22) {
                    DeviceArtView(art: art, accent: theme.accent)
                        .frame(width: 430 * art.aspect, height: 430)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 28)
                        .card(padding: 0)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 10) {
                                Text("AU05 Vibe Key").font(.system(size: 24, weight: .bold))
                                Badge(text: theme.title, color: theme.accent)
                                Spacer()
                                HStack(spacing: 6) {
                                    Circle().fill(device.link.color).frame(width: 8, height: 8)
                                    Text(device.link.text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                }
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(device.percent.map(String.init) ?? "—")
                                    .font(.system(size: 52, weight: .heavy))
                                Text("%").font(.system(size: 20, weight: .bold)).foregroundStyle(.secondary)
                                Spacer()
                                Text(device.charging ? "充电中" : "电池供电")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            LevelBar(fraction: Double(device.percent ?? 0) / 100, tint: theme.accent, height: 6)
                        }
                        .card(padding: 22)

                        VStack(spacing: 0) {
                            SettingRow(title: "电压") { value(device.millivolts.map { String(format: "%.2f V", Double($0) / 1000) } ?? "—") }
                            RowDivider()
                            SettingRow(title: "连接方式") { value("USB 接收器") }
                            RowDivider()
                            SettingRow(title: "心跳", detail: "约 3 秒收不到心跳，AU05 会变回普通键盘，语音键改发 ⌘H。") { value("每秒一次") }
                            RowDivider()
                            SettingRow(title: "外观") {
                                Button(theme.title) { model.section = .general }
                                    .buttonStyle(PillButtonStyle(kind: .subtle, height: 30))
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 4)
                        .card(padding: 0)

                        if model.ulanziRunning {
                            UlanziWarning(model: model)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 46)
            .padding(.bottom, 80)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
    }
}

// MARK: 设置（外观、启动、权限、关于）

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let accent = model.theme.accent
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(title: "设置")
                group("外观") {
                    HStack(spacing: 14) {
                        ForEach(DeviceTheme.allCases) { item in
                            ThemeOption(theme: item, selected: model.config.deviceTheme == item) {
                                model.config.deviceTheme = item
                            }
                        }
                    }
                    .padding(.vertical, 18)
                }
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
                    RowDivider()
                    SettingRow(title: "输入监控（仅调试）",
                               detail: "只在开发调试时用来记录按键来源，正式版不需要，也不会申请。") {
                        permission(model.inputMonitoringAllowed, kind: .subtle, open: model.openInputMonitoringSettings)
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
            .frame(maxWidth: 700, alignment: .leading)
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

/// 外观主题的一个选项：设备缩略图、配色色块和名字，选中时描强调色并打勾。
private struct ThemeOption: View {
    let theme: DeviceTheme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        let art = DeviceArt.of(theme)
        Button(action: choose) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised.opacity(0.6))
                    DeviceArtView(art: art, accent: theme.accent)
                        .frame(width: 130 * art.aspect, height: 130)
                }
                .frame(height: 150)
                HStack(spacing: 8) {
                    Circle().fill(theme.accent).frame(width: 12, height: 12)
                    Text(theme.title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? theme.accent : Color.secondary)
                }
            }
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? theme.accent : Palette.hairline, lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
