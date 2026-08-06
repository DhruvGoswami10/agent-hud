import XCTest
@testable import AgentHUD

/// The keep-awake policy, rebuilt after the "sleep thing is not working"
/// investigation (2026-08-06). Forensics showed every real sleep was an
/// unpreventable lid-close; these tests guard the parts that ARE ours.
final class AwakePolicyTests: XCTestCase {
    func testManualHoldWinsEverything() {
        XCTAssertEqual(AppState.desiredHold(keepAwake: true, autoAwake: false,
                                            running: 0, attention: 0, lastBusyAge: nil), .display)
    }

    func testRunningAgentsHoldSystem() {
        XCTAssertEqual(AppState.desiredHold(keepAwake: false, autoAwake: true,
                                            running: 2, attention: 0, lastBusyAge: 0), .system)
    }

    /// An agent blocked on a permission prompt is exactly when reachability
    /// matters most — it must hold the Mac awake.
    func testAttentionHoldsSystem() {
        XCTAssertEqual(AppState.desiredHold(keepAwake: false, autoAwake: true,
                                            running: 0, attention: 1, lastBusyAge: 0), .system)
    }

    /// Bursty overnight agents pause between runs; releasing instantly would
    /// let the Mac sleep and kill every tunnel — and sleep is a one-way door.
    func testLingerHoldsAfterAgentsGoQuiet() {
        XCTAssertEqual(AppState.desiredHold(keepAwake: false, autoAwake: true,
                                            running: 0, attention: 0, lastBusyAge: 300), .system)
    }

    func testLingerExpires() {
        XCTAssertEqual(AppState.desiredHold(keepAwake: false, autoAwake: true,
                                            running: 0, attention: 0,
                                            lastBusyAge: AppState.autoLinger + 1), .off)
    }

    func testAutoOffMeansOff() {
        XCTAssertEqual(AppState.desiredHold(keepAwake: false, autoAwake: false,
                                            running: 5, attention: 5, lastBusyAge: 0), .off)
    }

    func testNeverBusyMeansOff() {
        XCTAssertEqual(AppState.desiredHold(keepAwake: false, autoAwake: true,
                                            running: 0, attention: 0, lastBusyAge: nil), .off)
    }

    /// The jiggle threshold must beat macOS's shortest lock setting (1 min)
    /// even in the worst case: threshold + renew interval < 60s.
    func testJiggleBeatsTheMinimumLockWindow() {
        XCTAssertLessThan(Caffeine.jiggleAfterIdle + Caffeine.renewInterval, 60)
    }

    /// Self-healing invariant: a crashed app must shed its assertion quickly.
    func testAssertionTimeoutOutlivesRenewals() {
        XCTAssertGreaterThan(Caffeine.assertionTimeout, Caffeine.renewInterval * 2,
                             "renewal must comfortably outpace the timeout")
        XCTAssertLessThanOrEqual(Caffeine.assertionTimeout, 120,
                                 "a dead app must stop holding the Mac within ~2 min")
    }
}

/// Regression: a dead tunnel froze remote sessions at "running" forever,
/// latching auto-awake and draining the battery all night.
@MainActor
final class MaintenanceSweepTests: XCTestCase {
    private func running(_ host: String, id: String) -> AgentEvent {
        AgentEvent(kind: .running, host: host, project: "p", sessionId: id,
                   sessionName: "s", message: "", hook: "t", image: nil, ts: Date())
    }

    func testSilentHostSessionsAreDemoted() {
        let s = AppState()
        s.apply(running("box6", id: "1"))
        s.hostLastReport["box6"] = Date(timeIntervalSinceNow: -200)
        s.maintenanceSweep()
        XCTAssertEqual(s.sessions.first?.kind, .done)
        XCTAssertEqual(s.sessions.first?.message, "lost contact")
        XCTAssertEqual(s.runningCount, 0, "a dead tunnel must not hold the Mac awake")
    }

    func testFreshHostSessionsSurvive() {
        let s = AppState()
        s.apply(running("box6", id: "1"))
        s.hostLastReport["box6"] = Date(timeIntervalSinceNow: -5)
        s.maintenanceSweep()
        XCTAssertEqual(s.sessions.first?.kind, .running)
    }

    /// Hook-only sources (e.g. browser tabs) never report via the registry;
    /// silence there is normal and must not demote their sessions.
    func testHostsThatNeverReportedAreLeftAlone() {
        let s = AppState()
        s.apply(running("web", id: "chatgpt-1"))
        s.maintenanceSweep()
        XCTAssertEqual(s.sessions.first?.kind, .running)
    }

    func testDemotedAttentionReleasesTheBadge() {
        let s = AppState()
        s.apply(AgentEvent(kind: .attention, host: "box6", project: "p", sessionId: "1",
                           sessionName: "s", message: "perm", hook: "t", image: nil, ts: Date()))
        XCTAssertEqual(s.pendingAttention, 1)
        s.hostLastReport["box6"] = Date(timeIntervalSinceNow: -200)
        s.maintenanceSweep()
        XCTAssertEqual(s.pendingAttention, 0)
        XCTAssertEqual(s.attentionCount, 0)
    }

    func testOldFinishedSessionsArePruned() {
        let s = AppState()
        s.apply(running("box6", id: "1"))
        s.hostLastReport["box6"] = Date(timeIntervalSinceNow: -200)
        s.maintenanceSweep(now: Date())
        // Second sweep far in the future prunes the demoted session entirely.
        s.maintenanceSweep(now: Date(timeIntervalSinceNow: 3600))
        XCTAssertTrue(s.sessions.isEmpty)
    }
}
