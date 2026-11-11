import AppKit
import CoreGraphics
import Foundation

private final class KeyEchoState: @unchecked Sendable {
    var port: CFMachPort?
}

private let keyEchoState = KeyEchoState()

private func keyEchoCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = keyEchoState.port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        DebugLog.write("系统按键监听中断后已恢复")
        return Unmanaged.passUnretained(event)
    }
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let edge: String
    switch type {
    case .keyDown: edge = "按下"
    case .keyUp: edge = "松开"
    case .flagsChanged: edge = "标志"
    default: edge = "其他"
    }
    DebugLog.write(
        "系统按键 \(edge) 键 \(key) 标志 \(keyEchoFlags(event.flags)) 来源 \(keyEchoSource(event))"
    )
    return Unmanaged.passUnretained(event)
}

/// 进程号 0 是真实硬件（包括 AU05 自己的键盘口），其他是某个程序模拟出来的。
private func keyEchoSource(_ event: CGEvent) -> String {
    if event.getIntegerValueField(.eventSourceUserData) == FunctionKey.marker {
        return "本程序"
    }
    let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
    if pid == 0 {
        return "硬件"
    }
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "未知"
    return "\(name)(\(pid))"
}

private func keyEchoFlags(_ flags: CGEventFlags) -> String {
    var names: [String] = []
    if flags.contains(.maskSecondaryFn) { names.append("Fn") }
    if flags.contains(.maskCommand) { names.append("Command") }
    if flags.contains(.maskShift) { names.append("Shift") }
    if flags.contains(.maskAlternate) { names.append("Option") }
    if flags.contains(.maskControl) { names.append("Control") }
    return names.isEmpty ? "无" : names.joined(separator: "+")
}

enum KeyEcho {
    static func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: keyEchoCallback,
            userInfo: nil
        ) else {
            return false
        }
        keyEchoState.port = port
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0),
              let loop = CFRunLoopGetMain()
        else { return false }
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
}
