import XCTest
import SwiftUI
@testable import AgentHUD

@MainActor
final class NotificationInteractionTests: XCTestCase {
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

    func testShrinkingThePanelDoesNotCountAsThePointerLeaving() {
        var gate = HoverGate()
        gate.suppressUntilExit(within: CGRect(x: 400, y: 0, width: 470, height: 112))
        // Retraction moves the current bounds away from the stationary cursor.
        XCTAssertNil(gate.update(point: CGPoint(x: 600, y: 70), inside: false))
        // Moving back toward the notch is still within the dismissed slide-out.
        XCTAssertNil(gate.update(point: CGPoint(x: 600, y: 15), inside: true))
        XCTAssertNil(gate.update(point: CGPoint(x: 600, y: 15), inside: true))
        XCTAssertFalse(gate.engaged)
        _ = gate.update(point: CGPoint(x: 600, y: 200), inside: false)
        XCTAssertNil(gate.update(point: CGPoint(x: 600, y: 15), inside: true))
        XCTAssertEqual(gate.update(point: CGPoint(x: 600, y: 15), inside: true), true)
    }
}
