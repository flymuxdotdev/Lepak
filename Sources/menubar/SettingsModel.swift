import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import VibeKeyKit

/// 设置窗口的几页。首页 / 按键 / 设备在左侧栏的导航里；「设置」（启动、权限、外观）是侧栏底部的齿轮。
enum SettingsSection: String, CaseIterable, Identifiable {
    case home, keys, device, general

    var id: String { rawValue }

    /// 侧栏导航里列出的几页。
    static let navigation: [SettingsSection] = [.home, .keys, .device]

    var title: String {
        switch self {
        case .home: return "首页"
        case .keys: return "按键"
        case .device: return "设备"
        case .general: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .keys: return "keyboard"
        case .device: return "dot.radiowaves.left.and.right"
        case .general: return "gearshape"
        }
    }
}

/// 按键处理刚做过的一件事：哪个控件、做了什么、发了什么键。
struct DeviceAction: Identifiable, Equatable {
    let id = UUID()
    let control: MappingControl
    let title: String
    let combo: KeyCombo?
    let date: Date
}

struct DeviceSnapshot: Equatable {
    enum Link { case connecting, connected, disconnected }
    var link: Link = .connecting
    var percent: Int?
    var millivolts: Int?
    var charging = false
}

/// 设置窗口和菜单共用的状态。只在主线程使用。
@MainActor
final class SettingsModel: ObservableObject {
    nonisolated static let ulanziBundleID = "ulanzi.UlanziStudio"

    /// 改动立即写进 `Config`（按键处理马上用上）并保存。
    @Published var config: AppConfig {
        didSet {
            if config != oldValue { Config.update(config) }
        }
    }
    @Published var section: SettingsSection = .home
    /// 最近几次操作（最新的在前）。
    @Published private(set) var recentActions: [DeviceAction] = []
    /// 本次启动以来 AU05 触发过几次操作。
    @Published private(set) var actionCount = 0
    /// 刚触发的那一次：卡片和按键闪一下，并弹出「已发送」提示，2 秒后消失。
    @Published private(set) var flash: DeviceAction?
    /// 按键映射页的选中和编辑状态。
    let mappingUI = MappingUIState()
    @Published private(set) var device = DeviceSnapshot()
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoringAllowed = CGPreflightListenEventAccess()
    @Published private(set) var ulanziRunning = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemMessage: String?

    init() {
        config = Config.current
        refreshUlanzi()
        refreshLoginItem()
    }

    var theme: DeviceTheme { config.deviceTheme }

    func record(_ control: MappingControl, _ title: String, _ combo: KeyCombo?) {
        let action = DeviceAction(control: control, title: title, combo: combo, date: Date())
        // 同一轮转动会连续报告，只保留第一条，免得刷屏。
        if let last = recentActions.first, last.control == control, last.title == title,
           action.date.timeIntervalSince(last.date) < 1 {
            return
        }
        actionCount += 1
        recentActions.insert(action, at: 0)
        if recentActions.count > 6 { recentActions.removeLast(recentActions.count - 6) }
        flash = action
        let id = action.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.flash?.id == id { self?.flash = nil }
        }
    }

    /// 跳到按键页，选中某个控件。
    func open(_ control: MappingControl) {
        mappingUI.select(control)
        section = .keys
    }

    var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version)（\($0)）" } ?? version
    }

    func update(status: PowerStatus?, linkLost: Bool) {
        if let status {
            device = DeviceSnapshot(link: .connected, percent: status.percent,
                                    millivolts: status.millivolts, charging: status.charging)
        } else {
            device = DeviceSnapshot(link: linkLost ? .disconnected : .connecting)
        }
    }

    /// 开发用截图时显示一份示例设备状态。
    func showSampleDevice() {
        device = DeviceSnapshot(link: .connected, percent: 50, millivolts: 3670, charging: false)
    }

    func refreshPermissions() {
        accessibilityTrusted = AXIsProcessTrusted()
        inputMonitoringAllowed = CGPreflightListenEventAccess()
    }

    func refreshUlanzi() {
        ulanziRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.ulanziBundleID }
    }

    func quitUlanzi() {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == Self.ulanziBundleID {
            app.terminate()
        }
    }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginItemMessage = status == .requiresApproval
            ? "还需要在「系统设置 → 通用 → 登录项与扩展」里允许 Vibe Key。"
            : nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginItemMessage = "设置失败：\(error.localizedDescription)"
        }
    }

    /// 按键相关的设置是否都是默认值（外观主题不算）。
    var keysAreDefault: Bool {
        var defaults = AppConfig()
        defaults.deviceTheme = config.deviceTheme
        return config == defaults
    }

    /// 按键恢复默认，外观主题保持不变。
    func resetKeys() {
        var defaults = AppConfig()
        defaults.deviceTheme = config.deviceTheme
        config = defaults
    }

    func openAccessibilitySettings() {
        FunctionKey.requestTrust()
        openPrivacyPane("Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([DebugLog.url])
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
