import AppKit
import ApplicationServices
import AuthenticationServices
import ServiceManagement
import SwiftUI
import LepakKit

/// Lepak 支持的硬件型号。以后加遥控器等别的设备，在这里加一项，侧栏「我的设备」就会多一行。
/// 几台设备可以同时连着、同时工作，没有「当前设备」这回事；侧栏点哪台，只是在看哪台的设置。
enum DeviceKind: String, CaseIterable, Identifiable, Sendable {
    case au05
    /// FoloToy AI Passport，刷了社区固件（InputBetter / FoloVibe Key）后通过蓝牙连接，见 `PassportLink`。
    case passport

    var id: String { rawValue }

    var name: String {
        switch self {
        case .au05: return "Ulanzi AU05"
        case .passport: return "AI Passport"
        }
    }

    var systemImage: String {
        switch self {
        case .au05: return "mic.and.signal.meter"
        case .passport: return "rectangle.portrait"
        }
    }

    /// 使用次数里记的设备名（见 `Usage`）。
    var usageName: String {
        switch self {
        case .au05: return Usage.au05
        case .passport: return Usage.passport
        }
    }

    /// 按键页上能设置的控件。
    var controls: [MappingControl] {
        switch self {
        case .au05: return MappingControl.allCases
        case .passport: return [.confirm, .voice, .cancel]   // 从上到下：上键、OK 键、下键
        }
    }

    init?(usageName: String) {
        guard let kind = Self.allCases.first(where: { $0.usageName == usageName }) else { return nil }
        self = kind
    }
}

/// 设置窗口的几页。侧栏：首页、「我的设备」下每台设备一页、添加设备；「设置」（启动、权限、关于）是侧栏底部的齿轮。
enum SettingsSection: Hashable, Identifiable {
    case home
    case device(DeviceKind)
    case addDevice
    case general

    static let allCases: [SettingsSection] = [.home] + DeviceKind.allCases.map { .device($0) } + [.addDevice, .general]

    var id: String { name }

    /// 英文短名，开发截图的文件名用。
    var name: String {
        switch self {
        case .home: return "home"
        case .device(let kind): return "device-\(kind.rawValue)"
        case .addDevice: return "add-device"
        case .general: return "general"
        }
    }
}

/// 按键处理刚做过的一件事：哪个控件、做了什么、发了什么键。
struct DeviceAction: Identifiable, Equatable {
    let id = UUID()
    let device: DeviceKind
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
    /// 没连上时补一句原因，比如「蓝牙已关闭」；nil 就只显示连接状态。
    var note: String?
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
    @Published var section: SettingsSection = .home {
        didSet {
            // 换页时收起弹出的设置：几台设备的按键页共用同一份界面状态。
            if section != oldValue { mappingUI.closeEditor() }
        }
    }
    /// 设置窗口是否全屏。全屏时没有红黄绿按钮，侧栏顶上不用再给它们留位置。
    @Published var isFullScreen = false
    /// 用 Apple 登录的账号（见 `AppleAccount`）；nil 是没登录。侧栏底部按它显示头像、邮箱和状态。
    @Published var account: Account?
    /// 登录失败时显示在「设置 → 账号」里的话。
    @Published private(set) var accountMessage: String?
    private var revokedObserver: NSObjectProtocol?
    /// 最近几次操作（最新的在前）。
    @Published private(set) var recentActions: [DeviceAction] = []
    /// 本次启动以来 AU05 触发过几次操作。
    @Published private(set) var actionCount = 0
    /// 首页「洞察」：历史使用次数，按天、按设备加总。
    @Published var usage = Usage.summarize(Usage.shared.snapshot)
    /// 刚触发的那一次：卡片和按键闪一下，并弹出「已发送」提示，2 秒后消失。
    @Published private(set) var flash: DeviceAction?
    /// 按键映射页的选中和编辑状态。
    let mappingUI = MappingUIState()
    @Published private(set) var device = DeviceSnapshot()
    @Published private(set) var passport = DeviceSnapshot(link: .disconnected)
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoringAllowed = CGPreflightListenEventAccess()
    @Published private(set) var ulanziRunning = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemMessage: String?

    init() {
        config = Config.current
        account = AppleAccount.load()
        refreshUlanzi()
        refreshLoginItem()
        // 用户在系统设置里撤销了 Lepak 的 Apple 登录：本机也登出。
        revokedObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.signOut() }
        }
        refreshAccount()
    }

    // MARK: 账号

    /// 「用 Apple 登录」按钮的结果。
    func completeSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let signedIn = AppleAccount.account(from: authorization, previous: account) else {
                accountMessage = "登录没有成功：Apple 没有返回账号信息。"
                return
            }
            account = signedIn
            AppleAccount.save(signedIn)
            accountMessage = nil
        case .failure(let error):
            accountMessage = AppleAccount.message(for: error)
        }
    }

    /// 只是让本机忘掉这个账号；要彻底取消授权，用户得去「系统设置 → Apple 账户 → 用 Apple 登录」。
    func signOut() {
        account = nil
        AppleAccount.save(nil)
        accountMessage = nil
    }

    /// 打开设置窗口时问一下 Apple，授权是不是被撤销了。
    func refreshAccount() {
        guard let id = account?.appleUserID else { return }
        AppleAccount.checkRevoked(id) { [weak self] revoked in
            guard revoked else { return }
            Task { @MainActor in
                guard let self, self.account?.appleUserID == id else { return }
                self.signOut()
            }
        }
    }

    var theme: DeviceTheme { config.deviceTheme }

    func record(_ device: DeviceKind, _ control: MappingControl, _ title: String, _ combo: KeyCombo?) {
        let action = DeviceAction(device: device, control: control, title: title, combo: combo, date: Date())
        // 同一轮转动会连续报告，只保留第一条，免得刷屏。
        if let last = recentActions.first, last.device == device, last.control == control, last.title == title,
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

    /// 跳到 AU05 的页面，选中某个控件。
    func open(_ control: MappingControl) {
        mappingUI.select(control)
        section = .device(.au05)
    }

    /// 开发截图用：假装 Ulanzi Studio 正在运行，看提醒条放不放得下。
    func showSampleUlanziWarning(_ running: Bool) {
        ulanziRunning = running
    }

    /// 某台设备的连接和电量。
    func snapshot(of kind: DeviceKind) -> DeviceSnapshot {
        switch kind {
        case .au05: return device
        case .passport: return passport
        }
    }

    func updatePassport(_ snapshot: DeviceSnapshot) {
        passport = snapshot
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
        passport = DeviceSnapshot(link: .connected, percent: 87, millivolts: 4012, charging: false)
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
            ? "还需要在「系统设置 → 通用 → 登录项与扩展」里允许 Lepak。"
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

    /// 这台设备的按键设置是否都是默认值（AU05 的外观主题不算）。
    func keysAreDefault(_ kind: DeviceKind) -> Bool {
        switch kind {
        case .au05:
            var defaults = AppConfig()
            defaults.deviceTheme = config.deviceTheme
            defaults.passport = config.passport
            return config == defaults
        case .passport:
            return config.passport == PassportKeys()
        }
    }

    /// 这台设备的按键恢复默认，别的设备和 AU05 的外观主题保持不变。
    func resetKeys(_ kind: DeviceKind) {
        switch kind {
        case .au05:
            var defaults = AppConfig()
            defaults.deviceTheme = config.deviceTheme
            defaults.passport = config.passport
            config = defaults
        case .passport:
            config.passport = PassportKeys()
        }
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
