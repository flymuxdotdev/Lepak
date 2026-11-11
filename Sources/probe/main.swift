import Darwin
import Foundation
import IOKit
import IOKit.hid

/// AU05 配置报文使用 TEA（32 轮，delta 0x9E3779B9），按 8 字节分组。
enum FrameCodec {
    static let key: (UInt32, UInt32, UInt32, UInt32) = (
        0xCAA5_BACA, 0xBC2A_8A6D, 0xCA5A_9EBA, 0x9BB8_8BCA
    )

    static func encrypt(_ plain: [UInt8]) -> [UInt8] {
        transform(plain, decode: false)
    }

    static func decrypt(_ cipher: [UInt8]) -> [UInt8] {
        transform(cipher, decode: true)
    }

    private static func transform(_ bytes: [UInt8], decode: Bool) -> [UInt8] {
        var out = bytes
        let blocks = out.count / 8
        for index in 0..<blocks {
            let base = index * 8
            var v0 = UInt32(out[base])
                | (UInt32(out[base + 1]) << 8)
                | (UInt32(out[base + 2]) << 16)
                | (UInt32(out[base + 3]) << 24)
            var v1 = UInt32(out[base + 4])
                | (UInt32(out[base + 5]) << 8)
                | (UInt32(out[base + 6]) << 16)
                | (UInt32(out[base + 7]) << 24)
            if decode {
                decodeBlock(&v0, &v1)
            } else {
                encodeBlock(&v0, &v1)
            }
            write(v0, into: &out, at: base)
            write(v1, into: &out, at: base + 4)
        }
        return out
    }

    private static func encodeBlock(_ v0: inout UInt32, _ v1: inout UInt32) {
        let delta: UInt32 = 0x9E37_79B9
        let (k0, k1, k2, k3) = key
        var sum: UInt32 = 0
        for _ in 0..<32 {
            sum = sum &+ delta
            v0 = v0 &+ (((v1 << 4) &+ k0) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ k1))
            v1 = v1 &+ (((v0 << 4) &+ k2) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ k3))
        }
    }

    private static func decodeBlock(_ v0: inout UInt32, _ v1: inout UInt32) {
        let delta: UInt32 = 0x9E37_79B9
        let (k0, k1, k2, k3) = key
        var sum: UInt32 = delta &* 32
        for _ in 0..<32 {
            v1 = v1 &- (((v0 << 4) &+ k2) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ k3))
            v0 = v0 &- (((v1 << 4) &+ k0) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ k1))
            sum = sum &- delta
        }
    }

    private static func write(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

struct DeviceMessage {
    var bytes: [UInt8]

    static func command(_ command: UInt8, head: UInt8 = 0x01, marker: UInt8 = 0x01) -> DeviceMessage {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = head
        bytes[1] = marker
        bytes[2] = command
        bytes[3] = 0x01
        return DeviceMessage(bytes: bytes)
    }

    static func heartbeat() -> DeviceMessage {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x06
        bytes[1] = 0x01
        bytes[2] = 0x23
        bytes[3] = 0x00
        bytes[4] = 0x01
        return DeviceMessage(bytes: bytes)
    }

    static func auth(code: UInt32) -> DeviceMessage {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x06
        bytes[1] = 0x02
        bytes[2] = 0x05
        bytes[3] = 0x01
        bytes[4] = UInt8(code & 0x0F)
        bytes[5] = UInt8(code & 0xFF)
        bytes[6] = UInt8((code >> 8) & 0xFF)
        bytes[7] = UInt8((code >> 16) & 0xFF)
        bytes[8] = UInt8((code >> 24) & 0xFF)
        return DeviceMessage(bytes: bytes)
    }

    static func hooks(enabled: Bool) -> DeviceMessage {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x01
        bytes[1] = 0x0B
        bytes[2] = 0x89
        bytes[3] = 0x04
        bytes[4] = enabled ? 1 : 0
        return DeviceMessage(bytes: bytes)
    }
}

final class Probe: @unchecked Sendable {
    let vendorID = 65521
    let productID = 221
    let vendorUsagePage = 0xFFFC
    let reportID: UInt8 = 0x55
    let authCode = arc4random()

    private var manager: IOHIDManager?
    private var vendorDevice: IOHIDDevice?
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var sawAuthPacket = false
    private var sawAuthEcho = false
    private var sawBattery = false
    private var sawMicNR = false
    private var inputReports = 0
    private var watchMode = false
    private var enableHooks = false
    private var hooksOnly: Bool?
    private let quietCommands: Set<UInt8> = [0x02, 0x05, 0x23, 0x90]

    func setHooks(enabled: Bool) {
        hooksOnly = enabled
        run(seconds: 2)
    }

    func watch(seconds: TimeInterval, hooks: Bool) {
        watchMode = true
        enableHooks = hooks
        run(seconds: seconds)
    }

    func run(seconds: TimeInterval) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        // 只匹配配置口。把键盘口一起打开会触发「输入监控」权限，命令行探测会被直接拒绝。
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
            kIOHIDDeviceUsagePageKey as String: vendorUsagePage,
            kIOHIDDeviceUsageKey as String: 1,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            print("打开 HID 失败：\(statusName(opened))")
            return
        }

        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        if devices.isEmpty {
            print("没有找到 AU05。确认接收器已插入，并且 Ulanzi Studio 没有独占它。")
            return
        }

        for device in devices {
            describe(device)
            register(device)
            if usagePage(of: device) == vendorUsagePage {
                vendorDevice = device
            }
        }

        guard vendorDevice != nil else {
            print("找到了 AU05，但没有 Usage Page 0xFFFC 的配置接口。")
            return
        }

        let started = Date()
        if let hooksOnly {
            let label = hooksOnly ? "打开按键直报" : "关闭按键直报"
            emit(label)
            schedule(after: 0.3) { self.send(DeviceMessage.hooks(enabled: hooksOnly), label: label) }
        } else if watchMode {
            emit(enableHooks
                ? "WATCH 就绪。正在打开按键直报，之后只按我的提示操作。"
                : "WATCH 就绪。只打印按键和旋钮，电量和心跳不再刷屏。")
            schedule(after: 0.3) { self.send(DeviceMessage.heartbeat(), label: "心跳") }
            if enableHooks {
                schedule(after: 0.6) { self.send(DeviceMessage.hooks(enabled: true), label: "打开按键直报") }
                schedule(after: seconds - 0.4) { self.send(DeviceMessage.hooks(enabled: false), label: "关闭按键直报") }
            }
        } else {
            emit("认证码 \(String(format: "%08X", self.authCode))。请在这 \(Int(seconds)) 秒内按下三个键并转动旋钮。")
            schedule(after: 0.3) { self.send(DeviceMessage.heartbeat(), label: "心跳") }
            schedule(after: 0.5) { self.send(DeviceMessage.auth(code: self.authCode), label: "认证") }
            schedule(after: 0.9) { self.send(DeviceMessage.command(0x02), label: "读取电量") }
            schedule(after: 1.2) { self.send(DeviceMessage.command(0x90), label: "读取降噪") }
        }
        schedule(after: seconds) { CFRunLoopStop(CFRunLoopGetMain()) }
        CFRunLoopRun()

        let elapsed = Date().timeIntervalSince(started)
        print(
            String(
                format: "结束。用时 %.1f 秒，收到 %d 条输入，认证 %@，电量 %@，降噪 %@。",
                elapsed,
                inputReports,
                sawAuthEcho ? "已对上" : (sawAuthPacket ? "有回包但未对上" : "没有回包"),
                sawBattery ? "已读到" : "没有",
                sawMicNR ? "已读到" : "没有"
            )
        )
        for buffer in reportBuffers {
            buffer.deallocate()
        }
    }

    private func describe(_ device: IOHIDDevice) {
        let page = usagePage(of: device)
        let usage = intProperty(device, kIOHIDDeviceUsageKey as String) ?? -1
        let input = intProperty(device, kIOHIDMaxInputReportSizeKey as String) ?? -1
        let output = intProperty(device, kIOHIDMaxOutputReportSizeKey as String) ?? -1
        let name = stringProperty(device, kIOHIDProductKey as String) ?? "AU05"
        print("接口 \(name)  usage page \(String(format: "0x%04X", page)) usage \(usage)  输入 \(input) 字节  输出 \(output) 字节")
    }

    private func register(_ device: IOHIDDevice) {
        let size = max(intProperty(device, kIOHIDMaxInputReportSizeKey as String) ?? 64, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        reportBuffers.append(buffer)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, result, _, _, reportID, report, length in
            guard let context, result == kIOReturnSuccess else { return }
            let probe = Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
            probe.handleInput(reportID: reportID, bytes: bytes)
        }, context)
    }

    private func handleInput(reportID: UInt32, bytes: [UInt8]) {
        inputReports += 1
        var payload = bytes
        if reportID != 0, payload.first == UInt8(reportID & 0xFF) {
            payload.removeFirst()
        }
        guard usagePageOfCurrentIsVendor(reportID: reportID, count: bytes.count) else {
            print("按键/鼠标  report \(reportID)  \(hex(bytes.prefix(12)))")
            return
        }
        let plain = FrameCodec.decrypt(payload)
        interpret(plain)
    }

    /// 配置口的报文才会被解密。键盘口的 report id 通常是 1、2、3。
    private func usagePageOfCurrentIsVendor(reportID: UInt32, count: Int) -> Bool {
        reportID == UInt32(self.reportID) || count >= 32
    }

    private func interpret(_ plain: [UInt8]) {
        guard plain.count >= 12 else {
            emit("短报文 \(hex(plain))")
            return
        }
        let command = plain[2]
        if watchMode && quietCommands.contains(command) {
            return
        }
        switch command {
        case 0x05:
            let echoed = UInt32(plain[5])
                | (UInt32(plain[6]) << 8)
                | (UInt32(plain[7]) << 16)
                | (UInt32(plain[8]) << 24)
            sawAuthPacket = true
            let matched = echoed == authCode
            if matched { sawAuthEcho = true }
            print("认证回显 \(String(format: "%08X", echoed))  \(matched ? "一致" : "不一致")  \(hex(plain.prefix(12)))")
        case 0x02:
            sawBattery = true
            let voltage = UInt16(plain[4]) | (UInt16(plain[5]) << 8)
            let battery = UInt16(plain[6]) | (UInt16(plain[7]) << 8)
            let charging = plain[10]
            print("电量 \(battery)%  电压 \(voltage) mV  充电标志 \(charging)  \(hex(plain.prefix(12)))")
        case 0x90:
            sawMicNR = true
            let level = plain[4]
            let low = plain[5]
            let high = plain[7]
            print("降噪档位 \(level)  低参数 \(low)  高参数 \(high)  \(hex(plain.prefix(12)))")
        default:
            emit("EVENT cmd \(String(format: "0x%02X", command))  \(hex(plain.prefix(16)))")
        }
    }

    private func send(_ message: DeviceMessage, label: String) {
        guard let device = vendorDevice else { return }
        let encrypted = FrameCodec.encrypt(message.bytes)
        var reportLength = intProperty(device, kIOHIDMaxOutputReportSizeKey as String) ?? 0
        if reportLength < 1 {
            reportLength = encrypted.count + 1
        }
        var buffer = [UInt8](repeating: 0, count: reportLength)
        var room = reportLength
        var offset = 0
        if reportID != 0, room > 0 {
            buffer[0] = reportID
            room -= 1
            offset = 1
        }
        let count = min(encrypted.count, room)
        buffer.replaceSubrange(offset..<(offset + count), with: encrypted.prefix(count))
        let result = buffer.withUnsafeBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), base, buffer.count)
        }
        if !watchMode || label.contains("直报") {
            emit("发出\(label)：\(statusName(result))")
        }
    }

    private func usagePage(of device: IOHIDDevice) -> Int {
        intProperty(device, kIOHIDDeviceUsagePageKey as String) ?? intProperty(device, kIOHIDPrimaryUsagePageKey as String) ?? -1
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func statusName(_ status: IOReturn) -> String {
        if status == kIOReturnSuccess { return "成功" }
        return String(format: "0x%08X", UInt32(bitPattern: status))
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let probe = Probe()
if arguments.first == "hooks-off" {
    probe.setHooks(enabled: false)
} else if arguments.first == "watch" {
    let rest = arguments.dropFirst()
    let hooks = rest.contains("hooks")
    let seconds = TimeInterval(rest.first { Double($0) != nil } ?? "") ?? 180
    probe.watch(seconds: seconds, hooks: hooks)
} else {
    let seconds = TimeInterval(arguments.first ?? "") ?? 12
    probe.run(seconds: seconds)
}
