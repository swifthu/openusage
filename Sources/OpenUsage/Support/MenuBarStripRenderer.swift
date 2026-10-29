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

    static func image(for content: MenuBarContent) -> NSImage? {
        guard !content.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarTextStrip(content: content))
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

    static func appIcon(for content: MenuBarContent) -> NSImage {
        let icon = themedAppIcon()
        guard content.isStale else { return icon }
        let dimmed = NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
            return true
        }
        dimmed.isTemplate = false
        return dimmed
    }

    /// The brand mark in the theme color, drawn the same way the strip draws its glyphs so both
    /// read as the same ink.
    private static func themedAppIcon() -> NSImage {
        let mark = ProviderMarks.image(for: "openusage", side: 18, inset: 0.08)
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

    var body: some View {
        HStack(spacing: 11) {
            ForEach(content.groups, id: \.provider.id) { group in
                HStack(spacing: 4) {
                    glyph(group.provider.icon)
                        .overlay(alignment: .bottomTrailing) {
                            if let badge = group.badge {
                                badgeView(badge)
                                    .offset(x: Self.badgeOverhang.width, y: Self.badgeOverhang.height)
                            }
                        }
                        .compositingGroup()
                        // The renderer draws only inside layout bounds, so reserve the badge's overhang
                        // (vertically on both sides, keeping the mark centred on its values) or it is cut off.
                        .padding(.trailing, group.badge == nil ? 0 : Self.badgeOverhang.width)
                        .padding(.vertical, group.badge == nil ? 0 : Self.badgeOverhang.height)
                    metricsView(group.metrics)
                }
            }
        }
        .foregroundStyle(MenuBarStripRenderer.themeColor)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
        .compositingGroup()
        .opacity(content.isStale ? 0.5 : 1)
    }

    @ViewBuilder
    private func metricsView(_ metrics: [MenuBarContent.Metric]) -> some View {
        if metrics.count <= 1 {
            Text(metrics.first?.value ?? "")
                .font(.system(size: 12, weight: .bold))
        } else {
            VStack(alignment: .trailing, spacing: metrics.contains { $0.progressFraction != nil } ? 2 : -2) {
                ForEach(metrics, id: \.id) { metric in
                    if let fraction = metric.progressFraction {
                        progressBar(fraction: fraction)
                    } else {
                        Text(metric.value)
                    }
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .fixedSize()
        }
    }

    /// A countdown window drawn as a bar draining towards its reset: the filled part is the time
    /// still to run. White like the rest of the strip — the menu bar always renders against the
    /// system strip, where white reads on both Light and Dark Aqua.
    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MenuBarStripRenderer.themeColor.opacity(0.22))
                Capsule().fill(MenuBarStripRenderer.themeColor.opacity(0.85))
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }

    private static let glyphSide: CGFloat = 16

    private static let badgeOverhang = CGSize(width: 5, height: 2.5)

    private func badgeView(_ badge: String) -> some View {
        let label = Text(badge)
            .font(.system(size: 6.5, weight: .heavy))
            .padding(.horizontal, 2)
            .frame(minWidth: 8, minHeight: 8)
        return ZStack {
            Capsule().fill(MenuBarStripRenderer.themeColor)
                .padding(-1.25)
                .blendMode(.destinationOut)
            Capsule().fill(MenuBarStripRenderer.themeColor)
            label.foregroundStyle(MenuBarStripRenderer.themeColor).blendMode(.destinationOut)
        }
        .fixedSize()
    }

    private func glyph(_ icon: String) -> some View {
        Image(nsImage: ProviderMarks.image(for: icon, side: Self.glyphSide, inset: 0.04))
            .renderingMode(.template)
            .foregroundStyle(MenuBarStripRenderer.themeColor)
    }
}
