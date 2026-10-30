import XCTest
@testable import OpenUsage

/// The size the menu bar strip is drawn at. The menu bar has a fixed height, so the range stays
/// inside what fits, and a stored value outside it is clamped rather than drawn.
@MainActor
final class MenuBarSizeSettingTests: XCTestCase {
    func testAnUnsetSizeIsTheDefault() {
        let setting = MenuBarSizeSetting(defaults: isolatedDefaults())

        XCTAssertEqual(setting.scale, MenuBarSizeSetting.defaultScale)
        XCTAssertEqual(MenuBarSizeSetting.defaultScale, 1.0)
    }

    func testTheSizeIsClampedToTheRange() {
        let setting = MenuBarSizeSetting(defaults: isolatedDefaults())

        setting.set(0.1)
        XCTAssertEqual(setting.scale, MenuBarSizeSetting.range.lowerBound)

        setting.set(9)
        XCTAssertEqual(setting.scale, MenuBarSizeSetting.range.upperBound)

        setting.set(1.15)
        XCTAssertEqual(setting.scale, 1.15)
    }

    func testTheSizeIsPersisted() {
        let defaults = isolatedDefaults()
        let setting = MenuBarSizeSetting(defaults: defaults)

        setting.set(1.2)

        XCTAssertEqual(MenuBarSizeSetting(defaults: defaults).scale, 1.2)
    }

    func testAStoredSizeOutsideTheRangeIsClampedOnTheWayIn() {
        let defaults = isolatedDefaults()
        defaults.set(4, forKey: MenuBarSizeSetting.key)

        let setting = MenuBarSizeSetting(defaults: defaults)

        XCTAssertEqual(setting.scale, MenuBarSizeSetting.range.upperBound)
    }
}
