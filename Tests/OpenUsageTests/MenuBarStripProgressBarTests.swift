import AppKit
import XCTest
@testable import OpenUsage

/// A metric that counts down to a reset is drawn in the strip as a bar draining towards the reset,
/// so the countdown reads at a glance instead of only as text. The filled part is the time still to
/// run. While the window has plenty left the bar is the strip's own white ink; over the window's
/// final stretch it takes the app's warning colour, and the critical colour over the last fifth of
/// that stretch.
@MainActor
final class MenuBarStripProgressBarTests: XCTestCase {
    func testAResetCountdownIsDrawnAsABarInsteadOfItsText() throws {
        let withBar = try XCTUnwrap(strip(fraction: 0.4, level: .normal))
        let withText = try XCTUnwrap(strip(fraction: nil, level: nil))

        XCTAssertNotEqual(
            withBar.size.height, withText.size.height,
            "the bar replaces the countdown text, so the strip is a different shape"
        )
    }

    func testTheBarsFillTracksTheTimeStillToRun() throws {
        let plentyLeft = try XCTUnwrap(strip(fraction: 0.9, level: .normal))
        let nearlyOver = try XCTUnwrap(strip(fraction: 0.3, level: .normal))

        XCTAssertGreaterThan(
            try inkPixels(in: plentyLeft), try inkPixels(in: nearlyOver),
            "a window with more time left draws more of the bar"
        )
    }

    func testTheBarIsWhiteWhileTheWindowHasTimeLeft() throws {
        let image = try XCTUnwrap(strip(fraction: 0.6, level: .normal))

        XCTAssertTrue(
            try coloredPixels(in: image).isEmpty,
            "a window with time left keeps the strip's white ink"
        )
    }

    func testTheBarTakesTheWarningColourOverTheFinalStretch() throws {
        let image = try XCTUnwrap(strip(fraction: 0.5, level: .warning))

        let warning = try coloredPixels(in: image)
        XCTAssertFalse(warning.isEmpty, "the final stretch draws a colored bar")
        for pixel in warning {
            XCTAssertGreaterThan(pixel.g, pixel.b + 60, "the bar is warm, found \(pixel)")
        }
    }

    func testTheBarTurnsRedAtTheEndOfTheFinalStretch() throws {
        let image = try XCTUnwrap(strip(fraction: 0.15, level: .critical))

        let red = try coloredPixels(in: image)
        XCTAssertFalse(red.isEmpty, "the last moments draw a colored bar")
        for pixel in red {
            XCTAssertGreaterThan(pixel.r, pixel.g + 60, "the bar is red, found \(pixel)")
        }
    }

    private func strip(fraction: Double?, level: WidgetData.ProgressLevel?) -> NSImage? {
        var countdown = MenuBarContent.Metric(id: "minimax.sessionReset", label: "5h Reset", value: "2h 30m")
        countdown.progressFraction = fraction
        countdown.progressLevel = level
        let content = MenuBarContent(groups: [MenuBarContent.Group(
            provider: Provider(id: "minimax", kind: .minimax),
            metrics: [
                MenuBarContent.Metric(id: "minimax.session", label: "Session", value: "89%"),
                countdown
            ]
        )])
        return MenuBarStripRenderer.image(for: content)
    }

    /// The pixels the bar's fill covers. The track is drawn at low opacity, so only the fill counts.
    private func inkPixels(in image: NSImage) throws -> Int {
        try pixels(in: image).filter { $0.alpha > 128 }.count
    }

    /// The pixels that carry a color other than the strip's white ink.
    private func coloredPixels(in image: NSImage) throws -> [RGB] {
        try pixels(in: image).filter { $0.alpha > 128 && ($0.max - $0.min) > 60 }.map(\.color)
    }

    private struct Pixel {
        let r: Int
        let g: Int
        let b: Int
        let alpha: Int

        var color: RGB { RGB(r: r, g: g, b: b) }
        var max: Int { Swift.max(r, g, b) }
        var min: Int { Swift.min(r, g, b) }
    }

    private struct RGB: CustomStringConvertible {
        let r: Int
        let g: Int
        let b: Int

        var description: String { "rgb(\(r), \(g), \(b))" }
    }

    private func pixels(in image: NSImage) throws -> [Pixel] {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        var result: [Pixel] = []
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0 else { continue }
            // The bitmap is premultiplied, so an edge pixel's color is scaled by its own alpha.
            let unpremultiplied = { (channel: UInt8) in Int(channel) * 255 / alpha }
            result.append(Pixel(
                r: unpremultiplied(bytes[index]),
                g: unpremultiplied(bytes[index + 1]),
                b: unpremultiplied(bytes[index + 2]),
                alpha: alpha
            ))
        }
        return result
    }
}
