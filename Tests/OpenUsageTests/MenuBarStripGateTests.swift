import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarStripGateTests: XCTestCase {
    func testUnchangedStripIsNotShownAgain() {
        var shown: [MenuBarContent] = []
        var gate = StatusItemController.StripGate()
        gate.show(makeContent(value: "42%"), scale: 1) { content, _ in shown.append(content) }
        gate.show(makeContent(value: "42%"), scale: 1) { content, _ in shown.append(content) }
        XCTAssertEqual(shown, [makeContent(value: "42%")])
    }

    func testChangedStripIsShown() {
        var shown: [MenuBarContent] = []
        var gate = StatusItemController.StripGate()
        gate.show(makeContent(value: "42%"), scale: 1) { content, _ in shown.append(content) }
        gate.show(makeContent(value: "43%"), scale: 1) { content, _ in shown.append(content) }
        gate.show(makeContent(value: "43%"), scale: 1) { content, _ in shown.append(content) }
        XCTAssertEqual(shown, [makeContent(value: "42%"), makeContent(value: "43%")])
    }

    func testAChangedSizeShowsTheStripAgainEvenWhenTheContentIsTheSame() {
        // The strip is drawn at the chosen size, so a size change has to redraw it — the content
        // alone would not tell the gate that anything changed.
        var shown: [(MenuBarContent, Double)] = []
        var gate = StatusItemController.StripGate()
        gate.show(makeContent(value: "42%"), scale: 1) { content, scale in shown.append((content, scale)) }
        gate.show(makeContent(value: "42%"), scale: 1.2) { content, scale in shown.append((content, scale)) }
        gate.show(makeContent(value: "42%"), scale: 1.2) { content, scale in shown.append((content, scale)) }
        XCTAssertEqual(shown.map(\.1), [1, 1.2])
    }

    func testAChangedOverflowIsShown() {
        var shown: [MenuBarContent] = []
        var gate = StatusItemController.StripGate()
        var more = makeContent(value: "42%")
        more.overflow = 2
        gate.show(makeContent(value: "42%"), scale: 1) { content, _ in shown.append(content) }
        gate.show(more, scale: 1) { content, _ in shown.append(content) }
        gate.show(more, scale: 1) { content, _ in shown.append(content) }
        XCTAssertEqual(shown, [makeContent(value: "42%"), more])
    }

    private func makeContent(value: String) -> MenuBarContent {
        MenuBarContent(items: [MenuBarContent.Item(
            id: "claude.session",
            provider: Provider(id: "claude", kind: .claude),
            label: "Session",
            shortLabel: "Session",
            value: value
        )])
    }
}
