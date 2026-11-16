import AppKit
import ApplicationServices
import AuthenticationServices
import ServiceManagement
import SwiftUI
import LepakKit

/// Lepak 支持的硬件型号。以后加遥控器等别的设备，在这里加一项，「添加设备」弹窗里就会多一张卡。
/// 侧栏「我的设备」只列用户添加过的（`AppConfig.devices`）。
/// 几台设备可以同时连着、同时工作，没有「当前设备」这回事；侧栏点哪台，只是在看哪台的设置。
enum DeviceKind: String, CaseIterable, Codable, Identifiable, Sendable {
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
        case .passport: return [.confirm, .cancel, .voice]   // 和机身侧键一样从上到下：上键、下键、OK
        }
    }

    /// 「添加设备」弹窗里型号下面的一句话。
    var connectionHint: String {
        switch self {
        case .au05: return "插上 USB 接收器就能用"
        case .passport: return "蓝牙连接，需要先刷社区固件"
        }
    }

    init?(usageName: String) {
        guard let kind = Self.allCases.first(where: { $0.usageName == usageName }) else { return nil }
        self = kind
    }
}

/// 设置窗口的几页。侧栏：首页、「我的设备」下每台添加过的设备一页；「设置」（启动、权限、关于）是侧栏底部的齿轮。
/// 「添加设备」不是一页，是弹窗（见 `AddDeviceStep`）。
enum SettingsSection: Hashable, Identifiable {
    case home
    case device(DeviceKind)
    case general

    /// 开发截图用：所有可能的页面。
    static let allCases: [SettingsSection] = [.home] + DeviceKind.allCases.map { .device($0) } + [.general]

    var id: String { name }

    /// 英文短名，开发截图的文件名用。
    var name: String {
        switch self {
        case .home: return "home"
        case .device(let kind): return "device-\(kind.rawValue)"
        case .general: return "general"
        }
    }
}

/// 「添加设备」弹窗的两步：先选型号，再看着连接状态把它连上，点「完成」才加进「我的设备」。
enum AddDeviceStep: Equatable {
    case choose
    /// 第二步：这一步里 Lepak 已经开始连这台设备（实时显示连上没有），取消就断开。
    case connect(DeviceKind)
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
            activeDevicesMayHaveChanged()
        }
    }
    @Published var section: SettingsSection = .home {
        didSet {
            // 换页时收起弹出的设置：几台设备的按键页共用同一份界面状态。
            if section != oldValue { mappingUI.closeEditor() }
        }
    }
    /// 「添加设备」弹窗走到哪一步；nil 是没打开。
    @Published var addDeviceStep: AddDeviceStep? {
        didSet { activeDevicesMayHaveChanged() }
    }
    /// 弹窗第二步里的「名称」输入框，默认是型号名（以前起过名字就是那个名字）。
    @Published var newDeviceName = ""
    /// 等用户确认要不要移除的设备（弹出确认框）；nil 是没在问。
    @Published var removingDevice: DeviceKind?
    /// 正在重命名的设备（弹出带输入框的对话框）；nil 是没在改。
    @Published var renamingDevice: DeviceKind?
    @Published var renameText = ""
    /// 要连接的设备变了（添加、移除，或者弹窗第二步开始 / 停止试连）。菜单栏程序据此打开或断开连接。
    var onActiveDevicesChange: ((Set<DeviceKind>) -> Void)?
    private var lastActiveDevices: Set<DeviceKind> = []
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
    /// Lepak 麦克风（AI Passport 当麦克风用）的状态。
    @Published private(set) var passportMic = PassportMic.Status.notInstalled
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var ulanziRunning = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemMessage: String?

    init() {
        config = Config.current
        lastActiveDevices = activeDevices
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

    // MARK: 我的设备

    /// 现在该连着的设备：添加过的，加上弹窗第二步正在试连的那台。
    var activeDevices: Set<DeviceKind> {
        var active = Set(config.devices)
        if case .connect(let kind) = addDeviceStep { active.insert(kind) }
        return active
    }

    private func activeDevicesMayHaveChanged() {
        let active = activeDevices
        guard active != lastActiveDevices else { return }
        lastActiveDevices = active
        onActiveDevicesChange?(active)
    }

    func isAdded(_ kind: DeviceKind) -> Bool {
        config.devices.contains(kind)
    }

    /// 名字最多这么多个字，侧栏放得下。
    static let maxNameLength = 20

    /// 侧栏、设备页、菜单栏上显示的名字：用户起的，没起就是型号名。
    func displayName(_ kind: DeviceKind) -> String {
        config.deviceNames[kind.rawValue] ?? kind.name
    }

    /// 去掉首尾空白、截到 20 个字；留空或者和型号名一样就不单独存（显示型号名）。
    private static func store(_ name: String, for kind: DeviceKind, in config: inout AppConfig) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        config.deviceNames[kind.rawValue] = trimmed.isEmpty || trimmed == kind.name ? nil : trimmed
    }

    /// 弹出重命名对话框，输入框里先放现在的名字。
    func beginRename(_ kind: DeviceKind) {
        renameText = displayName(kind)
        renamingDevice = kind
    }

    func rename(_ kind: DeviceKind, to name: String) {
        renamingDevice = nil
        Self.store(name, for: kind, in: &config)
    }

    /// 打开「添加设备」弹窗的第一步（选型号）。
    func beginAddDevice() {
        mappingUI.closeEditor()
        addDeviceStep = .choose
    }

    /// 弹窗第二步：开始连这台设备，等用户看到连上了再点「完成」。
    func chooseDevice(_ kind: DeviceKind) {
        newDeviceName = displayName(kind)
        addDeviceStep = .connect(kind)
    }

    /// 弹窗里点「完成」：加进「我的设备」，关掉弹窗，打开它的设置页。
    /// 先加进列表再关弹窗，连接不会因为离开第二步而断一下。
    func finishAddDevice() {
        guard case .connect(let kind) = addDeviceStep else { return }
        var next = config
        Self.store(newDeviceName, for: kind, in: &next)
        if !next.devices.contains(kind) { next.devices.append(kind) }
        config = next
        addDeviceStep = nil
        section = .device(kind)
    }

    /// 关掉弹窗。第二步里试连的设备（还没点「完成」）随之断开。
    func cancelAddDevice() {
        addDeviceStep = nil
    }

    /// 从「我的设备」里拿掉：断开连接、不再处理它的按键。按键设置和名字保留，再添加回来还在（用户 2026-11-16 定的）。
    func removeDevice(_ kind: DeviceKind) {
        removingDevice = nil
        config.devices.removeAll { $0 == kind }
        if section == .device(kind) { section = .home }
    }

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

    func updatePassportMic(_ status: PassportMic.Status) {
        passportMic = status
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

    /// 这台设备的按键设置是否都是默认值（AU05 的外观主题、设备列表和名字不算）。
    func keysAreDefault(_ kind: DeviceKind) -> Bool {
        switch kind {
        case .au05:
            var defaults = AppConfig()
            defaults.devices = config.devices
            defaults.deviceNames = config.deviceNames
            defaults.deviceTheme = config.deviceTheme
            defaults.passport = config.passport
            return config == defaults
        case .passport:
            return config.passport == PassportKeys()
        }
    }

    /// 这台设备的按键恢复默认，别的设备、设备列表和名字、AU05 的外观主题保持不变。
    func resetKeys(_ kind: DeviceKind) {
        switch kind {
        case .au05:
            var defaults = AppConfig()
            defaults.devices = config.devices
            defaults.deviceNames = config.deviceNames
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
