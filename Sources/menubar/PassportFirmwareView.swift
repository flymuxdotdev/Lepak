import AppKit
import CoreBluetooth
import LepakKit
import SwiftUI

/// AI Passport 的固件：设备上是什么版本、这个 Lepak 带的是什么版本、USB 连没连着，以及一键安装 / 更新。
/// 固件跟着 Lepak 发布（Contents/Resources/Firmware），不联网。真正的检查和写入在 `PassportFirmware`（LepakKit）。只在主线程使用。
@MainActor
final class PassportFirmwareModel: ObservableObject {
    static let shared = PassportFirmwareModel()

    enum Phase: Equatable {
        case idle
        case connecting
        case backingUp(Double)
        case writing(Double)
        /// 装好了；`backup` 是这次新做的备份（以前备份过就是 nil）。
        case finished(version: String, backup: URL?)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .connecting, .backingUp, .writing: return true
            default: return false
            }
        }

        /// 开始写之前都可以取消，设备会回到原来的固件。
        var canCancel: Bool {
            switch self {
            case .connecting, .backingUp: return true
            default: return false
            }
        }

        /// 安装过程的先后，晚到的旧进度不能把界面拨回去。
        fileprivate var rank: Int {
            switch self {
            case .idle, .finished, .failed: return 0
            case .connecting: return 1
            case .backingUp: return 2
            case .writing: return 3
            }
        }
    }

    enum Bundled: Equatable {
        case available(PassportFirmware.Manifest)
        /// 没带固件（直接 swift build 的开发版）或者带的固件不对，附原因。
        case unavailable(String)
    }

    @Published private(set) var phase = Phase.idle
    /// 这个 Lepak 带的固件。
    @Published private(set) var bundled: Bundled
    /// 设备通过蓝牙报上来的固件版本，这次启动连上过才知道。
    @Published private(set) var deviceVersion: String?
    /// USB 上的 AI Passport（乐鑫的串口），没插就是 nil。
    @Published private(set) var port: String?
    /// 占着 USB 串口的程序（InputBetter / FoloVibe Key 的 App），开着就装不了。
    @Published private(set) var blockingApp: String?
    @Published var sheetShown = false

    /// 跟着 App 的 esptool（Contents/Helpers）；直接 swift build 的开发版可以用环境变量 LEPAK_ESPTOOL 指定。
    let esptool: Esptool? = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/esptool")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return Esptool(url: bundled) }
        if let path = ProcessInfo.processInfo.environment["LEPAK_ESPTOOL"], FileManager.default.isExecutableFile(atPath: path) {
            return Esptool(url: URL(fileURLWithPath: path))
        }
        return nil
    }()

    /// 跟着 App 的固件（Contents/Resources/Firmware）；开发版可以用环境变量 LEPAK_FIRMWARE_DIR 指定。
    private static var firmwareFolder: URL? {
        if let folder = Bundle.main.resourceURL?.appendingPathComponent("Firmware", isDirectory: true),
           FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) {
            return folder
        }
        if let path = ProcessInfo.processInfo.environment["LEPAK_FIRMWARE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// 第一次给某台设备装固件前，整片 Flash 备份在这里（含设备身份数据，只留在本机）。
    static let backupFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lepak/Backups", isDirectory: true)

    /// 占串口的程序：社区项目的 App。
    private static let blockingApps: Set<String> = ["InputBetter", "FoloVibe Key", "VibeKey", "PassportKeys"]

    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var watchers = 0
    private var sample = false

    init() {
        bundled = Self.loadBundled()
    }

    private static func loadBundled() -> Bundled {
        guard let folder = firmwareFolder else { return .unavailable(FirmwareError.missing.errorDescription ?? "") }
        do {
            return .available(try PassportFirmware.manifest(in: folder))
        } catch {
            return .unavailable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: 状态

    var bundledManifest: PassportFirmware.Manifest? {
        if case .available(let manifest) = bundled { return manifest }
        return nil
    }

    var updateAvailable: Bool {
        guard let manifest = bundledManifest, let deviceVersion else { return false }
        return PassportFirmware.isNewer(manifest.version, than: deviceVersion)
    }

    var canInstall: Bool {
        !phase.isRunning && port != nil && esptool != nil && blockingApp == nil && bundledManifest != nil
    }

    /// 设备每次握手报一次版本。
    func deviceReported(version: String, build: String?) {
        guard !sample else { return }
        deviceVersion = version
    }

    // MARK: 设备页开着时每秒看一眼 USB

    func startWatching() {
        watchers += 1
        guard !sample else { return }
        refreshUSB()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in PassportFirmwareModel.shared.refreshUSB() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func refreshUSB() {
        guard !sample else { return }
        let found = PassportFirmware.usbPorts().first
        if found != port { port = found }
        let blocking = NSWorkspace.shared.runningApplications
            .first { Self.blockingApps.contains($0.localizedName ?? "") }?.localizedName
        if blocking != blockingApp { blockingApp = blocking }
    }

    func quitBlockingApp() {
        NSWorkspace.shared.runningApplications
            .filter { Self.blockingApps.contains($0.localizedName ?? "") }
            .forEach { $0.terminate() }
    }

    // MARK: 安装

    func install() {
        guard canInstall, let port, let esptool, let manifest = bundledManifest else { return }
        phase = .connecting
        task = Task { await run(manifest, port: port, esptool: esptool) }
    }

    func cancel() {
        guard phase.canCancel else { return }
        task?.cancel()
    }

    /// 关掉弹窗：装完或失败的结果不再留着。
    func closeSheet() {
        guard !phase.isRunning else { return }
        sheetShown = false
        if !sample { phase = .idle }
    }

    private func run(_ manifest: PassportFirmware.Manifest, port: String, esptool: Esptool) async {
        var prepared: PassportFirmware.Prepared?
        defer { prepared?.discard() }
        do {
            // 每次都重新校验 App 里的镜像（2 MB 多，很快）。
            let firmware = try PassportFirmware.prepare(manifest)
            prepared = firmware
            DebugLog.write("AI Passport 固件：开始安装 \(manifest.version)（\(manifest.build)）")
            let result = try await PassportFirmware.install(firmware, port: port, esptool: esptool,
                                                            backupFolder: Self.backupFolder) { step in
                let phase: Phase = switch step {
                case .connecting: .connecting
                case .backingUp(let value): .backingUp(value)
                case .writing(let value): .writing(value)
                }
                Task { @MainActor in PassportFirmwareModel.shared.advance(to: phase) }
            }
            DebugLog.write("AI Passport 固件：已装好 \(manifest.version)" + (result.newBackup.map { "，备份在 \($0.path)" } ?? ""))
            phase = .finished(version: manifest.version, backup: result.newBackup)
        } catch is CancellationError {
            phase = .idle
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DebugLog.write("AI Passport 固件：安装失败 \(message)")
            phase = .failed(message)
        }
        task = nil
    }

    /// 进度只往前走：晚到的旧进度（比如备份的最后一点）不覆盖已经开始的写入。
    private func advance(to next: Phase) {
        guard phase.isRunning, next.rank >= phase.rank else { return }
        phase = next
    }

    // MARK: 开发截图

    func showSample(phase: Phase, bundled: Bundled, device: String?, port: String?, blocking: String? = nil) {
        sample = true
        self.phase = phase
        self.bundled = bundled
        deviceVersion = device
        self.port = port
        blockingApp = blocking
    }

    static let sampleManifest = PassportFirmware.Manifest(version: "1.0.0", build: "506deb46", images: [])
}

// MARK: 设备页上的入口

/// AI Passport 页右上角的胶囊按钮：「固件 0.1.21」，Lepak 带的固件比设备上的新时带一个小圆点。点开是固件弹窗。
/// `repair` 是装好后「重新配对」要做的事（`SettingsModel.beginRepairPassport`）。
struct PassportFirmwareBadge: View {
    @ObservedObject var firmware = PassportFirmwareModel.shared
    let accent: Color
    let repair: () -> Void

    var body: some View {
        Button { firmware.sheetShown = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(firmware.deviceVersion.map { "固件 \($0)" } ?? "固件")
                    .font(.system(size: 13, weight: .semibold))
                if firmware.updateAvailable {
                    Circle().fill(accent).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Palette.card))
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(firmware.updateAvailable ? "有新固件，点这里更新" : "查看或安装 AI Passport 的固件")
        .onAppear { firmware.startWatching() }
        .onDisappear { firmware.stopWatching() }
        .sheet(isPresented: Binding(
            get: { firmware.sheetShown },
            set: { if !$0 { firmware.closeSheet() } }
        )) {
            PassportFirmwareSheet(firmware: firmware, accent: accent) {
                // 两个弹窗不能同时开：先关掉固件弹窗，等它收起再打开配对弹窗。
                firmware.closeSheet()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { repair() }
            }
        }
    }
}

/// 设备页顶上的一条提示：AI Passport 用 USB 连着，蓝牙却没连上，多半还没装 Lepak 的固件。不满足条件时不占地方。
struct PassportFirmwareBanner: View {
    @ObservedObject var firmware = PassportFirmwareModel.shared
    let connected: Bool
    let accent: Color

    var body: some View {
        if firmware.port != nil, !connected, !firmware.phase.isRunning {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(accent)
                Text("AI Passport 用 USB 连着，蓝牙却没连上。如果还没装 Lepak 的固件，可以现在安装。")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 8)
                Button("安装固件…") { firmware.sheetShown = true }
                    .buttonStyle(PillButtonStyle(kind: .accent(accent), height: 28))
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.opacity(0.12)))
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }
    }
}

// MARK: 弹窗

struct PassportFirmwareSheet: View {
    @ObservedObject var firmware: PassportFirmwareModel
    let accent: Color
    let repair: () -> Void

    static let width: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI Passport 固件").font(.system(size: 24, weight: .bold))
                Text("AI Passport 要装上 Lepak 的固件才能连上。用 USB-C 线连到这台 Mac，就能安装或更新。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 20)

            VStack(spacing: 0) {
                row("设备上的版本") {
                    Text(firmware.deviceVersion ?? "蓝牙连上后显示")
                        .foregroundStyle(firmware.deviceVersion == nil ? .secondary : .primary)
                }
                Divider().padding(.horizontal, 16)
                row("Lepak 带的版本") { bundledValue }
                Divider().padding(.horizontal, 16)
                row("USB") { usbValue }
            }
            .card(padding: 0, radius: 16)

            if let app = firmware.blockingApp, !firmware.phase.isRunning {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(app) 正在运行，会占住 USB 连接，先退出它。")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("退出 \(app)") { firmware.quitBlockingApp() }
                        .buttonStyle(PillButtonStyle(kind: .accent(.orange), height: 28))
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
                .padding(.top, 14)
            }

            status
                .padding(.top, 18)

            Text("固件跟着 Lepak 一起发布，带蓝牙配对保护：只有配对过的 Mac 能连上它。第一次给一台设备安装时，Lepak 会先把它原来的内容完整备份到这台 Mac，多花一两分钟。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)

            HStack(spacing: 10) {
                Spacer()
                if firmware.phase.isRunning {
                    if firmware.phase.canCancel {
                        Button("取消") { firmware.cancel() }
                            .buttonStyle(PillButtonStyle(kind: .subtle, height: 34))
                    }
                } else {
                    Button("关闭") { firmware.closeSheet() }
                        .buttonStyle(PillButtonStyle(kind: .subtle, height: 34))
                        .keyboardShortcut(.cancelAction)
                    if !isFinished {
                        Button(installTitle) { firmware.install() }
                            .buttonStyle(PillButtonStyle(kind: .accent(accent), height: 34))
                            .disabled(!firmware.canInstall)
                            .opacity(firmware.canInstall ? 1 : 0.45)
                    }
                }
            }
            .padding(.top, 22)
        }
        .padding(28)
        .frame(width: Self.width)
        .background(Palette.canvas)
        .tint(accent)
        .interactiveDismissDisabled(firmware.phase.isRunning)
        .onAppear { firmware.startWatching() }
        .onDisappear { firmware.stopWatching() }
    }

    private var isFinished: Bool {
        if case .finished = firmware.phase { return true }
        return false
    }

    private var installTitle: String {
        if case .failed = firmware.phase { return "再试一次" }
        guard let manifest = firmware.bundledManifest else { return "安装固件" }
        guard let current = firmware.deviceVersion else { return "安装 \(manifest.version)" }
        if PassportFirmware.isNewer(manifest.version, than: current) { return "更新到 \(manifest.version)" }
        if PassportFirmware.isNewer(current, than: manifest.version) { return "安装 \(manifest.version)" }
        return "重新安装"
    }

    private func row<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value().font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }

    @ViewBuilder private var bundledValue: some View {
        switch firmware.bundled {
        case .available(let manifest):
            HStack(spacing: 8) {
                Text(manifest.version)
                if firmware.updateAvailable {
                    Text("有新版本").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                } else if let current = firmware.deviceVersion, !PassportFirmware.isNewer(current, than: manifest.version) {
                    Text("已是最新").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                }
            }
        case .unavailable:
            Text("没有").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var usbValue: some View {
        if firmware.port != nil {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("已连接")
            }
        } else {
            Text("没连上：用 USB-C 数据线连到这台 Mac，并给设备开机")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    /// 安装进度、结果或错误。空闲时不占地方。
    @ViewBuilder private var status: some View {
        switch firmware.phase {
        case .idle:
            if case .unavailable(let reason) = firmware.bundled {
                message("exclamationmark.triangle.fill", .orange, reason)
            } else if firmware.esptool == nil {
                message("exclamationmark.triangle.fill", .orange, FirmwareError.toolMissing.errorDescription ?? "")
            }
        case .connecting:
            progress("正在连接设备…", nil)
        case .backingUp(let value):
            progress("第一次安装，正在备份设备原来的内容…", value)
        case .writing(let value):
            progress("正在写入固件…", value)
        case .finished(let version, let backup):
            VStack(alignment: .leading, spacing: 10) {
                message("checkmark.circle.fill", .green, "装好了 \(version)。设备正在重启，过一会儿会自动连上。")
                HStack(spacing: 10) {
                    Text("过一会儿还连不上的话，重新配对一次。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button("重新配对") { repair() }
                        .buttonStyle(PillButtonStyle(kind: .subtle, height: 28))
                }
                if let backup {
                    HStack(spacing: 10) {
                        Text("设备原来的内容已经备份在这台 Mac 上。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                            .buttonStyle(PillButtonStyle(kind: .subtle, height: 28))
                    }
                }
            }
        case .failed(let text):
            message("xmark.octagon.fill", .red, text)
        }
    }

    private func progress(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let value, value > 0 {
                    Text("\(Int(value * 100))%").font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let value, value > 0 {
                ProgressView(value: value).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text("安装时不要拔线，也不要关机或退出 Lepak。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func message(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 开发截图

extension PassportFirmwareSheet {
    /// 截图用的窗口：允许放在屏幕外面。
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// 开发用：把固件弹窗的几种状态和带提示条的设备页画成 PNG（`--snapshot-settings` 最后调用）。
    static func snapshotAll(to folder: URL) {
        let firmware = PassportFirmwareModel.shared
        let bundled = PassportFirmwareModel.Bundled.available(PassportFirmwareModel.sampleManifest)
        let accent = DeviceTheme.standard.accent
        let usb = "/dev/cu.usbmodem101"
        let cases: [(String, NSAppearance.Name, () -> Void)] = [
            ("firmware-update-light", .aqua, {
                firmware.showSample(phase: .idle, bundled: bundled, device: "0.1.21", port: usb)
            }),
            ("firmware-no-usb-dark", .darkAqua, {
                firmware.showSample(phase: .idle, bundled: bundled, device: nil, port: nil)
            }),
            ("firmware-blocked-light", .aqua, {
                firmware.showSample(phase: .idle, bundled: bundled, device: nil, port: usb, blocking: "InputBetter")
            }),
            ("firmware-missing-light", .aqua, {
                firmware.showSample(phase: .idle, bundled: .unavailable(FirmwareError.missing.errorDescription ?? ""),
                                    device: "1.0.0", port: usb)
            }),
            ("firmware-backup-dark", .darkAqua, {
                firmware.showSample(phase: .backingUp(0.42), bundled: bundled, device: "0.1.21", port: usb)
            }),
            ("firmware-writing-light", .aqua, {
                firmware.showSample(phase: .writing(0.63), bundled: bundled, device: "0.1.21", port: usb)
            }),
            ("firmware-done-light", .aqua, {
                firmware.showSample(phase: .finished(version: "1.0.0", backup: URL(fileURLWithPath: "/tmp/passport-backup.bin")),
                                    bundled: bundled, device: "1.0.0", port: usb)
            }),
            ("firmware-failed-dark", .darkAqua, {
                firmware.showSample(phase: .failed(FirmwareError.portBusy.errorDescription ?? ""), bundled: bundled,
                                    device: nil, port: usb)
            }),
        ]
        for (name, appearance, setUp) in cases {
            setUp()
            let host = NSHostingController(rootView: PassportFirmwareSheet(firmware: firmware, accent: accent) {})
            render(host, appearance: appearance, to: folder.appendingPathComponent("\(name).png"))
        }

        // 设备页：USB 连着、蓝牙没连上，顶上出现安装提示；右上角是固件按钮。
        let model = SettingsModel()
        model.showSampleSetup(accessibility: true, bluetooth: .allowedAlways, mic: .installed)
        model.config.devices = [.passport]
        model.section = .device(.passport)
        model.updatePassport(DeviceSnapshot(link: .disconnected))
        firmware.showSample(phase: .idle, bundled: bundled, device: nil, port: usb)
        for (name, appearance) in [("device-passport-firmware-banner-light", NSAppearance.Name.aqua),
                                   ("device-passport-firmware-banner-dark", .darkAqua)] {
            render(window: settingsWindow(model), appearance: appearance, to: folder.appendingPathComponent("\(name).png"))
        }
        // 再画一张已连上、有新固件的设备页（右上角的按钮带圆点）。
        model.showSampleDevice()
        firmware.showSample(phase: .idle, bundled: bundled, device: "0.1.21", port: nil)
        render(window: settingsWindow(model), appearance: .aqua,
               to: folder.appendingPathComponent("device-passport-firmware-update-light.png"))
    }

    private static func settingsWindow(_ model: SettingsModel) -> NSWindow {
        let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.size),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(SettingsWindowController.size)
        return window
    }

    private static func render(_ host: NSViewController, appearance: NSAppearance.Name, to url: URL) {
        let window = OffscreenWindow(contentViewController: host)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        render(window: window, appearance: appearance, to: url, frameView: false)
    }

    private static func render(window: NSWindow, appearance: NSAppearance.Name, to url: URL, frameView: Bool = true) {
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let view = frameView ? window.contentView?.superview : window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote", url.path)
    }
}
