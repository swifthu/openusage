import AppKit
import SwiftUI

@MainActor
enum MenuBarStripRenderer {
    /// The strip's ink.
    ///
    /// Upstream draws the strip as a template image so macOS tints it for the current menu-bar
    /// appearance. This fork keeps the strip white instead: the menu bar always renders against the
    /// system strip, where white reads on both Light and Dark Aqua. A non-template image is what
    /// carries that choice, so the color lives here rather than in each drawing site.
    static let themeColor = Color.white

    /// The strip image, drawn at `scale` times its default size.
    static func image(for content: MenuBarContent, scale: Double = 1) -> NSImage? {
        guard !content.isEmpty else { return content.updateAvailable ? appIconWithUpdateDot(scale: scale) : nil }
        let renderer = ImageRenderer(content: MenuBarTextStrip(content: content, scale: scale))
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = false
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// The app icon shown when the strip has nothing to show, drawn at `scale` times its default size.
    static func appIcon(scale: Double = 1) -> NSImage {
        themedAppIcon(scale: scale)
    }

    /// The app icon with a dot in its top-right corner, cut out of the mark so the two never touch.
    static func appIconWithUpdateDot(scale: Double = 1) -> NSImage {
        let icon = themedAppIcon(scale: scale)
        let image = NSImage(size: icon.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            icon.draw(in: rect)
            let side = 5 * scale
            let dot = CGRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side)
            context.setBlendMode(.clear)
            context.fillEllipse(in: dot.insetBy(dx: -scale, dy: -scale))
            context.setBlendMode(.normal)
            context.setFillColor(NSColor(themeColor).cgColor)
            context.fillEllipse(in: dot)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Update available"
        return image
    }

    /// The brand mark in the theme color, drawn the same way the strip draws its glyphs so both
    /// read as the same ink.
    private static func themedAppIcon(scale: Double) -> NSImage {
        let mark = ProviderMarks.image(for: "openusage", side: 18 * scale, inset: 0.08)
        let renderer = ImageRenderer(content: Image(nsImage: mark)
            .renderingMode(.template)
            .foregroundStyle(themeColor))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return mark }
        image.isTemplate = false
        return image
    }

    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    nonisolated static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

private struct MenuBarTextStrip: View {
    let content: MenuBarContent
    /// The size the strip is drawn at, as a multiple of the default. Every dimension scales with it.
    var scale: Double = 1

    var body: some View {
        HStack(spacing: 11 * scale) {
            ForEach(content.items) { item in
                HStack(spacing: 4 * scale) {
                    glyph(item.provider.icon)
                        .overlay(alignment: .bottomTrailing) {
                            if let badge = item.provider.badge {
                                AccountBadge(text: badge, color: MenuBarStripRenderer.themeColor, scale: scale)
                                    .offset(x: AccountBadge.overhang.width * scale,
                                            y: AccountBadge.overhang.height * scale)
                            }
                        }
                        .compositingGroup()
                        // The renderer draws only inside layout bounds, so reserve the badge's overhang
                        // (vertically on both sides, keeping the mark centred on its values) or it is cut off.
                        .padding(.trailing, item.provider.badge == nil ? 0 : AccountBadge.overhang.width * scale)
                        .padding(.vertical, item.provider.badge == nil ? 0 : AccountBadge.overhang.height * scale)
                    labelledValue(item)
                }
            }
            if content.overflow > 0 {
                overflowCount(content.overflow)
            }
            if content.updateAvailable {
                updateMark()
            }
        }
        .foregroundStyle(MenuBarStripRenderer.themeColor)
        .monospacedDigit()
        .padding(.horizontal, 2 * scale)
        .padding(.vertical, 1 * scale)
        .fixedSize()
        .compositingGroup()
    }

    private func labelledValue(_ item: MenuBarContent.Item) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(item.shortLabel)
                .font(.system(size: 9 * scale, weight: .medium))
            // The bar is centred on the value's line rather than sat on its bottom: a bar hung off
            // the bottom would reach past the text's ink and make the strip taller than the menu
            // bar can show.
            HStack(alignment: .center, spacing: 3 * scale) {
                Text(item.value)
                    .font(.system(size: 11 * scale, weight: .bold))
                // A limit that counts down to a reset carries a bar draining towards that reset,
                // beside the value so the strip keeps its height.
                if let fraction = item.progressFraction {
                    progressBar(fraction: fraction, level: item.progressLevel)
                }
            }
        }
        .fixedSize()
    }

    /// A countdown window drawn as a bar draining towards its reset: the filled part is the time
    /// still to run. While the window has plenty left the bar is the strip's own ink; over the
    /// window's final stretch it takes the app's warning colour, and the critical colour over the
    /// last fifth of that stretch.
    private func progressBar(fraction: Double, level: WidgetData.ProgressLevel?) -> some View {
        let fill: Color = switch level {
        case .warning: Theme.severityColor(.warning)
        case .critical: Theme.severityColor(.critical)
        case .normal, .none: MenuBarStripRenderer.themeColor.opacity(0.85)
        }
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MenuBarStripRenderer.themeColor.opacity(0.22))
                Capsule().fill(fill)
                    .frame(width: max(2 * scale, geo.size.width * fraction))
            }
        }
        .frame(width: Self.barWidth * scale, height: 4 * scale)
    }

    private func overflowCount(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 11 * scale, weight: .bold))
            .padding(.horizontal, 5 * scale)
            .frame(height: 16 * scale)
            .background(Capsule().fill(MenuBarStripRenderer.themeColor.opacity(0.16)))
    }

    /// The app icon with the update dot, drawn in the theme color so it reads as the same ink as
    /// the rest of the strip.
    private func updateMark() -> some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: ProviderMarks.image(for: "openusage", side: Self.markSide * scale, inset: 0.08))
                .renderingMode(.template)
                .foregroundStyle(MenuBarStripRenderer.themeColor)
            // The notch the dot floats in, cut out of the mark.
            Circle()
                .fill(MenuBarStripRenderer.themeColor)
                .frame(width: 7 * scale, height: 7 * scale)
                .blendMode(.destinationOut)
                .offset(x: -1 * scale, y: 1 * scale)
            Circle()
                .fill(MenuBarStripRenderer.themeColor)
                .frame(width: 5 * scale, height: 5 * scale)
                .offset(x: -1 * scale, y: 1 * scale)
        }
        .compositingGroup()
    }

    private static let glyphSide: CGFloat = 16
    private static let markSide: CGFloat = 18
    private static let barWidth: CGFloat = 16

    private var glyphSide: CGFloat { Self.glyphSide * scale }

    private func glyph(_ icon: String) -> some View {
        Image(nsImage: ProviderMarks.image(for: icon, side: glyphSide, inset: 0.04))
            .renderingMode(.template)
            .foregroundStyle(MenuBarStripRenderer.themeColor)
    }
}
