import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The chart draws the peak in the app's blue and everything else in a lighter shade of it. A
/// slice nothing was read from stays empty: "we do not know" must not look like "nothing was
/// used".
@MainActor
final class RhythmChartTests: XCTestCase {
    func testThePeakBarIsDrawnInTheStrongerBlue() throws {
        var bars = makeBars()
        bars[14].points = 9
        bars[15].points = 8

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: 14...15, zoom: .day)))

        XCTAssertFalse(try stronglyBluePixels(in: image).isEmpty, "the peak is drawn in the stronger blue")
    }

    func testABurnThatHasNoReadingOfItsOwnIsStillDrawn() throws {
        // The burn between two readings is spread over the buckets it covered, and those buckets
        // hold no reading of their own. They still show.
        var bars = makeBars()
        bars[14].points = 9
        bars[14].samples = 0

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: 14...14, zoom: .day)))

        XCTAssertFalse(try stronglyBluePixels(in: image).isEmpty, "a burn without a reading of its own is drawn")
    }

    func testASliceThatWasReadButNotUsedDrawsABaseline() throws {
        let bars = makeBars()

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: nil, zoom: .day)))

        XCTAssertFalse(try inkPixels(in: image).isEmpty, "a slice that was read and not used draws a baseline")
    }

    func testASliceThatWasNotReadDrawsNothing() throws {
        let bars = makeBars(samples: 0)

        let image = try XCTUnwrap(render(RhythmChart(bars: bars, peak: nil, zoom: .day)))

        XCTAssertTrue(try inkPixels(in: image).isEmpty, "a slice that was not read draws nothing")
    }

    // MARK: - Rendering

    /// Twenty-four bars with distinct indices — the chart identifies a bar by its index, so two
    /// bars with the same one would make the drawing undefined.
    private func makeBars(samples: Int = 1) -> [RhythmBar] {
        (0..<24).map { RhythmBar(index: $0, points: 0, samples: samples, start: Date()) }
    }

    private func render(_ view: some View) -> CGImage? {
        // The white background makes the faint ink visible: without it a half-transparent bar has
        // a half-transparent alpha, and the test cannot tell it from nothing at all.
        let renderer = ImageRenderer(content: view.frame(width: 300, height: 100).background(Color.white))
        renderer.scale = 2
        return renderer.cgImage
    }

    private func pixels(in image: CGImage) throws -> [(r: Int, g: Int, b: Int, a: Int)] {
        let rep = NSBitmapImageRep(cgImage: image)
        var result: [(r: Int, g: Int, b: Int, a: Int)] = []
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y) {
                    result.append((r: Int(color.redComponent * 255), g: Int(color.greenComponent * 255), b: Int(color.blueComponent * 255), a: Int(color.alphaComponent * 255)))
                }
            }
        }
        return result
    }

    /// The pixels the strong blue covers. macOS's system blue is 0, 122, 255.
    private func stronglyBluePixels(in image: CGImage) throws -> [(r: Int, g: Int, b: Int, a: Int)] {
        try pixels(in: image).filter { $0.a > 128 && $0.b > 200 && $0.r < 120 && $0.g < 170 }
    }

    /// Every pixel that carries any of the chart's ink, however faint. The white background is not
    /// ink: blue minus red is what tells them apart.
    private func inkPixels(in image: CGImage) throws -> [(r: Int, g: Int, b: Int, a: Int)] {
        try pixels(in: image).filter { $0.b > 200 && $0.b - $0.r > 30 }
    }
}
