import XCTest
@testable import AgentHUD

@MainActor
final class AppStateTests: XCTestCase {
    private func makeState() -> AppState {
        let s = AppState()
        s.expandOnCopy = true
        s.musicEnabled = true
        s.muted = false
        return s
    }

    private func clip(_ text: String) -> ClipboardItem {
        ClipboardItem(kind: .text, text: text, image: nil,
                      signature: clipboardSignature(kind: .text, text: text, data: nil))
    }

    // MARK: - Clipboard

    /// Regression: apps re-assert the pasteboard on focus change (routine when
    /// moving between displays), which replayed the same copy preview forever.
    func testIdenticalClipboardContentIsIgnored() {
        let s = makeState()
        s.clipboardChanged(clip("hello"))
        XCTAssertEqual(s.clipboard.count, 1)
        s.collapse()

        s.clipboardChanged(clip("hello"))
        XCTAssertEqual(s.clipboard.count, 1, "re-asserted pasteboard must not add an entry")
        XCTAssertTrue(s.hudState.isCollapsed, "re-asserted pasteboard must not peek")
    }

    func testDifferentClipboardContentStillPeeks() {
        let s = makeState()
        s.clipboardChanged(clip("first"))
        s.collapse()
        s.clipboardChanged(clip("second"))
        XCTAssertEqual(s.clipboard.count, 2)
        if case .peek(.clipboard) = s.hudState {} else {
            XCTFail("a genuinely new copy should peek, got \(s.hudState)")
        }
    }

    /// Changed 2026-08-16: a re-copy of an older chip (usually a click on it)
    /// moves it to the front instead of growing a duplicate, and doesn't peek
    /// — you were looking right at the strip.
    func testCopyingSameTextAgainMovesItForwardWithoutDuplicating() {
        let s = makeState()
        s.clipboardChanged(clip("a"))
        s.clipboardChanged(clip("b"))
        s.collapse()
        s.clipboardChanged(clip("a"))
        XCTAssertEqual(s.clipboard.count, 2, "identical content must not duplicate")
        XCTAssertEqual(s.clipboard.first?.text, "a", "but it does move up")
        XCTAssertTrue(s.hudState.isCollapsed, "and it isn't news worth a peek")
    }

    // MARK: - Music

    private func track(_ title: String, playing: Bool = true) -> NowPlaying {
        NowPlaying(app: "YouTube", title: title, artist: "chan", playing: playing, artworkURL: "")
    }

    /// Regression: background tabs get throttled, so the web track went stale
    /// and came back repeatedly — each return re-announced the same song.
    func testSameTrackDoesNotRePeek() {
        let s = makeState()
        s.setWebNowPlaying(track("Song A"))
        if case .peek(.music) = s.hudState {} else { XCTFail("first play should peek") }
        s.collapse()

        s.setWebNowPlaying(track("Song A"))
        XCTAssertTrue(s.hudState.isCollapsed, "same track must not peek again")
    }

    func testStaleThenReturningTrackDoesNotRePeek() {
        let s = makeState()
        s.setWebNowPlaying(track("Song A"))
        s.collapse()
        // Simulate the poll that finds no native player while web data lapsed.
        s.composeNowPlaying(native: nil)
        s.setWebNowPlaying(track("Song A"))
        XCTAssertTrue(s.hudState.isCollapsed, "a lapse in reporting is not a new song")
    }

    func testNewTrackPeeks() {
        let s = makeState()
        s.setWebNowPlaying(track("Song A"))
        s.collapse()
        s.setWebNowPlaying(track("Song B"))
        if case .peek(.music) = s.hudState {} else { XCTFail("a new song should peek") }
    }

    // MARK: - Alerting policy

    func testShortDoneIsSilent() {
        XCTAssertFalse(AppState.shouldAlert(kind: .done, runDuration: 5, muted: false))
    }

    func testLongDoneAlerts() {
        XCTAssertTrue(AppState.shouldAlert(kind: .done, runDuration: 600, muted: false))
    }

    func testAttentionAlwaysAlerts() {
        XCTAssertTrue(AppState.shouldAlert(kind: .attention, runDuration: 0, muted: false))
    }

    func testMuteSilencesEverything() {
        XCTAssertFalse(AppState.shouldAlert(kind: .attention, runDuration: 0, muted: true))
        XCTAssertFalse(AppState.shouldAlert(kind: .done, runDuration: 6000, muted: true))
    }

    func testRunningNeverAlerts() {
        XCTAssertFalse(AppState.shouldAlert(kind: .running, runDuration: 6000, muted: false))
    }

    // MARK: - Sessions

    func testSessionsTrackStateAndAttentionCount() {
        let s = makeState()
        s.apply(AgentEvent(kind: .running, host: "box", project: "p", sessionId: "1",
                           sessionName: "one", message: "", hook: "t", image: nil, ts: Date()))
        XCTAssertEqual(s.runningCount, 1)
        s.apply(AgentEvent(kind: .attention, host: "box", project: "p", sessionId: "1",
                           sessionName: "one", message: "perm", hook: "t", image: nil, ts: Date()))
        XCTAssertEqual(s.runningCount, 0)
        XCTAssertEqual(s.attentionCount, 1)
        XCTAssertEqual(s.aggregate, .attention, "attention must win the collapsed indicator")
    }

    func testEventsFromDifferentHostsAreSeparateSessions() {
        let s = makeState()
        for host in ["mac", "box"] {
            s.apply(AgentEvent(kind: .running, host: host, project: "p", sessionId: "same",
                               sessionName: "n", message: "", hook: "t", image: nil, ts: Date()))
        }
        XCTAssertEqual(s.sessions.count, 2, "same session id on two machines is two sessions")
    }
}
