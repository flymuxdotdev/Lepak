import AppKit
import SwiftUI

// 设置界面共用的样式。观感参考 Typeless（用户本来就在用它做语音输入，看着眼熟）：
// 深色画布 + 点阵底纹、左侧圆角侧栏、不带阴影的大圆角卡片、描边键帽、大号粗体标题。
// 浅色模式用同一套结构换成浅色。全部用 SwiftUI 画，真实窗口和开发用的离屏截图一样。

extension DeviceTheme {
    /// 强调色：标准版暖橙红（和 App 图标一致），WorkBuddy 版冷青。只用在徽标、主按钮、开关和选中状态上。
    var accent: Color {
        switch self {
        case .standard: return Color(red: 0.93, green: 0.42, blue: 0.25)
        case .workBuddy: return Color(red: 0.20, green: 0.74, blue: 0.62)
        }
    }

    /// 按键页设备背后的光：标准版暖黄，WorkBuddy 版薄荷青。
    var glow: Color {
        switch self {
        case .standard: return Color(red: 1.00, green: 0.76, blue: 0.32)
        case .workBuddy: return Color(red: 0.42, green: 0.94, blue: 0.80)
        }
    }
}

/// 灰阶配色，浅色 / 深色各一套。
enum Palette {
    /// 窗口底色。
    static let canvas = gray(light: 0.945, dark: 0.078)
    /// 左侧栏。
    static let sidebar = gray(light: 0.975, dark: 0.122)
    /// 卡片。
    static let card = gray(light: 1.0, dark: 0.165)
    /// 卡片里再高一层：选中的导航项、按下的行、侧栏里的状态卡。
    static let raised = gray(light: 0.92, dark: 0.215)
    /// 键帽底色。
    static let keycap = gray(light: 1.0, dark: 0.105)
    /// 细分隔线和卡片描边。
    static let hairline = Color.primary.opacity(0.07)

    static func gray(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}

/// 卡片：大圆角、实心底、一圈很淡的描边；高亮时描强调色。
struct CardStyle: ViewModifier {
    var padding: CGFloat = 20
    var radius: CGFloat = 20
    var fill: Color = Palette.card
    var highlight: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlight ?? Palette.hairline, lineWidth: highlight == nil ? 1 : 1.5)
            )
    }
}

extension View {
    func card(padding: CGFloat = 20, radius: CGFloat = 20, fill: Color = Palette.card, highlight: Color? = nil) -> some View {
        modifier(CardStyle(padding: padding, radius: radius, fill: fill, highlight: highlight))
    }
}

/// 页面大标题，右边可以放按钮。
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 40, weight: .heavy))
                if let subtitle {
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 卡片上方的小节标题。
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 17, weight: .bold))
    }
}

/// 一个键帽：描边、实心底、底边略厚，像一颗真的键。
struct Keycap: View {
    let text: String
    var small = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: small ? 5 : 7, style: .continuous)
        Text(text)
            .font(.system(size: small ? 11.5 : 15, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, small ? 5 : 8)
            .frame(minWidth: small ? 22 : 32, minHeight: small ? 21 : 30)
            .background(shape.fill(Palette.keycap))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.75), lineWidth: small ? 1 : 1.4))
            .background(shape.fill(Color.primary.opacity(0.75)).offset(y: small ? 1.2 : 1.8))
    }
}

/// 一个组合键画成一排键帽，比如 ⌘ ⌫；「不发送」显示成灰字。
struct ComboKeycaps: View {
    let combo: KeyCombo
    var small = false

    var body: some View {
        if combo.isNone {
            Text("不发送").font(.system(size: small ? 12 : 14)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: small ? 3 : 5) {
                ForEach(Array(combo.parts.enumerated()), id: \.offset) { _, part in
                    Keycap(text: part, small: small)
                }
            }
        }
    }
}

/// 小徽标，比如侧栏里 Logo 旁边的「AU05」。
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.15)))
    }
}

/// 胶囊按钮。`accent`：强调色实心；`inverse`：和文字同色的实心（深色模式下是白底黑字）；`subtle`：浅灰底。
struct PillButtonStyle: ButtonStyle {
    enum Kind { case accent(Color), inverse, subtle }
    var kind: Kind
    var fill = false
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(isSubtle ? 0.08 : 0)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }

    private var isSubtle: Bool {
        if case .subtle = kind { return true }
        return false
    }

    private var foreground: Color {
        switch kind {
        case .accent: return .white
        case .inverse: return Palette.card
        case .subtle: return .primary
        }
    }

    private var background: Color {
        switch kind {
        case .accent(let color): return color
        case .inverse: return .primary
        case .subtle: return Palette.raised
        }
    }
}

/// 整行可点的列表项：按下时底色变深一层。
struct RowButtonStyle: ButtonStyle {
    var radius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? Palette.raised : .clear)
            )
    }
}

/// 主题色开关（不用系统开关，配色跟主题走）。
struct AccentSwitch: View {
    @Binding var isOn: Bool
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Capsule()
            .fill(isOn ? accent : Color.primary.opacity(0.2))
            .frame(width: 38, height: 22)
            .overlay(
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
                    .offset(x: isOn ? 8 : -8)
            )
            .animation(.easeOut(duration: 0.15), value: isOn)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { isOn.toggle() } }
    }
}

/// 带文字的开关：文字在左，开关在右。
struct ThemedSwitch: ToggleStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Spacer(minLength: 8)
            AccentSwitch(isOn: configuration.$isOn, accent: accent)
        }
    }
}

/// 细长的电量条。
struct LevelBar: View {
    let fraction: Double
    var tint: Color = .primary
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(fraction < 0.2 ? Color.red : tint)
                    .frame(width: proxy.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// 画布上的点阵底纹。用一小块模板图平铺，颜色跟着浅色 / 深色走。
struct DotGrid: View {
    @MainActor private static let tile: NSImage = {
        let image = NSImage(size: NSSize(width: 11, height: 11), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4.6, y: 4.6, width: 1.8, height: 1.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.tile)
            .renderingMode(.template)
            .resizable(resizingMode: .tile)
            .foregroundStyle(Color.primary.opacity(0.10))
    }
}

/// 一行设置：左边标题和说明，右边控件。卡片里一行一行排，中间用细线隔开。
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 14)
    }
}

/// 卡片里的分隔线。
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }
}

/// 表单里的小字说明。
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
