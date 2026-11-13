import AppKit

/// Lepak 的标志：六根圆头竖条，两边短、中间高，像一段声波。
/// 菜单栏图标和设置窗口侧栏的 Logo 都用它。用代码画，什么尺寸都清楚；
/// 是模板图，系统会按浅色 / 深色菜单栏自动着色，没连上设备时也能整体变灰。
enum BrandIcon {
    /// 一种画法：格子高度、竖条宽、相邻两根的间距，和从左到右六根的高度（上下居中）。
    private struct Grid {
        let height: CGFloat
        let barWidth: CGFloat
        let step: CGFloat
        let heights: [CGFloat]

        var width: CGFloat { step * CGFloat(heights.count - 1) + barWidth }
    }

    /// 侧栏 Logo：按 40×32 的格子设计，竖条宽 5 格、间隔 2 格。
    private static let logo = Grid(height: 32, barWidth: 5, step: 7, heights: [14, 22, 30, 30, 22, 14])

    /// 菜单栏：比旁边的图标小一号、细一点（用户 2026-11-13 嫌原来的 20×16pt 太大）。
    /// 按 @2x 屏幕的像素设计：高 26 像素（13pt），竖条 4 像素、间隔 2 像素，宽 34 像素（17pt），
    /// 竖条四边都落在整像素上，不发虚。
    private static let menuBar = Grid(height: 26, barWidth: 4, step: 6, heights: [12, 18, 24, 24, 18, 12])

    /// 侧栏 Logo，高 `height` 点，宽度按比例。
    static func image(height: CGFloat = 16) -> NSImage {
        draw(logo, height: height)
    }

    /// 菜单栏图标，13pt 高、17pt 宽。
    static func menuBarImage() -> NSImage {
        draw(menuBar, height: menuBar.height / 2)
    }

    private static func draw(_ grid: Grid, height: CGFloat) -> NSImage {
        let size = NSSize(width: height * grid.width / grid.height, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let scale = rect.height / grid.height
            NSColor.black.setFill()
            for (index, barHeight) in grid.heights.enumerated() {
                let bar = NSRect(
                    x: rect.minX + CGFloat(index) * grid.step * scale,
                    y: rect.minY + (grid.height - barHeight) / 2 * scale,
                    width: grid.barWidth * scale,
                    height: barHeight * scale
                )
                let radius = bar.width / 2
                NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
