import AppKit
import SwiftUI

/// 快捷键录制框。
///
/// 这是 AGENTS.md 里允许的唯一例外：只在用户点了录制框、并且它是设置窗口里的焦点时，
/// 通过本窗口自己的按键事件（响应链里的 keyDown / performKeyEquivalent / flagsChanged）读取一次组合键，
/// 录完立刻停止并交出焦点。不用 CGEventTap、NSEvent 监听或 IOHID，不申请「输入监控」，不写日志。
/// 系统先拦下的快捷键（⌘Tab、⌘空格、⌃←/→ 等）到不了这里，录不到，只能从预设里选。
///
/// 只按修饰键也能录（比如只按 Fn，或按住 Fn 再按左 Shift）：一直没按普通键、修饰键全部松开时，
/// 最后按下的那个修饰键当主键，前面按住的当修饰键。
final class RecorderNSView: NSView {
    var onStart: (@MainActor () -> Void)?
    var onLive: (@MainActor (String) -> Void)?
    var onStop: (@MainActor () -> Void)?
    var onRecord: (@MainActor (KeyCombo) -> Void)?

    private var isRecording = false
    /// 录制中现在按住的修饰键（键码，按按下的顺序）。
    private var heldModifiers: [UInt16] = []
    /// 这一下按过的所有修饰键（按按下的顺序），全部松开时用它组成组合。
    private var chord: [UInt16] = []

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stop()
        } else if window?.makeFirstResponder(self) == true {
            isRecording = true
            heldModifiers = []
            chord = []
            onStart?()
        }
    }

    /// 录制中卡片被收起（视图离开窗口）时也要停下。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isRecording {
            isRecording = false
            onStop?()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            onStop?()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    /// ⌘Q、⌘W 这类组合会先走这里，录制时也拦下来当成要录的键。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        capture(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let code = event.keyCode
        if ModifierKey.all[code] != nil {
            if heldModifiers.contains(code) {
                heldModifiers.removeAll { $0 == code }
            } else {
                heldModifiers.append(code)
                if !chord.contains(code) { chord.append(code) }
            }
            if heldModifiers.isEmpty, let last = chord.last {
                // 只按了修饰键，现在全部松开了：录下来。
                var combo = KeyCombo(keyCode: last)
                for code in chord.dropLast() {
                    switch code {
                    case 63: combo.fn = true
                    case 56, 60: combo.shift = true
                    case 59, 62: combo.control = true
                    case 58, 61: combo.option = true
                    case 55, 54: combo.command = true
                    default: break
                    }
                }
                stop()
                onRecord?(combo)
                return
            }
        }
        onLive?(liveSymbols(event.modifierFlags))
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags
        // Fn 看是不是真的按住了 Fn 键：方向键、F1–F12 这些键系统自己就会带上 Fn 标志。
        let combo = KeyCombo(
            keyCode: event.keyCode,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            fn: heldModifiers.contains(ModifierKey.fn)
        )
        stop()
        onRecord?(combo)
    }

    private func liveSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        (heldModifiers.contains(ModifierKey.fn) ? "Fn " : "") + Self.symbols(flags)
    }

    private func stop() {
        isRecording = false
        heldModifiers = []
        chord = []
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
        onStop?()
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }
}

private struct RecorderRepresentable: NSViewRepresentable {
    let onStart: @MainActor () -> Void
    let onLive: @MainActor (String) -> Void
    let onStop: @MainActor () -> Void
    let onRecord: @MainActor (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {
        update(view)
    }

    private func update(_ view: RecorderNSView) {
        view.onStart = onStart
        view.onLive = onLive
        view.onStop = onStop
        view.onRecord = onRecord
    }
}

/// 录制框的样子：没在录时提示「点这里」，录制中描强调色、显示正在按住的修饰键。
struct ShortcutRecorderRow: View {
    @ObservedObject var ui: MappingUIState
    let accent: Color
    let onRecord: (KeyCombo) -> Void

    var body: some View {
        let recording = ui.recordingLive != nil
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: recording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(recording ? accent : .secondary)
                Text(prompt).font(.callout)
                Spacer()
                if recording {
                    Text("再点一下取消").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(recording ? accent.opacity(0.12) : Palette.raised.opacity(0.55)))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(recording ? accent : Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: recording ? 1.5 : 1, dash: recording ? [] : [4, 3]))
            )
            RecorderRepresentable(
                onStart: { ui.recordingLive = "" },
                onLive: { ui.recordingLive = $0 },
                onStop: { ui.recordingLive = nil },
                onRecord: { onRecord($0) }
            )
        }
        .frame(height: 40)
    }

    private var prompt: String {
        guard let live = ui.recordingLive else { return "点这里录制：然后在键盘上按下组合键" }
        return live.isEmpty ? "请按下组合键…" : "\(live) …"
    }
}
