import Foundation
import IOKit
import IOKit.hid

/// 调试用。只匹配 AU05 自己的键盘、鼠标和消费类接口，不独占设备。
/// 打开键盘接口会让系统要求「输入监控」。正式版本不走这里。
public final class KeyboardMonitor: @unchecked Sendable {
    public var onNote: ((String) -> Void)?
    public var onInputMonitoring: ((Bool) -> Void)?

    private let vendorID = 65521
    private let productID = 221
    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var lastSignature: String?

    public init() {}

    public func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let match: [[String: Any]] = [
            usage(page: 0x01, usage: 0x06),
            usage(page: 0x01, usage: 0x02),
            usage(page: 0x0C, usage: 0x01),
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, match as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        onInputMonitoring?(opened != kIOReturnNotPermitted)
    }

    private func usage(page: Int, usage: Int) -> [String: Any] {
        [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
            kIOHIDDeviceUsagePageKey as String: page,
            kIOHIDDeviceUsageKey as String: usage,
        ]
    }

    private func attach(_ device: IOHIDDevice) {
        if devices.contains(where: { CFEqual($0, device) }) { return }
        devices.append(device)
        let size = max(intProperty(device, kIOHIDMaxInputReportSizeKey as String) ?? 64, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        buffers.append(buffer)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, result, _, _, reportID, report, length in
            guard let context, result == kIOReturnSuccess else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
            Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue().receive(reportID: reportID, bytes: bytes)
        }, context)
    }

    private func receive(reportID: UInt32, bytes: [UInt8]) {
        var payload = bytes
        var id = Int(reportID)
        if id == 0, let first = payload.first {
            id = Int(first)
            payload.removeFirst()
        } else if let first = payload.first, first == UInt8(id & 0xFF) {
            payload.removeFirst()
        }
        let signature: String
        switch id {
        case 3:
            guard payload.count >= 3 else { return }
            let keys = payload.dropFirst(2).prefix(6).filter { $0 != 0 }.map { String(format: "%02X", $0) }.joined(separator: " ")
            signature = "键盘口 键 \(keys) 修饰 \(String(format: "%02X", payload[0]))"
        case 2:
            guard payload.count >= 4 else { return }
            let wheel = Int8(bitPattern: payload[3])
            let pan = payload.count > 4 ? Int8(bitPattern: payload[4]) : 0
            guard payload[0] != 0 || wheel != 0 || pan != 0 else { return }
            signature = "键盘口 鼠标 按键 \(payload[0]) 滚轮 \(wheel) 平移 \(pan)"
        default:
            guard payload.contains(where: { $0 != 0 }) else { return }
            let hex = payload.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            signature = "键盘口 报告 \(id) \(hex)"
        }
        guard signature != lastSignature else { return }
        lastSignature = signature
        onNote?(signature)
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }
}
