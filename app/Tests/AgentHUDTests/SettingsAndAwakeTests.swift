import XCTest
@testable import AgentHUD

/// Timed holds, the display/system split, and the assertion bookkeeping the
/// "does the awake button actually work?" audit turned up.
final class TimedHoldTests: XCTestCase {
    func testIndefiniteHoldNeverExpires() {
        XCTAssertFalse(AppState.holdExpired(keepAwake: true, until: nil, now: Date()),
                       "indefinitely means indefinitely")
    }

    func testTimedHoldExpiresAtItsDeadline() {
        let deadline = Date()
        XCTAssertTrue(AppState.holdExpired(keepAwake: true, until: deadline,
                                           now: deadline.addingTimeInterval(1)))
        XCTAssertFalse(AppState.holdExpired(keepAwake: true, until: deadline,
                                            now: deadline.addingTimeInterval(-1)))
    }

    func testNoHoldMeansNothingToExpire() {
        XCTAssertFalse(AppState.holdExpired(keepAwake: false,
                                            until: Date.distantPast, now: Date()))
    }

    /// Amphetamine's "allow the display to sleep": a manual hold that keeps
    /// the machine up without lighting the screen.
    func testManualHoldCanBeSystemOnly() {
        XCTAssertEqual(AppState.desiredHold(keepAwake: true, autoAwake: false, running: 0,
                                            attention: 0, lastBusyAge: nil, keepScreenOn: false),
                       .system)
        XCTAssertEqual(AppState.desiredHold(keepAwake: true, autoAwake: false, running: 0,
                                            attention: 0, lastBusyAge: nil, keepScreenOn: true),
                       .display)
    }
}

@MainActor
final class HoldLifecycleTests: XCTestCase {
    func testHoldForMinutesSetsADeadline() {
        let s = AppState()
        s.holdAwake(minutes: 30)
        XCTAssertTrue(s.keepAwake)
        let left = try? XCTUnwrap(s.awakeRemaining)
        XCTAssertEqual(left ?? 0, 1800, accuracy: 5)
    }

    func testIndefiniteHoldHasNoCountdown() {
        let s = AppState()
        s.holdAwake(minutes: 0)
        XCTAssertTrue(s.keepAwake)
        XCTAssertNil(s.awakeRemaining, "an indefinite hold must not show a countdown")
    }

    func testReleaseClearsBoth() {
        let s = AppState()
        s.holdAwake(minutes: 60)
        s.releaseAwakeHold()
        XCTAssertFalse(s.keepAwake)
        XCTAssertNil(s.awakeRemaining)
    }
}

@MainActor
final class DismissTests: XCTestCase {
    private func event(_ kind: EventKind, sid: String) -> AgentEvent {
        AgentEvent(kind: kind, host: "box", project: "p", sessionId: sid,
                   sessionName: "n", message: "m", hook: "t", image: nil, ts: Date())
    }

    /// The escape hatch for a peek that lands mid-thought.
    func testDismissNowCollapsesAndDropsHover() {
        let s = AppState()
        s.openPanel()
        XCTAssertTrue(s.hudState.isOpen)
        s.dismissNow()
        XCTAssertTrue(s.hudState.isCollapsed)
        XCTAssertFalse(s.hovering, "a dismissed HUD must not re-open from a stale hover")
    }

    /// Dismissing a card by hand must release what it was holding, or the
    /// glow outlives the card.
    func testDismissingACardReleasesItsAttention() {
        let s = AppState()
        s.apply(event(.attention, sid: "S"))
        XCTAssertEqual(s.pendingAttention, 1)
        XCTAssertEqual(s.aggregate, .attention)
        s.dismiss(sessionId: "box#S")
        XCTAssertEqual(s.sessions.first?.kind, .done)
        XCTAssertEqual(s.pendingAttention, 0)
        XCTAssertEqual(s.attentionCount, 0)
    }

    func testDismissingAnUnknownCardIsHarmless() {
        let s = AppState()
        s.dismiss(sessionId: "nope#nope")
        XCTAssertTrue(s.sessions.isEmpty)
    }

    /// The whole reason click-to-dismiss was unreachable: pointing at a
    /// slide-out expanded it into the full panel, so the click landed on the
    /// panel instead of the thing you were aiming at.
    func testHoveringASlideOutDoesNotExpandIt() {
        let s = AppState()
        // Set explicitly: preferences persist to shared UserDefaults, so a
        // sibling test flipping this would otherwise decide the outcome.
        s.hoverExpandsPeek = false
        s.apply(event(.attention, sid: "S"))
        guard case .peek = s.hudState else { return XCTFail("expected a peek") }
        s.hoverChanged(true)
        guard case .peek = s.hudState else {
            return XCTFail("hovering a slide-out must leave it a slide-out")
        }
        XCTAssertFalse(s.hudState.isOpen)
    }

    func testHoveringTheCollapsedNotchStillOpensThePanel() {
        let s = AppState()
        s.hoverExpandsPeek = false
        s.collapse()
        s.hoverChanged(true)
        XCTAssertTrue(s.hudState.isOpen, "the documented hover-to-open must survive")
    }

    /// Opt back in and the old behaviour returns intact.
    func testHoverExpandCanBeTurnedBackOn() {
        let s = AppState()
        s.hoverExpandsPeek = true
        s.apply(event(.attention, sid: "S"))
        s.hoverChanged(true)
        XCTAssertTrue(s.hudState.isOpen)
    }
}

final class PeekTimingDefaultsTests: XCTestCase {
    /// The durations must stay adjustable rather than drifting back into
    /// hard-coded constants.
    @MainActor
    func testDurationsAreSettable() {
        let s = AppState()
        s.attentionPeekSeconds = 5
        s.donePeekSeconds = 2
        s.clipboardPeekSeconds = 2
        s.musicPeekSeconds = 2
        XCTAssertEqual(s.attentionPeekSeconds, 5)
        XCTAssertEqual(s.donePeekSeconds, 2)
        XCTAssertEqual(s.clipboardPeekSeconds, 2)
        XCTAssertEqual(s.musicPeekSeconds, 2)
    }
}

/// The hover fix: leaving must be much more forgiving than entering, or the
/// panel snaps shut while you're moving around inside it.
final class HoverGeometryTests: XCTestCase {
    func testExitBoundaryIsLooserThanEntry() {
        XCTAssertGreaterThan(NotchWindowController.exitMargin,
                             NotchWindowController.enterMargin * 4,
                             "a tight exit boundary is what made the panel run away")
    }

    /// Idle stays exactly the notch by default; the resting indicator opts
    /// into a sliver to draw in.
    func testIdleIndicatorChangesTheCollapsedSize() {
        let m = NotchWindowController.Metrics(notchWidth: 200, notchHeight: 32, hasNotch: true)
        let invisible = NotchWindowController.contentSize(for: .collapsed, metrics: m,
                                                          aggregate: .info, sideBars: true)
        XCTAssertEqual(invisible.width, 200, "idle must be invisible by default")
        let showing = NotchWindowController.contentSize(for: .collapsed, metrics: m,
                                                        aggregate: .info, sideBars: true,
                                                        idleIndicator: true)
        XCTAssertGreaterThan(showing.width, 200, "the resting indicator needs room")
        XCTAssertEqual(showing.height, 32, "and must still not hang below the notch")
    }
}

final class UpdaterVersionTests: XCTestCase {
    func testNewerTagsAreDetected() {
        XCTAssertTrue(Updater.isNewer("v0.2.0", than: "v0.1.0"))
        XCTAssertTrue(Updater.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(Updater.isNewer("v0.1.1", than: "v0.1.0"))
    }

    func testSameOrOlderIsNotAnUpdate() {
        XCTAssertFalse(Updater.isNewer("v0.1.0", than: "v0.1.0"))
        XCTAssertFalse(Updater.isNewer("v0.1.0", than: "v0.2.0"))
    }

    /// `git describe` stamps commits past a tag as v0.1.0-7-gabc123[-dirty];
    /// that is the SAME release, not an older one, and must not nag.
    func testGitDescribeSuffixIsIgnored() {
        XCTAssertFalse(Updater.isNewer("v0.1.0", than: "v0.1.0-7-g7cae397-dirty"))
        XCTAssertTrue(Updater.isNewer("v0.2.0", than: "v0.1.0-7-g7cae397-dirty"))
    }

    func testUnparseableVersionsNeverClaimAnUpdate() {
        XCTAssertFalse(Updater.isNewer("nightly", than: "v0.1.0"))
        XCTAssertFalse(Updater.isNewer("v0.2.0", than: "unknown"))
    }
}
