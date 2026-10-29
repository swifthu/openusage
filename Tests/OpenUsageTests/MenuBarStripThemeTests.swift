import AppKit
import XCTest
@testable import OpenUsage

/// This fork draws the menu bar in its own white instead of letting macOS tint a template image.
/// The color is the one thing a merge with upstream can silently undo, so it is pinned here.
@MainActor
final class MenuBarStripThemeTests: XCTestCase {
    func testTheStripIsDrawnInWhite() throws {
        let content = MenuBarContent(
            groups: [
                MenuBarContent.Group(
                    provider: Provider(id: "claude", kind: .claude),
                    metrics: [MenuBarContent.Metric(id: "claude.session", label: "Session", value: "99%")]
                )
            ]
        )

        let image = try XCTUnwrap(MenuBarStripRenderer.image(for: content))
        XCTAssertFalse(image.isTemplate, "a template image would be tinted by macOS, not white")

        let colors = try opaqueColors(in: image)
        XCTAssertFalse(colors.isEmpty, "the strip drew nothing")
        for color in colors {
            XCTAssertTrue(RGB.isWhite(color), "the strip must be white, found \(color)")
        }
    }

    func testTheAppIconIsDrawnInWhite() throws {
        let empty = MenuBarContentBuilder.build(groups: [], data: { $0.sample })

        let icon = MenuBarStripRenderer.appIcon(for: empty)
        XCTAssertFalse(icon.isTemplate, "a template icon would be tinted by macOS, not white")

        let colors = try opaqueColors(in: icon)
        XCTAssertFalse(colors.isEmpty, "the app icon drew nothing")
        for color in colors {
            XCTAssertTrue(RGB.isWhite(color), "the app icon must be white, found \(color)")
        }
    }

    /// The RGB of every pixel opaque enough to carry the drawing's ink. The bitmap is premultiplied,
    /// so an edge pixel's color is scaled by its own alpha; the alpha is divided back out to read the
    /// ink's own color.
    private func opaqueColors(in image: NSImage) throws -> Set<RGB> {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        var colors: Set<RGB> = []
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 200 else { continue }
            let unpremultiplied = { (channel: UInt8) in Int(channel) * 255 / alpha }
            colors.insert(RGB(
                r: unpremultiplied(pixels[index]),
                g: unpremultiplied(pixels[index + 1]),
                b: unpremultiplied(pixels[index + 2])
            ))
        }
        return colors
    }
}

/// A pixel's color.
private struct RGB: Hashable {
    let r: Int
    let g: Int
    let b: Int

    /// White, within a rounding step of the 8-bit channels.
    static func isWhite(_ color: RGB) -> Bool {
        color.r >= 250 && color.g >= 250 && color.b >= 250
    }
}
