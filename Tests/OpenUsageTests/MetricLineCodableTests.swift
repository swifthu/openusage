import XCTest
@testable import OpenUsage

/// The metric lines a provider hands back are cached on disk, so their encoded shape has to stay
/// readable by the build that wrote them. A badge gained the fields that describe its countdown
/// window after the first release of that shape; a snapshot cached before that must still decode.
final class MetricLineCodableTests: XCTestCase {
    func testABadgeEncodedBeforeTheWindowFieldsStillDecodes() throws {
        let json = #"{"badge":{"text":"2h 30m","label":"5h Reset"}}"#

        let line = try JSONDecoder().decode(MetricLine.self, from: Data(json.utf8))

        guard case .badge(let label, let text, let resetsAt, let periodDurationMs) = line else {
            return XCTFail("expected a badge")
        }
        XCTAssertEqual(label, "5h Reset")
        XCTAssertEqual(text, "2h 30m")
        XCTAssertNil(resetsAt)
        XCTAssertNil(periodDurationMs)
    }

    func testABadgeCarriesItsWindowThroughACodableRoundTrip() throws {
        let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
        let line = MetricLine.badge(
            label: "5h Reset",
            text: "2h 30m",
            resetsAt: resetsAt,
            periodDurationMs: 5 * 60 * 60 * 1000
        )

        let decoded = try JSONDecoder().decode(
            MetricLine.self, from: try JSONEncoder().encode(line)
        )

        guard case .badge(let label, let text, let decodedResetsAt, let periodDurationMs) = decoded else {
            return XCTFail("expected a badge")
        }
        XCTAssertEqual(label, "5h Reset")
        XCTAssertEqual(text, "2h 30m")
        XCTAssertEqual(decodedResetsAt, resetsAt)
        XCTAssertEqual(periodDurationMs, 5 * 60 * 60 * 1000)
    }
}
