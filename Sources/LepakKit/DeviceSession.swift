import Foundation
import IOKit
import IOKit.hid

final class HIDLoop: @unchecked Sendable {
    var runLoop: CFRunLoop?
}

public struct VendorKeyEvent: Sendable, Equatable {
    public var index: Int
    public var status: Int
    public var physicalIndex: Int
}

public final class DeviceSession: @unchecked Sendable {
    public var onStatus: ((PowerStatus?) -> Void)?
    public var onVendorKey: ((VendorKeyEvent) -> Void)?
    public var onVendorPacket: ((String) -> Void)?
    public var onNote: ((String) -> Void)?

    private let vendorID = 65521
    private let productID = 221
    private let usagePage = 0xFFFC
    private let reportID: UInt8 = 0x55
    private let loop = HIDLoop()
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var status: PowerStatus?

    public init() {}

    /// 打开配置口（单独一条 HID 线程）。已经开着就什么都不做；`stop()` 之后可以再调用。
    public func start() {
        guard loop.runLoop == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            let match: [String: Any] = [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDDeviceUsagePageKey as String: usagePage,
                kIOHIDDeviceUsageKey as String: 1,
            ]
            IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<DeviceSession>.fromOpaque(context).takeUnretainedValue().attach(device)
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<DeviceSession>.fromOpaque(context).takeUnretainedValue().detach(device)
            }, context)
            guard let runLoop = CFRunLoopGetCurrent() else {
                ready.signal()
                return
            }
            self.loop.runLoop = runLoop
            IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if opened != kIOReturnSuccess {
                self.onNote?("配置口打开失败")
                self.publish(nil)
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Lepak HID"
        thread.start()
        ready.wait()
    }

    /// 关掉配置口、结束 HID 线程（用户在 Lepak 里移除了 AU05）。之后不再收按键、不再发心跳。
    public func stop() {
        guard let runLoop = loop.runLoop else { return }
        loop.runLoop = nil
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            if let manager {
                IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            manager = nil
            device = nil
            status = nil
            CFRunLoopStop(runLoop)
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        // HID 线程万一已经退出，不能让主线程一直等下去。
        _ = done.wait(timeout: .now() + 1)
    }

    public func refresh() {
        send(DeviceMessage.batteryQuery())
    }

    public func keepAlive() {
        send(DeviceMessage.heartbeat())
    }

    public func introduce() {
        send(DeviceMessage.activeQuery())
        for index in UInt8(0)...5 {
            let delay = 0.15 * Double(index + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.send(DeviceMessage.shortcutQuery(index: index))
            }
        }
    }

    private func attach(_ device: IOHIDDevice) {
        if let current = self.device, CFEqual(current, device) {
            refresh()
            return
        }
        self.device = device
        onNote?("配置口已连接")
        let size = max(intProperty(device, kIOHIDMaxInputReportSizeKey as String) ?? 64, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        reportBuffer?.deallocate()
        reportBuffer = buffer
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, result, _, _, reportID, report, length in
            guard let context, result == kIOReturnSuccess else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
            Unmanaged<DeviceSession>.fromOpaque(context).takeUnretainedValue().receive(reportID: reportID, bytes: bytes)
        }, context)
        send(DeviceMessage.heartbeat())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
            self?.introduce()
        }
    }

    private func detach(_ device: IOHIDDevice) {
        guard let current = self.device, CFEqual(current, device) else { return }
        self.device = nil
        publish(nil)
    }

    private func receive(reportID: UInt32, bytes: [UInt8]) {
        var payload = bytes
        if reportID != 0, payload.first == UInt8(reportID & 0xFF) {
            payload.removeFirst()
        }
        guard payload.count >= 8 else { return }
        let plain = FrameCodec.decrypt(payload)
        if plain.count >= 5, plain[1] == 0x10 {
            onVendorKey?(VendorKeyEvent(
                index: Int(plain[2]),
                status: Int(plain[3]),
                physicalIndex: Int(plain[4])
            ))
            return
        }
        if let next = PowerReport.parse(plain) {
            guard next != status else { return }
            publish(next)
            return
        }
        let kind = plain.count > 2 ? plain[2] : 0
        let quiet: Set<UInt8> = [0x02, 0x05, 0x23, 0x89, 0x90]
        guard !quiet.contains(kind), plain.count > 1, plain[1] != 0x7B else { return }
        let hex = plain.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        onVendorPacket?("配置口 \(hex)")
    }

    private func publish(_ status: PowerStatus?) {
        self.status = status
        onStatus?(status)
    }

    private func send(_ message: DeviceMessage) {
        guard let runLoop = loop.runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            self.write(message)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func write(_ message: DeviceMessage) {
        guard let device else { return }
        let encrypted = FrameCodec.encrypt(message.bytes)
        var reportLength = intProperty(device, kIOHIDMaxOutputReportSizeKey as String) ?? 0
        if reportLength < 1 {
            reportLength = encrypted.count + 1
        }
        var buffer = [UInt8](repeating: 0, count: reportLength)
        var room = reportLength
        var offset = 0
        if room > 0 {
            buffer[0] = reportID
            room -= 1
            offset = 1
        }
        let count = min(encrypted.count, room)
        buffer.replaceSubrange(offset..<(offset + count), with: encrypted.prefix(count))
        _ = buffer.withUnsafeBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), base, buffer.count)
        }
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }
}
