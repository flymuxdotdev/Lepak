import AppKit
import Darwin
import Foundation
import LepakKit

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let session = DeviceSession()
    /// AI Passport（社区固件）走蓝牙，和 AU05 同时工作。
    private let passport = PassportLink()
    private var passportState = PassportLinkState.searching
    private var passportBattery: PassportBattery?
    private var configObserver: NSObjectProtocol?
    /// 调试：看 AU05 自己的键盘口有没有发键（比如长按时冒出来的 Command+H）。
    private let keyboard = KeyboardMonitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var status: PowerStatus?
    private var timer: Timer?
    private var heartbeat: Timer?
    private var appNapGuard: NSObjectProtocol?
    private var loggedPercent: Int?
    private var loggedCharging: Bool?
    private var recent = "还没有按键"
    private var linkLost = false
    private var updatingMenu = false
    private let settings = SettingsModel()
    private lazy var settingsWindow = SettingsWindowController(model: settings)
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Lepak.log")
        try? Data().write(to: logURL)
        if let button = statusItem.button {
            // 菜单栏图标：六根竖条（BrandIcon），13pt 高、比侧栏 Logo 细一点，模板图，系统按浅色 / 深色菜单栏自动着色。
            button.image = BrandIcon.menuBarImage()
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        session.onStatus = { [weak self] status in
            Task { @MainActor in
                if status == nil {
                    FunctionKey.reset()
                    DeviceKeys.releaseAll()
                    self?.linkLost = true
                } else {
                    self?.linkLost = false
                }
                self?.status = status
                self?.show(status)
                self?.settings.update(status: status, linkLost: self?.linkLost ?? false)
            }
        }
        session.onVendorKey = { [weak self] event in
            // 语音键（物理 0）也在 DeviceKeys 里：默认交给 FunctionKey，开了长按 / 双击时走手势判断。
            let note = DeviceKeys.handle(physicalIndex: event.physicalIndex, status: event.status)
            Task { @MainActor in
                var line = "配置口按键 序号 \(event.index) 状态 \(event.status) 物理 \(event.physicalIndex)"
                if let note {
                    line += " " + note
                }
                self?.recent = line
                self?.log(line)
            }
        }
        session.onVendorPacket = { [weak self] line in
            Task { @MainActor in
                self?.recent = line
                self?.log(line)
            }
        }
        session.onNote = { [weak self] line in
            Task { @MainActor in
                self?.log(line)
            }
        }
        DeviceKeys.setActionHandler { [weak self] device, control, title, combo in
            Task { @MainActor in
                self?.settings.record(device, control, title, combo)
            }
        }
        startPassport()
        Usage.shared.onChange { [weak self] data in
            Task { @MainActor in
                self?.settings.usage = Usage.summarize(data)
            }
        }
        FunctionKey.requestTrust()
        FunctionKey.reset()
        session.start()
        let echo = KeyEcho.start()
        log(FunctionKey.isTrusted ? "只打开配置口，语音键发送 Fn" : "只打开配置口，辅助功能未允许")
        log(echo ? "系统按键监听已打开" : "系统按键监听未建立")
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
            log("输入监控未允许：系统按键监听和 AU05 键盘口都看不到按键")
        }
        keyboard.onNote = { [weak self] line in
            Task { @MainActor in
                self?.log(line)
            }
        }
        keyboard.onInputMonitoring = { [weak self] allowed in
            Task { @MainActor in
                self?.log(allowed ? "AU05 键盘口监听已打开" : "AU05 键盘口监听被拒绝（输入监控）")
            }
        }
        keyboard.start()
        // 心跳要跟官方 Ulanzi Studio 一样每 1 秒一次。AU05 大约 3 秒收不到心跳，
        // 就认为电脑上没有配套程序，这时按语音键会从它自己的键盘口发出 Win+H
        // （Windows 的语音输入快捷键），在 Mac 上就是 Command+H：当前窗口被隐藏，
        // Typeless 也会因为多出来的按键取消录音。
        // 菜单打开时也要继续发，所以加到 common 模式；并且关掉 App Nap，免得后台计时器被拖慢。
        appNapGuard = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "AU05 心跳"
        )
        let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.session.keepAlive()
            }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        self.heartbeat = heartbeat
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.session.refresh()
            }
        }
        SettingsWindowController.installMainMenu(openSettings: #selector(openSettings), target: self)
        watchWorkspace()
    }

    /// 日常稳定性：睡眠唤醒后立刻补发心跳（等下一次计时器可能已经超过 AU05 的 3 秒），
    /// 并留意 Ulanzi Studio 的启动和退出——它和本程序同时运行会抢 AU05。
    private func watchWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.session.keepAlive()
                self?.session.refresh()
                self?.log("唤醒后已补发心跳")
            }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SettingsModel.ulanziBundleID else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.settings.refreshUlanzi()
                    self.log(self.settings.ulanziRunning ? "Ulanzi Studio 已启动，可能和 Lepak 抢 AU05" : "Ulanzi Studio 已退出")
                }
            })
        }
        if settings.ulanziRunning {
            log("Ulanzi Studio 正在运行，可能和 Lepak 抢 AU05")
        }
    }

    /// 菜单栏只显示图标（电量在菜单里看），没连上时图标变灰。
    private func setConnected(_ connected: Bool) {
        statusItem.button?.appearsDisabled = !connected
    }

    private func show(_ status: PowerStatus?) {
        if let status {
            setConnected(true)
            if loggedPercent != status.percent || loggedCharging != status.charging {
                loggedPercent = status.percent
                loggedCharging = status.charging
                log("状态 \(status.percent)% \(status.millivolts) mV \(status.charging ? "充电" : "未充电")")
            }
        } else {
            setConnected(false)
            if loggedPercent != nil || loggedCharging != nil {
                loggedPercent = nil
                loggedCharging = nil
                log("状态 未连接")
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !updatingMenu else { return }
        updatingMenu = true
        rebuildMenu()
        updatingMenu = false
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        settings.refreshUlanzi()
        if let status {
            menu.addItem(title: "AU05 已连接 · 电量 \(status.percent)%\(status.charging ? " · 充电中" : "")", action: nil)
        } else {
            menu.addItem(title: linkLost ? "AU05 未连接" : "正在连接 AU05…", action: nil)
        }
        if case .online = passportState {
            let percent = passportBattery?.percent.map { " · 电量 \($0)%" } ?? ""
            menu.addItem(title: "AI Passport 已连接\(percent)\(passportBattery?.charging == true ? " · 充电中" : "")", action: nil)
        }
        if !FunctionKey.isTrusted {
            let item = menu.addItem(withTitle: "⚠️ 辅助功能未允许，按键发不出去…", action: #selector(openPermissions), keyEquivalent: "")
            item.target = self
        }
        if settings.ulanziRunning {
            let item = menu.addItem(withTitle: "⚠️ Ulanzi Studio 正在运行，可能冲突…", action: #selector(openDevicePage), keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        let debugMenu = NSMenu()
        debugMenu.addItem(title: "最近：\(recent)", action: nil)
        let refresh = debugMenu.addItem(withTitle: "刷新电量", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        let debug = menu.addItem(withTitle: "调试", action: nil, keyEquivalent: "")
        debug.submenu = debugMenu
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Lepak", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openPermissions() {
        settingsWindow.show(section: .general)
    }

    @objc private func openDevicePage() {
        // Ulanzi Studio 冲突的提醒条在 AU05 页面顶上。
        settingsWindow.show(section: .device(.au05))
    }

    private func log(_ line: String) {
        DebugLog.write(line)
    }

    @objc private func refresh() {
        session.refresh()
        rebuildMenu()
    }

    // MARK: AI Passport

    private func startPassport() {
        passport.onState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.passportState = state
                if case .online = state {} else { self.passportBattery = nil }
                self.showPassport()
            }
        }
        passport.onBattery = { [weak self] battery in
            Task { @MainActor in
                self?.passportBattery = battery
                self?.showPassport()
            }
        }
        passport.onButton = { [weak self] button, pressed in
            let key: GestureKey = switch button {
            case .ok: .voice
            case .up: .confirm
            case .down: .cancel
            }
            let note = DeviceKeys.handle(passportKey: key, pressed: pressed)
            Task { @MainActor in
                var line = "AI Passport 按键 \(button.rawValue) \(pressed ? "按下" : "松开")"
                if let note { line += " " + note }
                self?.recent = line
                self?.log(line)
            }
        }
        passport.onNote = { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
        updatePassportKeys()
        // 改了按键设置，屏幕上三个键旁边的提示马上跟着变。
        configObserver = NotificationCenter.default.addObserver(forName: Config.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePassportKeys() }
        }
        passport.start()
    }

    private func updatePassportKeys() {
        let keys = Config.current.passport
        passport.setKeyIcons([.ok: passportIcon(keys.voice), .up: passportIcon(keys.confirm), .down: passportIcon(keys.cancel)])
    }

    private func showPassport() {
        var snapshot = DeviceSnapshot(link: .disconnected)
        switch passportState {
        case .online:
            snapshot.link = .connected
            snapshot.percent = passportBattery?.percent
            snapshot.millivolts = passportBattery?.millivolts
            snapshot.charging = passportBattery?.charging ?? false
        case .connecting:
            snapshot.link = .connecting
        case .searching:
            break
        case .bluetoothOff:
            snapshot.note = "蓝牙已关闭"
        case .unauthorized:
            snapshot.note = "没有允许 Lepak 使用蓝牙"
        case .unsupported:
            snapshot.note = "这台 Mac 不支持低功耗蓝牙"
        }
        if snapshot != settings.passport {
            settings.updatePassport(snapshot)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FunctionKey.reset()
        passport.stop()
        Usage.shared.flush()
    }

    @objc private func quit() {
        FunctionKey.reset()
        NSApp.terminate(nil)
    }
}

/// AI Passport 屏幕上、三个键旁边的提示图标：按这个键单击发什么来选（协议里的固定图标 id），认不出来的就不显示。
private func passportIcon(_ combo: KeyCombo) -> String {
    if combo.isNone { return "" }
    if combo == .fnKey { return "mic" }
    let modifiers = (combo.command, combo.shift, combo.option, combo.control, combo.fn)
    let plain = (false, false, false, false, false)
    switch combo.keyCode {
    case 36:   // 回车
        if modifiers == plain || modifiers == (false, true, false, false, false) { return "enter" }
        if modifiers == (true, false, false, false, false) { return "send" }
    case 53 where modifiers == plain: return "esc"
    case 51 where modifiers == plain: return "bksp"
    case 117 where modifiers == plain: return "del"
    case 48:   // Tab
        if modifiers == plain { return "tab" }
        if modifiers == (false, true, false, false, false) { return "stab" }
    case 6 where modifiers == (true, false, false, false, false): return "undo"
    case 56 where modifiers == (false, false, false, false, true): return "translate"   // Fn + 左 Shift：Typeless 翻译
    default: break
    }
    return ""
}

private extension NSMenu {
    @discardableResult
    func addItem(title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        addItem(item)
        return item
    }
}

// 开发用：离屏画出设置界面后退出，不建菜单栏图标、不连设备。
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), flag + 1 < CommandLine.arguments.count {
    NSApplication.shared.setActivationPolicy(.accessory)
    SettingsWindowController.snapshotAll(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(0)
}

let app = MenuBarApp()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = app
application.run()
