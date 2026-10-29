import AppKit
import XCTest
@testable import OpenUsage

/// A metric that counts down to a reset is drawn in the strip as a bar draining towards the reset,
/// so the countdown reads at a glance instead of only as text. The filled part is the time still to
/// run.
@MainActor
final class MenuBarStripProgressBarTests: XCTestCase {
    func testAResetCountdownIsDrawnAsABarInsteadOfItsText() throws {
        let withBar = try XCTUnwrap(strip(fraction: 0.4))
        let withText = try XCTUnwrap(strip(fraction: nil))

        XCTAssertNotEqual(
            withBar.size.height, withText.size.height,
            "the bar replaces the countdown text, so the strip is a different shape"
        )
    }

    func testTheBarsFillTracksTheTimeStillToRun() throws {
        let plentyLeft = try XCTUnwrap(strip(fraction: 0.9))
        let nearlyOver = try XCTUnwrap(strip(fraction: 0.3))

        XCTAssertGreaterThan(
            try inkPixels(in: plentyLeft), try inkPixels(in: nearlyOver),
            "a window with more time left draws more of the bar"
        )
    }

    private func strip(fraction: Double?) -> NSImage? {
        var countdown = MenuBarContent.Metric(id: "minimax.sessionReset", label: "5h Reset", value: "2h 30m")
        countdown.progressFraction = fraction
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
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where Int(pixels[index + 3]) > 128 {
            count += 1
        }
        return count
    }
}
