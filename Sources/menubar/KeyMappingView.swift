import AppKit
import SwiftUI

// MARK: 设备图

/// 设备图上可以点的位置。
enum Hotspot: Hashable {
    case knob, mic, check, cancel
}

/// 一个外观主题的 AU05 图和图上各按键的位置。位置是 0–1 的比例，左上角为原点，按 Support 里的图量出来；
/// 打包时没有这张图（比如直接 swift run）就用代码画的简图，位置和真图对齐。
struct DeviceArt: Sendable {
    enum Sketch: Sendable { case au05, passport }
    /// Resources 里的图片名。
    let imageName: String
    /// 没有图片时画哪种简图。
    var sketch = Sketch.au05
    /// 宽 / 高。
    let aspect: CGFloat
    let centers: [Hotspot: CGPoint]
    /// 高亮圈的半径，按图宽的比例。
    let radii: [Hotspot: CGFloat]

    var image: NSImage? { NSImage(named: imageName) }

    /// 标准版：DeviceArt.png，309×1000。
    static let standard = DeviceArt(
        imageName: "DeviceArt",
        aspect: 0.309,
        centers: [
            .knob: CGPoint(x: 0.405, y: 0.320),
            .mic: CGPoint(x: 0.420, y: 0.543),
            .check: CGPoint(x: 0.420, y: 0.703),
            .cancel: CGPoint(x: 0.420, y: 0.860),
        ],
        radii: [.knob: 0.38, .mic: 0.28, .check: 0.28, .cancel: 0.28]
    )

    /// WorkBuddy 版：DeviceArtWorkBuddy.png，308×1000。和标准版同一构图，只有旋钮略窄、略靠右。
    static let workBuddy = DeviceArt(
        imageName: "DeviceArtWorkBuddy",
        aspect: 0.308,
        centers: [
            .knob: CGPoint(x: 0.420, y: 0.320),
            .mic: CGPoint(x: 0.420, y: 0.543),
            .check: CGPoint(x: 0.420, y: 0.703),
            .cancel: CGPoint(x: 0.420, y: 0.860),
        ],
        radii: [.knob: 0.37, .mic: 0.28, .check: 0.28, .cancel: 0.28]
    )

    /// AI Passport：没有实拍图，用代码画（`PassportSketch`）。竖着的卡片，上面是屏幕，屏幕右边从上到下是上键、OK、下键。
    static let passport = DeviceArt(
        imageName: "PassportArt",
        sketch: .passport,
        aspect: 0.64,
        centers: [
            .check: CGPoint(x: 0.885, y: 0.200),
            .mic: CGPoint(x: 0.885, y: 0.335),
            .cancel: CGPoint(x: 0.885, y: 0.470),
        ],
        radii: [.check: 0.085, .mic: 0.085, .cancel: 0.085]
    )

    static func of(_ theme: DeviceTheme) -> DeviceArt {
        switch theme {
        case .standard: return .standard
        case .workBuddy: return .workBuddy
        }
    }

    /// 某台设备在设置里用的图。AU05 跟着款式走。
    static func of(_ kind: DeviceKind, theme: DeviceTheme) -> DeviceArt {
        switch kind {
        case .au05: return of(theme)
        case .passport: return .passport
        }
    }

    /// 图上能点的位置，按从上到下的顺序。
    var spots: [Hotspot] {
        [Hotspot.knob, .check, .mic, .cancel].filter { centers[$0] != nil }
            .sorted { centers[$0]!.y < centers[$1]!.y }
    }
}

/// 设备图，选中的按键套一圈强调色；`onTap` 为 nil 时只是展示。
struct DeviceArtView: View {
    let art: DeviceArt
    let accent: Color
    var highlighted: Hotspot?
    var onTap: ((Hotspot) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if let image = art.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                } else if art.sketch == .passport {
                    PassportSketch(size: size)
                } else {
                    SketchDevice(art: art, size: size)
                }
                if let onTap {
                    ForEach(art.spots, id: \.self) { spot in
                        let center = art.centers[spot]!
                        let radius = (art.radii[spot] ?? 0.3) * size.width
                        Circle()
                            .strokeBorder(accent, lineWidth: highlighted == spot ? 2.5 : 0)
                            .background(Circle().fill(accent.opacity(highlighted == spot ? 0.12 : 0.001)))
                            .shadow(color: accent.opacity(highlighted == spot ? 0.45 : 0), radius: 8)
                            .frame(width: radius * 2, height: radius * 2)
                            .position(x: center.x * size.width, y: center.y * size.height)
                            .onTapGesture { onTap(spot) }
                            .help(spotName(spot))
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }

    private func spotName(_ spot: Hotspot) -> String {
        let passport = art.sketch == .passport
        switch spot {
        case .knob: return "旋钮"
        case .mic: return passport ? "OK 键" : "语音键"
        case .check: return passport ? "上键" : "确定键"
        case .cancel: return passport ? "下键" : "取消键"
        }
    }
}

/// AI Passport 的简图：深色机身，上面一块竖屏，屏幕右边三个圆键（上、OK、下），下半截是喇叭孔。
/// 键的位置和 `DeviceArt.passport` 对齐。
private struct PassportSketch: View {
    let size: CGSize

    var body: some View {
        let w = size.width
        let h = size.height
        let art = DeviceArt.passport
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: w * 0.10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: w * 0.10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            // 屏幕：240×320 竖屏。
            RoundedRectangle(cornerRadius: w * 0.03, style: .continuous)
                .fill(Color(red: 0.04, green: 0.07, blue: 0.06))
                .overlay(
                    VStack(spacing: h * 0.012) {
                        Text("READY").font(.system(size: w * 0.075, weight: .bold, design: .monospaced))
                        Text("LEPAK").font(.system(size: w * 0.045, weight: .medium, design: .monospaced)).opacity(0.6)
                    }
                    .foregroundStyle(Color(red: 0.45, green: 0.95, blue: 0.6))
                )
                .overlay(RoundedRectangle(cornerRadius: w * 0.03, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .frame(width: w * 0.66, height: w * 0.66 * 4 / 3)
                .position(x: w * 0.42, y: h * 0.335)
            ForEach([Hotspot.check, .mic, .cancel], id: \.self) { spot in
                let center = art.centers[spot]!
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.24)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .overlay(Image(systemName: spot == .check ? "chevron.up" : spot == .cancel ? "chevron.down" : "circle.fill")
                        .font(.system(size: w * (spot == .mic ? 0.035 : 0.05), weight: .bold))
                        .foregroundStyle(Color(white: 0.75)))
                    .frame(width: w * 0.11, height: w * 0.11)
                    .position(x: center.x * w, y: center.y * h)
            }
            // 喇叭孔。
            VStack(spacing: w * 0.035) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: w * 0.035) {
                        ForEach(0..<7, id: \.self) { _ in
                            Circle().fill(Color.black.opacity(0.55)).frame(width: w * 0.03, height: w * 0.03)
                        }
                    }
                }
            }
            .position(x: w * 0.5, y: h * 0.80)
        }
        .frame(width: w, height: h)
    }
}

/// 没有设备图时的简图：银色机身、旋钮、三个键帽。
private struct SketchDevice: View {
    let art: DeviceArt
    let size: CGSize

    var body: some View {
        let w = size.width
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: w * 0.12)
                .fill(LinearGradient(colors: [Color(white: 0.90), Color(white: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: w * 0.05) {
                ForEach(0..<6, id: \.self) { _ in
                    Capsule().fill(Color(white: 0.45)).frame(width: w * 0.06, height: w * 0.22)
                }
            }
            .position(x: w * 0.5, y: size.height * 0.13)
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.80)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color(white: 0.7), lineWidth: 1))
                .frame(width: w * 0.78, height: w * 0.78)
                .position(x: w * 0.5, y: art.centers[.knob]!.y * size.height)
            ForEach([Hotspot.mic, .check, .cancel], id: \.self) { spot in
                RoundedRectangle(cornerRadius: w * 0.06)
                    .fill(Color(white: 0.97))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.06).stroke(Color(white: 0.75), lineWidth: 1))
                    .overlay(Image(systemName: spot == .mic ? "mic" : spot == .check ? "checkmark.circle" : "xmark.circle")
                        .font(.system(size: w * 0.18)).foregroundStyle(Color(white: 0.45)))
                    .frame(width: w * 0.62, height: w * 0.62)
                    .position(x: w * 0.5, y: art.centers[spot]!.y * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: 控件和它们现在做什么

/// AU05 上可以设置的控件。按键页一张卡片一个。
enum MappingControl: String, CaseIterable, Identifiable {
    case voice, confirm, cancel, knobPress, knobTurn, knobPressTurn

    var id: String { rawValue }
    var title: String {
        switch self {
        case .voice: return "语音键"
        case .confirm: return "确定键"
        case .cancel: return "取消键"
        case .knobPress: return "旋钮 · 按下"
        case .knobTurn: return "旋钮 · 转动"
        case .knobPressTurn: return "旋钮 · 按住转动"
        }
    }
    var systemImage: String {
        switch self {
        case .voice: return "mic"
        case .confirm: return "checkmark"
        case .cancel: return "xmark"
        case .knobPress: return "smallcircle.filled.circle"
        case .knobTurn: return "arrow.left.and.right"
        case .knobPressTurn: return "rectangle.split.3x1"
        }
    }
    var hotspot: Hotspot {
        switch self {
        case .voice: return .mic
        case .confirm: return .check
        case .cancel: return .cancel
        case .knobPress, .knobTurn, .knobPressTurn: return .knob
        }
    }
    /// 按键页里卡片放在设备左边还是右边：AU05 三个键在左，旋钮在右；AI Passport 的键在机身右边，卡片都在右边。
    func onLeft(on device: DeviceKind) -> Bool {
        switch device {
        case .au05: return [.voice, .confirm, .cancel].contains(self)
        case .passport: return false
        }
    }

    /// 在某台设备上的名字（AI Passport 的键按样子叫：OK 键、上键、下键）。
    func title(on device: DeviceKind) -> String {
        GestureKey(control: self)?.title(on: device) ?? title
    }

    func systemImage(on device: DeviceKind) -> String {
        guard device == .passport else { return systemImage }
        switch self {
        case .voice: return "circle.circle"
        case .confirm: return "chevron.up"
        case .cancel: return "chevron.down"
        default: return systemImage
        }
    }
}

/// 弹出设置的目标：卡片里的每一行。
enum EditTarget: Hashable {
    /// 语音 / 确定 / 取消键的单击。
    case single(GestureKey)
    /// 语音 / 确定 / 取消键另外开启的长按或双击。
    case gesture(GestureKey, KeyGesture)
    case knobShort, knobLong, knobTurn, knobPressTurn
}

extension GestureKey {
    var control: MappingControl {
        switch self {
        case .voice: return .voice
        case .confirm: return .confirm
        case .cancel: return .cancel
        }
    }

    init?(control: MappingControl) {
        guard let key = Self.allCases.first(where: { $0.control == control }) else { return nil }
        self = key
    }
}

/// 按键页的界面状态（选中哪张卡片、正在编辑哪一项、录制中按住的修饰键）。
/// 这台机器只有命令行工具，SwiftUI 的 @State 宏用不了，所以放在一个可观察对象里，由 SettingsModel 持有。
@MainActor
final class MappingUIState: ObservableObject {
    @Published private(set) var selected: MappingControl?
    /// 正在弹出设置的那一行。
    @Published var editing: EditTarget?
    /// 正在录制组合键时，当前按住的修饰键（比如「⌘⇧」）；没在录制时为 nil。
    @Published var recordingLive: String?
    /// 「自定义」里选按键的弹出面板是否打开。
    @Published var keyPickerOpen = false

    func select(_ control: MappingControl?) {
        guard control != selected else { return }
        selected = control
        closeEditor()
    }

    func edit(_ target: EditTarget, of control: MappingControl) {
        selected = control
        recordingLive = nil
        keyPickerOpen = false
        editing = target
    }

    func closeEditor() {
        editing = nil
        recordingLive = nil
        keyPickerOpen = false
    }
}

// MARK: 按键页

private enum AnchorID: Hashable {
    case card(MappingControl)
    case art
}

private struct AnchorsKey: PreferenceKey {
    static let defaultValue: [AnchorID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [AnchorID: Anchor<CGRect>], nextValue: () -> [AnchorID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 按键页：设备在中间当主角，背后一圈主题色的光；两侧卡片用引线连到对应的按键上。
/// 点设备上的键或卡片选中它；点卡片里的一行，弹出这一项的设置。
struct KeysPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var ui: MappingUIState
    let kind: DeviceKind

    /// 配色：AU05 跟着它的款式；别的设备没有款式，用标准配色。
    private var theme: DeviceTheme { kind == .au05 ? model.theme : .standard }
    private var art: DeviceArt { DeviceArt.of(kind, theme: theme) }
    private var flash: DeviceAction? { model.flash?.device == kind ? model.flash : nil }

    /// 展台的尺寸：设备图高度、两侧卡片宽度、卡片和设备之间的最小间距。
    private struct StageSize {
        let artHeight: CGFloat
        let cardWidth: CGFloat
        let gap: CGFloat
    }
    /// 窗口够大时用标准尺寸（约 790pt 宽、480pt 高）；放不下就换紧凑尺寸（约 690×400，窗口最小 1000×660 时也放得下）。
    private static let regular = StageSize(artHeight: 480, cardWidth: 264, gap: 36)
    private static let compact = StageSize(artHeight: 400, cardWidth: 248, gap: 16)

    /// 选中的或刚刚触发的控件，卡片、引线和按键会亮起来。
    private func isLit(_ control: MappingControl) -> Bool {
        ui.selected == control || flash?.control == control
    }

    private var litSpot: Hotspot? {
        (flash?.control ?? ui.selected)?.hotspot
    }

    /// 设备页的按键展台（标题、款式切换和「恢复默认」在设备页顶上）。
    /// 占满标题下面剩下的地方：宽和高都放得下标准尺寸就用标准尺寸，否则用紧凑尺寸；
    /// 紧凑尺寸也放不下（窗口很矮、长按双击全开、又有提醒条）就让紧凑展台上下滚动，不把窗口撑高。
    var body: some View {
        ViewThatFits(in: [.horizontal, .vertical]) {
            stage(Self.regular)
            stage(Self.compact)
            ScrollView(.vertical) {
                stage(Self.compact)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    // MARK: 展台

    private func stage(_ size: StageSize) -> some View {
        let artHeight = size.artHeight
        let glow = artHeight * 500 / 480
        let left = kind.controls.filter { $0.onLeft(on: kind) }
        return HStack(alignment: .center, spacing: 0) {
            // 卡片都在一边时（AI Passport）不留另一边的空列，设备和卡片一起居中。
            if !left.isEmpty {
                column(left, width: size.cardWidth)
                Spacer(minLength: size.gap)
            }
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [theme.glow.opacity(0.34), theme.glow.opacity(0)],
                                         center: .center, startRadius: 10, endRadius: glow / 2))
                    .frame(width: glow, height: glow)
                    .allowsHitTesting(false)
                DeviceArtView(art: art, accent: theme.accent, highlighted: litSpot) { spot in
                    if spot != ui.selected?.hotspot {
                        ui.select(kind.controls.first { $0.hotspot == spot })
                    }
                }
                .frame(width: artHeight * art.aspect, height: artHeight)
                .anchorPreference(key: AnchorsKey.self, value: .bounds) { [.art: $0] }
            }
            .frame(width: artHeight * art.aspect + 40, height: artHeight)
            .zIndex(-1)
            if left.isEmpty {
                Color.clear.frame(width: size.gap * 2, height: 1)
            } else {
                Spacer(minLength: size.gap)
            }
            column(kind.controls.filter { !$0.onLeft(on: kind) }, width: size.cardWidth)
        }
        .frame(maxWidth: .infinity)
        .overlayPreferenceValue(AnchorsKey.self) { anchors in
            GeometryReader { proxy in
                leaderLines(anchors: anchors, proxy: proxy)
            }
            .allowsHitTesting(false)
        }
    }

    private func column(_ controls: [MappingControl], width: CGFloat) -> some View {
        VStack(spacing: 14) {
            ForEach(controls) { control in
                card(control)
                    .anchorPreference(key: AnchorsKey.self, value: .bounds) { [.card(control): $0] }
            }
        }
        .frame(width: width)
    }

    // MARK: 卡片

    private func card(_ control: MappingControl) -> some View {
        let lit = isLit(control)
        let accent = theme.accent
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: control.systemImage(on: kind))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(lit ? accent : Color.primary.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(lit ? accent.opacity(0.15) : Palette.raised))
                Text(control.title(on: kind)).font(.system(size: 15, weight: .semibold))
                Spacer()
                if let key = GestureKey(control: control) {
                    addGestureButtons(key)
                }
            }
            rows(control)
        }
        .card(padding: 12, radius: 18, highlight: lit ? accent : nil)
        .contentShape(Rectangle())
        .onTapGesture { ui.select(control) }
        .animation(.easeOut(duration: 0.2), value: lit)
    }

    @ViewBuilder private func rows(_ control: MappingControl) -> some View {
        let c = model.config
        switch control {
        case .voice, .confirm, .cancel:
            if let key = GestureKey(control: control) {
                VStack(spacing: 6) {
                    row("单击", target: .single(key), control: control) {
                        comboLabel(c[keyPath: key.singlePath(kind)])
                    }
                    ForEach(KeyGesture.allCases) { gesture in
                        if let combo = c[keyPath: key.gesturePath(gesture, kind)] {
                            row(gesture.title, target: .gesture(key, gesture), control: control) {
                                comboLabel(combo)
                            }
                        }
                    }
                }
            }
        case .knobPress:
            row("短按", target: .knobShort, control: control) { comboLabel(c.knobShortPress) }
            row("长按", target: .knobLong, control: control) {
                ComboKeycaps(combo: c.knobLongPress, small: true)
                Text(String(format: "%.1f 秒", c.longPressSeconds)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        case .knobTurn:
            row("左右转", target: .knobTurn, control: control) {
                Text("滚动 \(c.scrollLines) 行\(c.reverseScroll ? "（反向）" : "")").font(.system(size: 13))
            }
            row("输入框里", target: .knobTurn, control: control) {
                Text(c.caretInTextFields ? "移动光标" : "也滚动").font(.system(size: 13))
            }
        case .knobPressTurn:
            row("左右转", target: .knobPressTurn, control: control) {
                if c.switchSpacesWhilePressed {
                    ComboKeycaps(combo: KeyCombo(keyCode: 123, control: true), small: true)
                    ComboKeycaps(combo: KeyCombo(keyCode: 124, control: true), small: true)
                } else {
                    Text("已关闭").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 卡片标题右边的小按钮：「+ 长按」「+ 双击」，已经开启的不再显示。点了先给一个常用组合并弹出设置。
    @ViewBuilder private func addGestureButtons(_ key: GestureKey) -> some View {
        HStack(spacing: 4) {
            ForEach(KeyGesture.allCases) { gesture in
                let path = key.gesturePath(gesture, kind)
                if model.config[keyPath: path] == nil {
                    Button {
                        model.config[keyPath: path] = key.suggestedCombo(gesture)
                        ui.edit(.gesture(key, gesture), of: key.control)
                    } label: {
                        Text("+ \(gesture.title)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Capsule().fill(Palette.raised))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(gesture == .long ? "开启长按：按住发另一个组合键" : "开启双击：快速按两下发另一个组合键")
                }
            }
        }
    }

    @ViewBuilder private func comboLabel(_ combo: KeyCombo) -> some View {
        ComboKeycaps(combo: combo, small: true)
        if let label = combo.label, label != combo.parts.last {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    /// 卡片里的一行：左边是动作（单击 / 长按 …），右边是现在发什么；点一下弹出设置。
    private func row<Trailing: View>(
        _ label: String, target: EditTarget?, control: MappingControl,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        Button {
            if let target {
                ui.edit(target, of: control)
            } else {
                ui.select(control)
            }
        } label: {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                trailing().lineLimit(1)
                if target != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(target != nil && ui.editing == target ? theme.accent.opacity(0.12) : Palette.raised.opacity(0.6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(
            get: { target != nil && ui.editing == target },
            set: { if !$0 { ui.closeEditor() } }
        ), arrowEdge: control.onLeft(on: kind) ? .leading : .trailing) {
            if let target { editor(for: target) }
        }
    }

    // MARK: 弹出的设置

    @ViewBuilder private func editor(for target: EditTarget) -> some View {
        let accent = theme.accent
        switch target {
        case let .single(key):
            PopoverPanel(title: "\(key.title(on: kind)) · 单击") {
                ComboEditor(combo: $model.config[dynamicMember: key.singlePath(kind)], ui: ui, accent: accent)
                singleClickNote(key)
            }
        case let .gesture(key, gesture):
            gestureEditor(key, gesture)
        case .knobShort:
            PopoverPanel(title: "旋钮 · 短按") {
                ComboEditor(combo: $model.config.knobShortPress, ui: ui, accent: accent)
            }
        case .knobLong:
            PopoverPanel(title: "旋钮 · 长按") {
                ComboEditor(combo: $model.config.knobLongPress, ui: ui, accent: accent)
                RowDivider()
                HStack(spacing: 12) {
                    Text("按住多久算长按").font(.system(size: 14, weight: .medium))
                    Slider(value: $model.config.longPressSeconds, in: 0.3...1.5, step: 0.1)
                    Text(String(format: "%.1f 秒", model.config.longPressSeconds))
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                }
                Note("松手时才发送；按住期间转动旋钮切换过桌面，就什么都不发。")
            }
        case .knobTurn:
            PopoverPanel(title: "旋钮 · 转动", width: 440) {
                VStack(spacing: 0) {
                    SettingRow(title: "在输入框里移动光标",
                               detail: "焦点在输入框里、并且鼠标停在这个输入框上时，转动旋钮左右移动光标；其他地方照常滚动。") {
                        AccentSwitch(isOn: $model.config.caretInTextFields, accent: accent)
                    }
                    RowDivider()
                    SettingRow(title: "反转光标方向") {
                        AccentSwitch(isOn: $model.config.reverseCaret, accent: accent)
                    }
                    .disabled(!model.config.caretInTextFields)
                    RowDivider()
                    SettingRow(title: "每格滚动行数") {
                        HStack(spacing: 8) {
                            Text("\(model.config.scrollLines) 行").font(.system(size: 14, weight: .medium)).monospacedDigit()
                            Stepper("", value: $model.config.scrollLines, in: 1...10).labelsHidden()
                        }
                    }
                    RowDivider()
                    SettingRow(title: "反转滚动方向") {
                        AccentSwitch(isOn: $model.config.reverseScroll, accent: accent)
                    }
                }
            }
        case .knobPressTurn:
            PopoverPanel(title: "旋钮 · 按住转动", width: 440) {
                SettingRow(title: "按住旋钮转动切换桌面",
                           detail: "相当于 Control + ← / →。需要在「系统设置 → 键盘 → 键盘快捷键 → 调度中心」里开着「向左 / 向右移动一个空间」。") {
                    AccentSwitch(isOn: $model.config.switchSpacesWhilePressed, accent: accent)
                }
            }
        }
    }

    /// 单击的设置下面的说明：语音键说一下默认的 Fn；开了长按 / 双击时说明单击现在什么时候发。
    @ViewBuilder private func singleClickNote(_ key: GestureKey) -> some View {
        let c = model.config
        let long = c[keyPath: key.gesturePath(.long, kind)] != nil
        let double = c[keyPath: key.gesturePath(.double, kind)] != nil
        if long || double {
            RowDivider()
            Note(double
                 ? "开了双击：松手后要等 \(Int(doubleClickWindow * 1000)) 毫秒确认没有第二下，单击才发出去。"
                    + (long ? "" : String(format: "按住不放的话，%.1f 秒后就直接发，不用等松手。", clickMaxHold))
                 : "开了长按：松手时才发单击，不再是一按下就发。")
        } else if key == .voice {
            RowDivider()
            Note("默认是 Fn：Typeless 等语音输入用它开始和结束说话。")
        }
    }

    private func gestureEditor(_ key: GestureKey, _ gesture: KeyGesture) -> some View {
        let path = key.gesturePath(gesture, kind)
        let combo = Binding<KeyCombo>(
            get: { model.config[keyPath: path] ?? .none },
            set: { model.config[keyPath: path] = $0 }
        )
        return PopoverPanel(title: "\(key.title(on: kind)) · \(gesture.title)") {
            ComboEditor(combo: combo, ui: ui, accent: theme.accent)
            RowDivider()
            if gesture == .long {
                HStack(spacing: 12) {
                    Text("按住多久算长按").font(.system(size: 14, weight: .medium))
                    Slider(value: $model.config.longPressSeconds, in: 0.3...1.5, step: 0.1)
                    Text(String(format: "%.1f 秒", model.config.longPressSeconds))
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                }
                Note("按住到这个时长就发长按。开启后单击改成松手时才发。这个时长和旋钮长按共用。")
            } else {
                Note("快速按两下发这个组合。开启后单击会慢一点：松手后要等 \(Int(doubleClickWindow * 1000)) 毫秒确认没有第二下，单击才发出去。")
            }
            HStack {
                Spacer()
                Button("关闭\(gesture.title)") {
                    ui.closeEditor()
                    // 等弹出面板收起，再去掉它所在的那一行。
                    DispatchQueue.main.async { model.config[keyPath: path] = nil }
                }
                .buttonStyle(PillButtonStyle(kind: .subtle, height: 30))
            }
        }
    }

    // MARK: 引线

    private func leaderLines(anchors: [AnchorID: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        let art = anchors[.art].map { proxy[$0] }
        let spec = self.art
        return ZStack {
            if let art {
                ForEach(kind.controls) { control in
                    if let anchor = anchors[.card(control)] {
                        let cardRect = proxy[anchor]
                        let spot = spec.centers[control.hotspot] ?? CGPoint(x: 0.5, y: 0.5)
                        let radius = (spec.radii[control.hotspot] ?? 0.3) * art.width
                        let center = CGPoint(x: art.minX + spot.x * art.width, y: art.minY + spot.y * art.height)
                        let onLeft = control.onLeft(on: kind)
                        let start = CGPoint(x: onLeft ? cardRect.maxX : cardRect.minX, y: cardRect.midY)
                        let end = CGPoint(x: center.x + (onLeft ? -radius : radius), y: center.y)
                        let lit = isLit(control)
                        Path { path in
                            path.move(to: start)
                            let mid = (start.x + end.x) / 2
                            path.addCurve(to: end, control1: CGPoint(x: mid, y: start.y), control2: CGPoint(x: mid, y: end.y))
                        }
                        .stroke(lit ? theme.accent : Color.primary.opacity(0.22),
                                style: StrokeStyle(lineWidth: lit ? 2 : 1, lineCap: .round))
                        Circle()
                            .fill(lit ? theme.accent : Color.primary.opacity(0.4))
                            .frame(width: 6, height: 6)
                            .position(end)
                        Circle()
                            .fill(lit ? theme.accent : Color.primary.opacity(0.4))
                            .frame(width: 5, height: 5)
                            .position(start)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.flash?.id)
    }
}

/// 弹出面板：标题加内容。
private struct PopoverPanel<Content: View>: View {
    let title: String
    var width: CGFloat = 480
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .bold))
            content()
        }
        .padding(20)
        .frame(width: width)
    }
}

// MARK: 组合键编辑

/// 三种方式设置一个组合键：录制（在本窗口里按一次）、从常用里点选、用 ⌃⌥⇧⌘ 加一个键自由组合。
struct ComboEditor: View {
    @Binding var combo: KeyCombo
    @ObservedObject var ui: MappingUIState
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                ShortcutRecorderRow(ui: ui, accent: accent) { combo = $0 }
                Text("只在这个框被点中时读取你按下的一次组合键，不监听系统，也不需要额外权限。只按 Fn 或修饰键（比如 Fn + 左 Shift）也能录，全部松开时记下。⌘Tab、⌘空格、⌃← / → 这类系统快捷键录不到，可以在下面选。")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                caption("常用")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 8)], spacing: 8) {
                    ForEach(KeyPresets.options.map(\.0) + [KeyCombo.none], id: \.self) { preset in
                        presetChip(preset)
                    }
                }
            }
            HStack(spacing: 6) {
                caption("自定义").padding(.trailing, 6)
                modifier("Fn", "Fn（地球仪键）", $combo.fn)
                modifier("⌃", "Control", $combo.control)
                modifier("⌥", "Option", $combo.option)
                modifier("⇧", "Shift", $combo.shift)
                modifier("⌘", "Command", $combo.command)
                Text("+").foregroundStyle(.secondary).padding(.horizontal, 2)
                KeyPickerButton(combo: $combo, ui: ui, accent: accent)
                Spacer()
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func presetChip(_ preset: KeyCombo) -> some View {
        let selected = combo == preset
        let label = preset.isNone ? nil : preset.label
        return Button {
            combo = preset
        } label: {
            HStack(spacing: 7) {
                ComboKeycaps(combo: preset, small: true)
                if let label, label != preset.parts.last {
                    Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? accent.opacity(0.12) : Palette.raised.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? accent : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modifier(_ symbol: String, _ name: String, _ isOn: Binding<Bool>) -> some View {
        let on = isOn.wrappedValue
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? accent : Palette.raised))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .disabled(combo.isNone)
        .opacity(combo.isNone ? 0.4 : 1)
    }
}

/// 「自定义」里选主键：点开一个面板，按分组列出所有键帽。
private struct KeyPickerButton: View {
    @Binding var combo: KeyCombo
    @ObservedObject var ui: MappingUIState
    let accent: Color

    var body: some View {
        Button {
            ui.keyPickerOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                if combo.isNone {
                    Text("选择按键").font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    Keycap(text: KeyCombo.keyName(combo.keyCode), small: true)
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $ui.keyPickerOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(KeyCatalog.groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(group.keys, id: \.code) { key in
                                keyButton(key.code, key.name)
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(width: 460)
        }
    }

    private func keyButton(_ code: UInt16, _ name: String) -> some View {
        let selected = combo.keyCode == code
        return Button {
            combo.keyCode = code
            ui.keyPickerOpen = false
        } label: {
            Keycap(text: name, small: true)
                .frame(minWidth: 34)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? accent.opacity(0.15) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? accent : .clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 从左到右排、排满换行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
