import AppKit
import XCTest
@testable import OpenUsage

/// The strip is drawn at a multiple of its default size, so a bigger setting has to draw a bigger
/// strip — the glyph, the values and the spacing all scale together.
@MainActor
final class MenuBarStripSizeTests: XCTestCase {
    func testTheStripIsDrawnLargerAtAScaleAboveOne() throws {
        let small = try XCTUnwrap(MenuBarStripRenderer.image(for: content, scale: 0.7))
        let large = try XCTUnwrap(MenuBarStripRenderer.image(for: content, scale: 1.3))

        XCTAssertGreaterThan(large.size.height, small.size.height)
        XCTAssertGreaterThan(large.size.width, small.size.width)
    }

    func testTheDefaultScaleDrawsTheDefaultSize() throws {
        let plain = try XCTUnwrap(MenuBarStripRenderer.image(for: content, scale: 1))
        let scaled = try XCTUnwrap(MenuBarStripRenderer.image(for: content, scale: MenuBarSizeSetting.defaultScale))

        XCTAssertEqual(plain.size, scaled.size)
    }

    func testTheAppIconIsDrawnLargerAtAScaleAboveOne() {
        let small = MenuBarStripRenderer.appIcon(for: content, scale: 0.7)
        let large = MenuBarStripRenderer.appIcon(for: content, scale: 1.3)

        XCTAssertGreaterThan(large.size.height, small.size.height)
        XCTAssertGreaterThan(large.size.width, small.size.width)
    }

    private var content: MenuBarContent {
        MenuBarContent(groups: [MenuBarContent.Group(
            provider: Provider(id: "minimax", kind: .minimax),
            metrics: [MenuBarContent.Metric(id: "minimax.session", label: "Session", value: "89%")]
        )])
    }
}
