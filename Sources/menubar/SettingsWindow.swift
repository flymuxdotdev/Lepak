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
        model.record(.knobPressTurn, "切到右边桌面", KeyCombo(keyCode: 124, control: true))
        model.record(.voice, "语音输入", KeyCombo(keyCode: FunctionKey.virtualKey))
        model.record(.knobPress, "删到行首", KeyCombo(keyCode: 51, command: true))
        model.record(.knobTurn, "移动光标", nil)
        model.record(.confirm, "确定", KeyCombo(keyCode: 36))
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
        pages.append(Page(section: .home, appearance: .darkAqua, name: "home-signed-out-dark", signedIn: false))
        pages.append(Page(section: .general, appearance: .aqua, name: "general-signed-out-light", signedIn: false))
        pages.append(Page(section: .general, appearance: .darkAqua, name: "general-signed-out-dark", signedIn: false))
        for page in pages {
            let (section, theme, appearance, control, name, gestures) =
                (page.section, page.theme, page.appearance, page.control, page.name, page.gestures)
            model.section = section
            model.showSampleUlanziWarning(page.ulanzi)
            model.account = page.signedIn ? Account(appleUserID: "sample", email: "you@example.com") : nil
            model.config.deviceTheme = theme
            for key in GestureKey.allCases {
                for gesture in KeyGesture.allCases {
                    let path = key.gesturePath(gesture)
                    model.config[keyPath: path] = gestures ? key.suggestedCombo(gesture) : original[keyPath: path]
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
