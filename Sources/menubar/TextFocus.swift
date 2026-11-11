import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private final class TextFocusState: @unchecked Sendable {
    let lock = NSLock()
    /// 已经替它打开过辅助功能树的 App（Electron / Chromium），免得每次都设一遍。
    var enabledApps: Set<pid_t> = []
}

/// 判断旋钮该移动光标还是滚动。
///
/// 只读焦点控件的类型和位置（辅助功能 API），不读里面的文字，也不监听键盘。
/// 规则：焦点在可编辑的文本控件上，并且鼠标指针停在这个输入框上 → 移动光标；否则 → 滚动。
/// 光看焦点不够：聊天类 App 的输入框几乎一直有焦点，那样就永远滚不动聊天记录了。
enum TextFocus {
    struct Decision {
        let moveCaret: Bool
        /// 写进日志的原因，方便调规则。
        let reason: String
    }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]
    /// 每次跨进程查询最多等这么久，某个 App 卡住时不拖累旋钮。
    private static let timeout: Float = 0.25
    /// 看得见的输入框四周通常有内边距，比系统报告的文本区大一圈；鼠标在这个范围内也算。
    private static let margin: CGFloat = 12
    private static let state = TextFocusState()

    static func decide() -> Decision {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var (app, appError) = copyElement(system, kAXFocusedApplicationAttribute)
        var fallback = ""
        if app == nil, let front = NSWorkspace.shared.frontmostApplication {
            // 系统级查询偶尔会失败（比如超时），退回用前台 App 的进程号。
            app = AXUIElementCreateApplication(front.processIdentifier)
            fallback = "（系统查询失败 \(appError.rawValue)，改用前台进程）"
        }
        guard let app else {
            return Decision(moveCaret: false, reason: "取不到前台 App，错误 \(appError.rawValue)")
        }
        AXUIElementSetMessagingTimeout(app, timeout)
        let name = appName(app) + fallback

        var (focused, focusError) = copyElement(app, kAXFocusedUIElementAttribute)
        if focused.map({ !textRoles.contains(role(of: $0)) }) ?? true, enableAccessibilityTree(of: app) {
            // Electron / Chromium 默认不开放辅助功能树，打开后再取一次。
            (focused, focusError) = copyElement(app, kAXFocusedUIElementAttribute)
        }
        guard let focused else {
            return Decision(moveCaret: false, reason: "\(name) 没有焦点控件，错误 \(focusError.rawValue)")
        }
        let role = role(of: focused)
        guard textRoles.contains(role) else {
            return Decision(moveCaret: false, reason: "\(name) 焦点在 \(role)")
        }
        let valueSettable = settable(focused, kAXValueAttribute)
        let rangeSettable = settable(focused, kAXSelectedTextRangeAttribute)
        let detail = "\(name) \(role) 值可写:\(valueSettable ? "是" : "否") 选区可写:\(rangeSettable ? "是" : "否")"
        // 文本框、搜索框本身就是输入控件；文本区可能只读（比如日志窗口），要能写才算输入框。
        guard role != kAXTextAreaRole as String || valueSettable || rangeSettable else {
            return Decision(moveCaret: false, reason: "只读 \(detail)")
        }
        guard let frame = frame(of: focused) else {
            return Decision(moveCaret: false, reason: "取不到位置 \(detail)")
        }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let where_ = "输入框 \(describe(frame)) 鼠标 \(Int(pointer.x)),\(Int(pointer.y))"
        if frame.insetBy(dx: -margin, dy: -margin).contains(pointer) {
            return Decision(moveCaret: true, reason: "\(detail) \(where_)")
        }
        if pointerOnInputContainer(app: app, focused: focused, frame: frame, pointer: pointer) {
            return Decision(moveCaret: true, reason: "\(detail) 鼠标在输入框外框上 \(where_)")
        }
        return Decision(moveCaret: false, reason: "鼠标不在输入框上 \(detail) \(where_)")
    }

    /// 鼠标是不是在输入框的外框上（比如输入框四周的留白、占位文字）。
    /// 从输入框往上找最多 3 层父控件当「外框」，只算不比输入框大太多的，免得把整个窗口都算进去；
    /// 鼠标下面的控件（或它往上 4 层内的父控件）是其中之一就算。
    private static func pointerOnInputContainer(app: AXUIElement, focused: AXUIElement, frame: CGRect, pointer: CGPoint) -> Bool {
        var containers: [AXUIElement] = [focused]
        var current = focused
        for _ in 0..<3 {
            guard let parent = copyElement(current, kAXParentAttribute).0,
                  let parentFrame = self.frame(of: parent),
                  parentFrame.height <= max(frame.height * 3, 240),
                  parentFrame.width <= frame.width + 240
            else { break }
            containers.append(parent)
            current = parent
        }
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(pointer.x), Float(pointer.y), &hitRef) == .success,
              var hit = hitRef
        else { return false }
        for _ in 0..<5 {
            if containers.contains(where: { CFEqual($0, hit) }) { return true }
            guard let parent = copyElement(hit, kAXParentAttribute).0 else { return false }
            hit = parent
        }
        return false
    }

    /// 给 Electron 应用打开辅助功能树。返回 true 表示这次刚打开，值得再查一次。
    private static func enableAccessibilityTree(of app: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return false }
        state.lock.lock()
        let already = state.enabledApps.contains(pid)
        state.enabledApps.insert(pid)
        state.lock.unlock()
        guard !already else { return false }
        let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return result == .success
    }

    private static func appName(_ app: AXUIElement) -> String {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return "未知 App" }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    private static func copyElement(_ parent: AXUIElement, _ attribute: String) -> (AXUIElement?, AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error) }
        return ((value as! AXUIElement), error)
    }

    private static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return "?" }
        return (value as? String) ?? "?"
    }

    private static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var result: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success else { return false }
        return result.boolValue
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }
}
