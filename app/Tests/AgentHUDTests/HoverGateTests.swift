import XCTest
@testable import AgentHUD

/// Regression: on multi-display setups the cursor crosses the notch strip on
/// its way to another screen, and every crossing used to pop the panel open.
final class HoverGateTests: XCTestCase {
    func testFastTransitDoesNotEngage() {
        var gate = HoverGate()
        // Cursor sweeping across the notch toward another display: big jumps.
        XCTAssertNil(gate.update(point: CGPoint(x: 100, y: 10), inside: false))
        XCTAssertNil(gate.update(point: CGPoint(x: 400, y: 10), inside: true))
        XCTAssertNil(gate.update(point: CGPoint(x: 700, y: 10), inside: true))
        XCTAssertNil(gate.update(point: CGPoint(x: 1000, y: 10), inside: false))
        XCTAssertFalse(gate.engaged)
    }

    func testDeliberateHoverEngages() {
        var gate = HoverGate()
        XCTAssertNil(gate.update(point: CGPoint(x: 600, y: 300), inside: false))
        // Arrives fast...
        XCTAssertNil(gate.update(point: CGPoint(x: 620, y: 8), inside: true))
        // ...then settles: engages on the next slow sample.
        XCTAssertEqual(gate.update(point: CGPoint(x: 622, y: 8), inside: true), true)
        XCTAssertTrue(gate.engaged)
    }

    func testEngagesOnlyOncePerEntry() {
        var gate = HoverGate()
        _ = gate.update(point: CGPoint(x: 600, y: 8), inside: true)
        XCTAssertEqual(gate.update(point: CGPoint(x: 601, y: 8), inside: true), true)
        // Still inside and still hovering — no repeat events.
        XCTAssertNil(gate.update(point: CGPoint(x: 602, y: 8), inside: true))
        XCTAssertNil(gate.update(point: CGPoint(x: 603, y: 8), inside: true))
    }

    func testLeavingDisengagesImmediately() {
        var gate = HoverGate()
        _ = gate.update(point: CGPoint(x: 600, y: 8), inside: true)
        _ = gate.update(point: CGPoint(x: 601, y: 8), inside: true)
        XCTAssertTrue(gate.engaged)
        XCTAssertEqual(gate.update(point: CGPoint(x: 601, y: 400), inside: false), false)
        XCTAssertFalse(gate.engaged)
        // Leaving again reports nothing — one event per transition.
        XCTAssertNil(gate.update(point: CGPoint(x: 601, y: 500), inside: false))
    }

    func testDwellResetsWhenPointerLeavesMidDwell() {
        var gate = HoverGate()
        XCTAssertNil(gate.update(point: CGPoint(x: 600, y: 8), inside: true))
        XCTAssertNil(gate.update(point: CGPoint(x: 601, y: 400), inside: false))
        // One slow sample back inside is not enough — dwell restarts.
        XCTAssertNil(gate.update(point: CGPoint(x: 601, y: 8), inside: true))
        XCTAssertFalse(gate.engaged)
    }
}
