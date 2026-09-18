import XCTest
import SwiftUI
@testable import AgentHUD

@MainActor
final class NotificationInteractionTests: XCTestCase {
    private func completion(_ id: String, host: String = "test") -> AgentEvent {
        AgentEvent.from(json: ["event": "done", "host": host, "app": "codex",
                              "session_id": "S", "message": "Finished", "event_id": id])!
    }

    func testRetriedCompletionStaysDismissed() {
        let state = AppState()
        state.muted = false
        state.apply(completion("turn-one"))
        state.dismissNow()
        for _ in 0..<20 { state.apply(completion("turn-one")) }
        XCTAssertTrue(state.hudState.isCollapsed, "a repeated event must not undo the user's dismissal")
        XCTAssertEqual(state.events.count, 1, "retries must not flood the event history")
        XCTAssertEqual(state.alertLog.count, 1, "retries must not repeat banners or sounds")
        state.apply(completion("turn-two"))
        guard case .peek = state.hudState else { return XCTFail("a new turn should still notify") }
    }

    func testOldCompletionRetryCannotFinishANewRun() {
        let state = AppState()
        state.apply(completion("turn-one"))
        state.apply(AgentEvent.from(json: ["event": "running", "host": "test", "app": "codex",
                                           "session_id": "S", "message": "Working"])!)
        state.dismissNow()
        state.apply(completion("turn-one"))
        XCTAssertEqual(state.sessions.first?.kind, .running)
        XCTAssertTrue(state.hudState.isCollapsed)
    }

    func testEventIDsAreScopedToTheirSource() {
        let state = AppState()
        state.apply(completion("same-id", host: "box-one"))
        state.apply(completion("same-id", host: "box-two"))
        XCTAssertEqual(state.events.count, 2)
        XCTAssertEqual(state.sessions.count, 2)
    }

    func testLegacyEventsWithoutIDsStillNotify() {
        let state = AppState()
        state.muted = false
        state.apply(completion(""))
        state.dismissNow()
        state.apply(completion(""))
        guard case .peek = state.hudState else { return XCTFail("legacy integrations remain supported") }
    }

    func testHUDHandlesTheFirstClickWhileAnotherAppIsActive() {
        let hosting = HUDHostingView(rootView: Text("A notification"))
        XCTAssertTrue(hosting.acceptsFirstMouse(for: nil),
                      "a notification click must dismiss, not only focus the panel")
    }

    func testMuteRetractsAnExistingSlideOutAndSuppressesNewOnes() {
        let state = AppState()
        state.muted = false
        defer { state.muted = false }
        let event = AgentEvent(kind: .attention, host: "test", project: "test", sessionId: "S",
                               sessionName: "test", message: "Needs attention", hook: "test", image: nil, ts: Date())
        state.apply(event)
        guard case .peek = state.hudState else { return XCTFail("expected an alert slide-out") }
        state.muted = true
        XCTAssertTrue(state.hudState.isCollapsed, "muting should retract the current alert")
        state.apply(event)
        XCTAssertTrue(state.hudState.isCollapsed, "new alerts must stay quiet while muted")
        XCTAssertEqual(state.sessions.first?.kind, .attention, "mute preserves the session's real state")
    }

    func testDisablingBannersImmediatelyClearsThePermissionWarning() {
        let state = AppState()
        state.systemNotifications = true
        state.refreshNotificationStatus()
        XCTAssertTrue(state.notificationsBlocked)
        state.systemNotifications = false
        XCTAssertFalse(state.notificationsBlocked, "the warning must not linger until the next maintenance timer")
    }

    func testDismissalBeforeHoverDwellPreventsImmediateReopening() {
        var gate = HoverGate()
        let p = CGPoint(x: 500, y: 10)
        _ = gate.update(point: p, inside: true)
        gate.suppressUntilExit()
        XCTAssertNil(gate.update(point: p, inside: true))
        XCTAssertNil(gate.update(point: p, inside: true))
        XCTAssertFalse(gate.engaged)
        _ = gate.update(point: CGPoint(x: 500, y: 200), inside: false)
        XCTAssertNil(gate.update(point: p, inside: true))
        XCTAssertEqual(gate.update(point: p, inside: true), true,
                       "hover-to-open resumes after leaving and returning")
    }

    func testReturningToTheNotchRearmsHoverInsideTheOldPopupBounds() {
        var gate = HoverGate()
        _ = gate.update(point: CGPoint(x: 600, y: 70), inside: true)
        gate.suppressUntilExit(within: CGRect(x: 400, y: 0, width: 470, height: 112))
        // Retraction moves the current bounds away from the stationary cursor.
        XCTAssertNil(gate.update(point: CGPoint(x: 600, y: 70), inside: false))
        // A deliberate move back to the notch must work even though the
        // pointer never left the old popup's much larger rectangle.
        XCTAssertNil(gate.update(point: CGPoint(x: 600, y: 15), inside: true))
        XCTAssertEqual(gate.update(point: CGPoint(x: 600, y: 15), inside: true), true)
    }

    func testPointerJitterAfterDismissalDoesNotReopenTheNotch() {
        var gate = HoverGate()
        _ = gate.update(point: CGPoint(x: 600, y: 15), inside: true)
        gate.suppressUntilExit(within: CGRect(x: 400, y: 0, width: 470, height: 112))
        for x in [600.0, 601, 599, 600] {
            XCTAssertNil(gate.update(point: CGPoint(x: x, y: 15), inside: true))
        }
        XCTAssertFalse(gate.engaged)
    }
}
