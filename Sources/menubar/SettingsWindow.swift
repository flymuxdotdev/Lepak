import AppKit
import SwiftUI

/// 设置窗口。Lepak 平时只在菜单栏里（不显示在 Dock）；打开设置时临时显示 Dock 图标，
/// 方便被别的窗口挡住后切回来，关掉窗口再隐藏。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    func show(section: SettingsSection? = nil) {
        if let section {
            model.section = section
        }
        model.refreshPermissions()
        model.refreshUlanzi()
        model.refreshLoginItem()
        model.refreshAccount()
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        // 被 ⌘H 隐藏或最小化进 Dock 的窗口要先还原，不然只激活了程序，窗口还是看不见。
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// 全屏时系统默认一直显示工具栏，变成顶上一条很高的灰条，挡住内容。
    /// 这个工具栏是空的（只为挪红黄绿按钮），全屏时让它和菜单栏一起自动隐藏，鼠标移到屏幕顶端才滑出来。
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        model.isFullScreen = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        model.isFullScreen = false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: Self.styleMask, backing: .buffered, defer: false)
        Self.configure(window, model: model)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    static let size = NSSize(width: 1100, height: 740)
    private static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    private static func configure(_ window: NSWindow, model: SettingsModel) {
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
        window.title = "Lepak"
        // 标题栏透明、不显示标题：内容一直延伸到窗口顶部。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // 一个空的工具栏只为把红黄绿按钮往右下挪一点，正好落在侧栏的圆角卡片里。
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 1000, height: 660)
        window.setContentSize(size)
    }

    /// 截图用的窗口：允许放在屏幕外面（普通窗口会被系统挪回屏幕里）。
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// 开发用：把设置窗口的每一页画成 PNG（不连设备），方便没有屏幕录制权限时检查界面。
    /// 窗口真的显示出来（放在屏幕外面，看不到），系统控件（滑块、选择器）才画得出来；连标题栏的红黄绿按钮一起截。
    /// 每页画浅色和深色两张，另加几张 WorkBuddy 主题和展开不同控件的按键页。
    /// 用法：Lepak --snapshot-settings <输出文件夹>；看窗口拉大后的样子，加环境变量 LEPAK_SNAPSHOT_SIZE=1500x900。
    static func snapshotAll(to folder: URL) {
        let snapshotSize: NSSize = {
            let parts = (ProcessInfo.processInfo.environment["LEPAK_SNAPSHOT_SIZE"] ?? "")
                .split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : size
        }()
        let model = SettingsModel()
        model.showSampleDevice()
        model.record(.au05, .knobPressTurn, "切到右边桌面", KeyCombo(keyCode: 124, control: true))
        model.record(.au05, .voice, "语音输入", KeyCombo(keyCode: FunctionKey.virtualKey))
        model.record(.au05, .knobPress, "删到行首", KeyCombo(keyCode: 51, command: true))
        model.record(.au05, .knobTurn, "移动光标", nil)
        model.record(.au05, .confirm, "确定", KeyCombo(keyCode: 36))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = model.config
        defer { model.config = original }   // 下面会临时换主题，画完改回来
        struct Page {
            var section: SettingsSection
            var theme = DeviceTheme.standard
            var appearance: NSAppearance.Name
            var control = MappingControl.confirm
            var name: String
            /// 是否把确定 / 取消的长按、双击全部开启（看卡片最高时放不放得下）。
            var gestures = false
            /// 是否显示「Ulanzi Studio 也在运行」的提醒条。
            var ulanzi = false
            /// 侧栏底部显示示例账号（已登录）还是「未登录」。
            var signedIn = true
            /// 「我的设备」里有哪些（默认全部，看空列表时传 []）。
            var devices = DeviceKind.allCases
            /// 用户起的名字（看改名后的样子）。
            var names: [String: String] = [:]
            /// 假装辅助功能、蓝牙都没允许，Lepak 麦克风没装（看提醒条和安装按钮）；默认都准备好了。
            var setupMissing = false
        }
        let au05 = SettingsSection.device(.au05)
        var pages: [Page] = []
        for section in SettingsSection.allCases {
            pages.append(Page(section: section, appearance: .aqua, name: "\(section.name)-light"))
            pages.append(Page(section: section, appearance: .darkAqua, control: .knobPress, name: "\(section.name)-dark"))
        }
        pages.append(Page(section: au05, theme: .workBuddy, appearance: .darkAqua, control: .knobTurn, name: "device-au05-workbuddy-dark"))
        pages.append(Page(section: au05, theme: .workBuddy, appearance: .aqua, name: "device-au05-workbuddy-light"))
        pages.append(Page(section: au05, appearance: .darkAqua, name: "device-au05-gestures-dark", gestures: true))
        pages.append(Page(section: au05, appearance: .aqua, name: "device-au05-ulanzi-light", gestures: true, ulanzi: true))
        pages.append(Page(section: .device(.passport), appearance: .aqua, control: .voice, name: "device-passport-gestures-light", gestures: true))
        pages.append(Page(section: .home, appearance: .darkAqua, name: "home-signed-out-dark", signedIn: false))
        pages.append(Page(section: .general, appearance: .aqua, name: "general-signed-out-light", signedIn: false))
        pages.append(Page(section: .general, appearance: .darkAqua, name: "general-signed-out-dark", signedIn: false))
        pages.append(Page(section: .home, appearance: .aqua, name: "home-no-devices-light", devices: []))
        pages.append(Page(section: .home, appearance: .darkAqua, name: "home-no-devices-dark", devices: []))
        pages.append(Page(section: .home, appearance: .aqua, name: "home-passport-only-light", devices: [.passport]))
        let renamed = ["au05": "书房的 AU05", "passport": "随身的小方块"]
        pages.append(Page(section: au05, appearance: .aqua, name: "device-au05-renamed-light", names: renamed))
        pages.append(Page(section: .device(.passport), appearance: .darkAqua, name: "device-passport-renamed-dark", names: renamed))
        pages.append(Page(section: .home, appearance: .aqua, name: "home-renamed-light", names: renamed))
        pages.append(Page(section: .home, appearance: .aqua, name: "home-setup-light", setupMissing: true))
        pages.append(Page(section: .device(.passport), appearance: .darkAqua, name: "device-passport-setup-dark", setupMissing: true))
        pages.append(Page(section: .general, appearance: .aqua, name: "general-setup-light", setupMissing: true))
        // AI Passport 还没配对：首页和设备页顶上的「配对」提醒条。
        pages.append(Page(section: .device(.passport), appearance: .aqua, name: "device-passport-unpaired-light"))
        // 配对对不上：设备不认这台 Mac / 设备清掉了配对。
        pages.append(Page(section: .device(.passport), appearance: .darkAqua, name: "device-passport-rejected-dark"))
        pages.append(Page(section: .home, appearance: .aqua, name: "home-passport-removed-light"))
        for page in pages {
            model.showSampleSetup(accessibility: !page.setupMissing,
                                  bluetooth: page.setupMissing ? .denied : .allowedAlways,
                                  mic: page.setupMissing ? .notInstalled : .installed)
            model.updatePassportPaired(page.name != "device-passport-unpaired-light")
            model.updatePassportRejection(page.name == "device-passport-rejected-dark" ? .macNotAccepted
                                          : page.name == "home-passport-removed-light" ? .removedOnDevice : nil)
            let (section, theme, appearance, control, name, gestures) =
                (page.section, page.theme, page.appearance, page.control, page.name, page.gestures)
            model.section = section
            model.showSampleUlanziWarning(page.ulanzi)
            model.account = page.signedIn ? Account(appleUserID: "sample", email: "you@example.com") : nil
            model.config.deviceTheme = theme
            model.config.devices = page.devices
            model.config.deviceNames = page.names
            for device in DeviceKind.allCases {
                for key in GestureKey.allCases {
                    for gesture in KeyGesture.allCases {
                        let path = key.gesturePath(gesture, device)
                        model.config[keyPath: path] = gestures ? key.suggestedCombo(gesture) : original[keyPath: path]
                    }
                }
            }
            model.mappingUI.select(control)
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size),
                                         styleMask: styleMask, backing: .buffered, defer: false)
            configure(window, model: model)
            window.setContentSize(snapshotSize)
            window.appearance = NSAppearance(named: appearance)
            window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            // 截整个窗口（含标题栏），不只是内容。
            guard let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            window.orderOut(nil)
            let url = folder.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote", url.path)
        }
        // 「添加设备」弹窗：真正的 sheet 截不到，单独放进一个离屏窗口里画。
        model.section = .home
        model.config.deviceTheme = .standard
        let sheets: [(AddDeviceStep, [DeviceKind], NSAppearance.Name, String)] = [
            (.choose, [], .aqua, "add-device-choose-light"),
            (.choose, [.au05], .darkAqua, "add-device-choose-dark"),
            (.connect(.au05), [], .aqua, "add-device-au05-light"),
            (.connect(.au05), [], .darkAqua, "add-device-au05-dark"),
            (.connect(.passport), [], .aqua, "add-device-passport-light"),
            (.connect(.passport), [], .darkAqua, "add-device-passport-ready-dark"),
            (.connect(.passport), [], .aqua, "add-device-passport-installing-light"),
            // 配对：Mac 正在弹系统的配对窗口 / 「重新配对」/ 连上的是没有配对保护的旧固件。
            (.connect(.passport), [], .aqua, "add-device-passport-pairing-light"),
            (.connect(.passport), [.passport], .darkAqua, "repair-passport-dark"),
            (.connect(.passport), [], .aqua, "add-device-passport-unprotected-light"),
        ]
        for (step, devices, appearance, name) in sheets {
            model.cancelAddDevice()
            model.config.devices = devices
            if name == "repair-passport-dark" {
                model.beginRepairPassport()
            } else if case .connect(let kind) = step {
                model.chooseDevice(kind)
            } else {
                model.addDeviceStep = step
            }
            model.updatePassportProtection(name != "add-device-passport-unprotected-light")
            model.showSampleUlanziWarning(name == "add-device-au05-dark")
            if name == "add-device-passport-light" {
                model.updatePassport(DeviceSnapshot(link: .disconnected, note: "蓝牙已关闭"))
            } else {
                model.showSampleDevice()
            }
            if name == "add-device-au05-light" {
                model.update(status: nil, linkLost: false)
            }
            // 清单的几种样子：什么都没准备好 / 都好了 / 正在等蓝牙授权和安装驱动。
            switch name {
            case "add-device-passport-light", "add-device-au05-light":
                model.showSampleSetup(accessibility: false, bluetooth: .allowedAlways, mic: .notInstalled)
                if name == "add-device-passport-light" {
                    model.updatePassport(DeviceSnapshot(link: .disconnected, note: "蓝牙已关闭", bluetooth: .off))
                }
            case "add-device-passport-installing-light":
                model.showSampleSetup(accessibility: true, bluetooth: .notDetermined, mic: .notInstalled, busy: true)
                model.updatePassport(DeviceSnapshot(link: .connecting))
            case "add-device-passport-pairing-light", "repair-passport-dark":
                model.showSampleSetup(accessibility: true, bluetooth: .allowedAlways, mic: .installed)
                model.updatePassport(DeviceSnapshot(link: .connecting))
            default:
                model.showSampleSetup(accessibility: true, bluetooth: .allowedAlways, mic: .installed)
            }
            let host = NSHostingController(rootView: AddDeviceSheet(model: model))
            let window = OffscreenWindow(contentViewController: host)
            window.styleMask = [.titled, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearance)
            window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            window.orderOut(nil)
            let url = folder.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote", url.path)
        }
        model.cancelAddDevice()
        PassportFirmwareSheet.snapshotAll(to: folder)
    }

    /// 显示 Dock 图标时屏幕顶部会出现本程序的菜单栏，给它最基本的菜单，⌘W / ⌘Q 才好用。
    static func installMainMenu(openSettings: Selector, target: AnyObject) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "设置…", action: openSettings, keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Lepak", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Lepak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
