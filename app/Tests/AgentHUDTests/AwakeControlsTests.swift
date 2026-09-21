import XCTest
@testable import AgentHUD

final class AwakeStatusTests: XCTestCase {
    private func status(mode: AwakeMode = .manual, requested: Caffeine.Mode = .display,
                        alive: Bool = true, remaining: TimeInterval? = nil,
                        running: Int = 0, attention: Int = 0, grace: TimeInterval = 0,
                        idleResetAllowed: Bool = false) -> AwakeStatus {
        AwakeStatus(mode: mode, requested: requested, assertionAlive: alive,
                    remaining: remaining, running: running, attention: attention,
                    graceRemaining: grace, idleResetAllowed: idleResetAllowed)
    }

    func testAnUnavailableAssertionCannotClaimTheMacOrDisplayIsHeldAwake() {
        let s = status(alive: false)
        XCTAssertTrue(s.failed)
        XCTAssertFalse(s.active)
        XCTAssertFalse(s.displayOn)
        XCTAssertEqual(s.status, "Not active")
        XCTAssertEqual(s.badgeTitle, "Hold unavailable")
    }

    func testAutoReadyIsDifferentFromDisabledOrActivelyHolding() {
        let ready = status(mode: .auto, requested: .off, alive: false)
        XCTAssertEqual(ready.status, "Ready")
        XCTAssertEqual(ready.badgeTitle, "Sleep allowed")
        XCTAssertFalse(ready.failed)
        XCTAssertEqual(status(mode: .off, requested: .off).status, "Off")
        XCTAssertEqual(status(mode: .auto, requested: .system, running: 1).status, "Active")
    }

    func testSystemOnlyHoldDoesNotPromiseDisplayOrLockPrevention() {
        let s = status(requested: .system, idleResetAllowed: true)
        XCTAssertTrue(s.active)
        XCTAssertFalse(s.displayOn)
        XCTAssertEqual(s.title, "Mac stays awake")
        XCTAssertEqual(s.lockDescription, "Auto-lock follows macOS settings.")
    }

    func testDisplayHoldDoesNotPromiseLockPreventionWithoutPermission() {
        XCTAssertEqual(status().lockDescription, "Auto-lock follows macOS settings.")
        XCTAssertEqual(status(idleResetAllowed: true).lockDescription, "Idle-lock prevention enabled.")
    }

    func testAttentionAndGraceExplainWhyAutoIsStillHolding() {
        XCTAssertEqual(status(mode: .auto, requested: .system, running: 2, attention: 1).badgeDetail,
                       "Auto · Needs you")
        let grace = status(mode: .auto, requested: .system, grace: 61)
        XCTAssertEqual(grace.detail, "1:01 until sleep is allowed")
        XCTAssertEqual(grace.badgeDetail, "Auto · 2 min left")
    }

    func testCountdownRoundsUpWithoutSayingZeroWhileTimeRemains() {
        XCTAssertEqual(status(remaining: 0.1).badgeDetail, "Manual · 1 min left")
        XCTAssertEqual(status(remaining: 60.1).detail, "1:01 remaining")
        XCTAssertEqual(status(remaining: 0).detail, "Ending hold…")
        XCTAssertEqual(status().detail, "Until you stop it")
    }
}

@MainActor
final class AwakeControlsTests: XCTestCase {
    private func withState(_ body: (AppState) async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let keys = ["keepAwake", "keepAwakeUntil", "keepAwakeMinutes", "autoAwake", "keepScreenOn", "muted", "hoverCollapseDelay"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let s = AppState()
        s.selectAwakeMode(.off)
        s.muted = true
        defer {
            s.dismissNow()
            _ = Caffeine.shared.set(mode: .off)
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
        }
        try await body(s)
    }

    private func working(_ s: AppState) {
        s.apply(AgentEvent(kind: .running, host: "awake-test", project: "test", sessionId: "one",
                           sessionName: "test", message: "", hook: "test", image: nil, ts: Date()))
    }

    func testOffReleasesAutomaticAndManualHoldsEvenWhenAgentsAreBusy() async {
        await withState { s in
            working(s)
            s.selectAwakeMode(.auto)
            s.holdAwake(minutes: 30)
            s.selectAwakeMode(.off)
            XCTAssertFalse(s.autoAwake)
            XCTAssertFalse(s.keepAwake)
            XCTAssertNil(s.keepAwakeUntil)
            XCTAssertNil(s.keepAwakeMinutes)
            XCTAssertEqual(Caffeine.shared.mode, .off)
        }
    }

    func testEndHoldReturnsToAutoAndLetsTheDisplaySleep() async {
        await withState { s in
            working(s)
            s.selectAwakeMode(.auto)
            s.selectAwakeMode(.manual)
            s.releaseAwakeHold()
            XCTAssertEqual(s.awakeMode, .auto)
            XCTAssertEqual(Caffeine.shared.mode, .system)
        }
    }

    func testEndHoldReturnsToOffWhenAutoWasDisabled() async {
        await withState { s in
            working(s)
            s.selectAwakeMode(.manual)
            s.releaseAwakeHold()
            XCTAssertEqual(s.awakeMode, .off)
            XCTAssertEqual(Caffeine.shared.mode, .off)
        }
    }

    func testSelectingManualAgainDoesNotResetATimer() async {
        await withState { s in
            s.holdAwake(minutes: 30)
            let deadline = s.keepAwakeUntil
            s.selectAwakeMode(.manual)
            XCTAssertEqual(s.keepAwakeUntil, deadline)
            XCTAssertEqual(s.keepAwakeMinutes, 30)
            let restored = AppState()
            XCTAssertEqual(restored.keepAwakeUntil, deadline)
            XCTAssertEqual(restored.keepAwakeMinutes, 30)
        }
    }

    func testExpiredManualTimerReturnsToAutoWithoutRelightingDisplay() async {
        await withState { s in
            working(s)
            s.selectAwakeMode(.auto)
            s.holdAwake(minutes: 1, now: Date(timeIntervalSinceNow: -120))
            XCTAssertEqual(s.awakeMode, .auto)
            XCTAssertNil(s.keepAwakeMinutes)
            XCTAssertNil(s.keepAwakeUntil)
            XCTAssertEqual(Caffeine.shared.mode, .system)
        }
    }

    func testMovingFromNotchToControlsDoesNotCollapseTheParent() async throws {
        try await withState { s in
            s.hoverCollapseDelay = 0.02
            s.hoverChanged(true)
            s.awakeControlsPresented = true
            s.hoverChanged(false)
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertTrue(s.hudState.isOpen)
            s.awakeControlsPresented = false
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertTrue(s.hudState.isCollapsed)
            s.hoverChanged(true)
            XCTAssertTrue(s.hudState.isOpen, "closing awake controls must not break the next hover")
        }
    }

    func testDismissClosesControlsAndReleasesTheirHoverHold() async throws {
        try await withState { s in
            s.openPanel()
            s.awakeControlsPresented = true
            s.dismissNow()
            XCTAssertFalse(s.awakeControlsPresented)
            s.hoverCollapseDelay = 0.02
            s.hoverChanged(true)
            s.hoverChanged(false)
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertTrue(s.hudState.isCollapsed)
        }
    }
}
