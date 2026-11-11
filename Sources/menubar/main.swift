import AppKit
import Darwin
import Foundation
import VibeKeyKit

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let session = DeviceSession()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VibeKey.log")
        try? Data().write(to: logURL)
        if let button = statusItem.button {
            // 菜单栏图标：模板图，系统会按浅色/深色菜单栏自动着色。打包时从 Support 复制进 Resources。
            if let icon = NSImage(named: "MenuBarIcon") {
                icon.isTemplate = true
                // 键帽 + 麦克风。16pt 和菜单栏里其他图标（13–17pt）一样大。
                icon.size = NSSize(width: 16, height: 16)
                button.image = icon
                button.imagePosition = .imageLeading
            } else {
                button.title = "AU05"
            }
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
            }
        }
        session.onVendorKey = { [weak self] event in
            let note: String?
            if event.physicalIndex == 0 {
                let sent = (event.status == 0 || event.status == 1)
                    ? FunctionKey.handle(pressed: event.status == 1)
                    : false
                note = event.status == 1 ? (sent ? "已按下 Fn" : "Fn 未发出") : nil
            } else {
                note = DeviceKeys.handle(physicalIndex: event.physicalIndex, status: event.status)
            }
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
    }

    /// 有图标时菜单栏只显示图标（电量在菜单里看），没连上时图标变灰；
    /// 没有图标（不是从打包的 App 启动）时才用文字顶替。
    private func setStatusTitle(_ text: String, connected: Bool) {
        guard let button = statusItem.button else { return }
        if button.image == nil {
            button.title = "AU05 \(text)"
        } else {
            button.title = ""
            button.appearsDisabled = !connected
        }
    }

    private func show(_ status: PowerStatus?) {
        if let status {
            setStatusTitle(status.charging ? "\(status.percent)% 充电" : "\(status.percent)%", connected: true)
            if loggedPercent != status.percent || loggedCharging != status.charging {
                loggedPercent = status.percent
                loggedCharging = status.charging
                log("状态 \(status.percent)% \(status.millivolts) mV \(status.charging ? "充电" : "未充电")")
            }
        } else {
            setStatusTitle("未连接", connected: false)
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
        if let status {
            menu.addItem(title: "电量 \(status.percent)%", action: nil)
            menu.addItem(title: "电压 \(status.menuVoltage)", action: nil)
            menu.addItem(title: status.charging ? "正在充电" : "未在充电", action: nil)
        } else if linkLost {
            menu.addItem(title: "配置口未连接", action: nil)
        } else {
            menu.addItem(title: "正在连接配置口", action: nil)
        }
        menu.addItem(.separator())
        menu.addItem(title: FunctionKey.isTrusted ? "调试：对照系统按键" : "辅助功能未允许，Fn 发不出", action: nil)
        menu.addItem(title: recent, action: nil)
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
    }

    private func log(_ line: String) {
        DebugLog.write(line)
    }

    @objc private func refresh() {
        session.refresh()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        FunctionKey.reset()
    }

    @objc private func quit() {
        FunctionKey.reset()
        NSApp.terminate(nil)
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        addItem(item)
        return item
    }
}

let app = MenuBarApp()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = app
application.run()
