import XCTest
@testable import AgentHUD

/// The split-brain bug: the Mac answers to several names (hostname flips with
/// corporate DNS), which used to split one machine into two "hosts" with
/// duplicate session cards that the sweep could never reach.
@MainActor
final class HostNormalizationTests: XCTestCase {
    func testLocalNameFormsCollapse() {
        XCTAssertEqual(AppState.Host.normalize(ProcessInfo.processInfo.hostName), "Mac")
        XCTAssertEqual(AppState.Host.normalize("mac"), "Mac")
        XCTAssertTrue(AppState.Host.isLocal("Mac"))
        XCTAssertEqual(AppState.Host.normalize("l-dev-aiplayground-02"), "l-dev-aiplayground-02",
                       "remote boxes must pass through untouched")
    }

    func testTwoLocalNameFormsAreOneSession() {
        let s = AppState()
        s.apply(AgentEvent(kind: .running, host: "Mac", project: "p", sessionId: "S",
                           sessionName: "n", message: "", hook: "t", image: nil, ts: Date()))
        // The reporter reports the same session under the raw DNS hostname.
        let entry = LocalSessionEntry(sessionId: "S", name: "n", cwd: "/tmp/p",
                                      status: "busy", updatedAt: 1)
        s.syncRegistry(host: ProcessInfo.processInfo.hostName, entries: [entry])
        XCTAssertEqual(s.sessions.count, 1, "one machine must never appear as two hosts")
        XCTAssertEqual(s.sessions.first?.host, "Mac")
    }
}

/// The stuck-card class of bugs: sessions frozen in "needs you" or "working"
/// with no path back to done.
@MainActor
final class StuckSessionTests: XCTestCase {
    private func entry(_ sid: String, status: String, at: Double = 1) -> LocalSessionEntry {
        LocalSessionEntry(sessionId: sid, name: "n", cwd: "/tmp/p", status: status, updatedAt: at)
    }

    private func event(_ kind: EventKind, host: String, sid: String,
                       ts: Date = Date()) -> AgentEvent {
        AgentEvent(kind: kind, host: host, project: "p", sessionId: sid,
                   sessionName: "n", message: "m", hook: "t", image: nil, ts: ts)
    }

    /// An attention session whose registry entry goes idle must resolve —
    /// the guard used to cover only .running, so it glowed orange forever.
    func testAttentionSessionResolvesWhenRegistryGoesIdle() async throws {
        let s = AppState()
        s.finishVerdictDelay = 0.05
        s.syncRegistry(host: "box", entries: [entry("S", status: "busy")])
        s.apply(event(.attention, host: "box", sid: "S"))
        XCTAssertEqual(s.attentionCount, 1)
        s.syncRegistry(host: "box", entries: [entry("S", status: "idle", at: 2)])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(s.sessions.first?.kind, .done)
        XCTAssertEqual(s.attentionCount, 0)
        XCTAssertEqual(s.pendingAttention, 0)
    }

    /// An attention session that vanishes from the registry entirely (killed
    /// terminal) resolves to done and settles the attention count.
    func testAttentionSessionGoneFromRegistryResolves() {
        let s = AppState()
        s.syncRegistry(host: "box", entries: [entry("S", status: "busy")])
        s.apply(event(.attention, host: "box", sid: "S"))
        s.syncRegistry(host: "box", entries: [])
        XCTAssertEqual(s.sessions.first?.kind, .done)
        XCTAssertEqual(s.pendingAttention, 0)
    }

    /// A hook-created card for a session the host's registry never listed
    /// (died between reports) is pruned once the grace period passes.
    func testGhostAttentionCardIsPrunedByRegistry() {
        let s = AppState()
        s.apply(event(.attention, host: "box", sid: "ghost",
                      ts: Date(timeIntervalSinceNow: -300)))
        XCTAssertEqual(s.pendingAttention, 1)
        s.syncRegistry(host: "box", entries: [])
        XCTAssertEqual(s.sessions.first?.kind, .done)
        XCTAssertEqual(s.pendingAttention, 0)
    }

    func testFreshHookCardSurvivesThePruneGrace() {
        let s = AppState()
        s.apply(event(.attention, host: "box", sid: "young"))
        s.syncRegistry(host: "box", entries: [])
        XCTAssertEqual(s.sessions.first?.kind, .attention,
                       "a card inside the grace window must not be judged yet")
    }

    /// Web tabs never POST /sessions; a closed tab's card used to be
    /// unreachable by the sweep (no hostLastReport entry → skipped).
    func testClosedWebTabIsSwept() {
        let s = AppState()
        s.apply(event(.running, host: "web", sid: "tab",
                      ts: Date(timeIntervalSinceNow: -300)))
        s.maintenanceSweep()
        XCTAssertEqual(s.sessions.first?.kind, .done)
    }

    func testStreamingWebTabSurvivesSweep() {
        let s = AppState()
        s.apply(event(.running, host: "web", sid: "tab"))
        s.maintenanceSweep()
        XCTAssertEqual(s.sessions.first?.kind, .running,
                       "a tab inside the heartbeat window is alive")
    }

    /// Hook-only hosts with no registry get the generous safety net, not the
    /// web cutoff — a real turn can run a long time between hook events.
    func testHookOnlyHostGetsGenerousCutoff() {
        let s = AppState()
        s.apply(event(.running, host: "lonely", sid: "S",
                      ts: Date(timeIntervalSinceNow: -1800)))
        s.maintenanceSweep()
        XCTAssertEqual(s.sessions.first?.kind, .running, "30 min is a normal long turn")
        s.apply(event(.running, host: "lonely", sid: "S2",
                      ts: Date(timeIntervalSinceNow: -4000)))
        s.maintenanceSweep()
        XCTAssertEqual(s.sessions.first { $0.id.hasSuffix("S2") }?.kind, .done,
                       "past an hour it's a ghost")
    }

    /// The receipt fields ride the registry report into the session card.
    func testChangeReceiptFieldsFlowThroughRegistry() {
        let s = AppState()
        var e = entry("S", status: "busy")
        e.filesChanged = 7
        e.linesAdded = 412
        e.linesRemoved = 88
        e.topFile = "NotchView.swift"
        s.syncRegistry(host: "box", entries: [e])
        XCTAssertEqual(s.sessions.first?.filesChanged, 7)
        XCTAssertEqual(s.sessions.first?.linesAdded, 412)
        XCTAssertEqual(s.sessions.first?.linesRemoved, 88)
        XCTAssertEqual(s.sessions.first?.topFile, "NotchView.swift")
    }
}

@MainActor
final class ClipboardDedupeTests: XCTestCase {
    private func item(_ t: String) -> ClipboardItem {
        ClipboardItem(kind: .text, text: t, image: nil,
                      signature: clipboardSignature(kind: .text, text: t, data: nil))
    }

    /// Clicking an old chip re-copies it; the strip must move the SAME item
    /// forward (its view is mid "Copied" flash), not grow a duplicate.
    func testRecopyMovesExistingItemToFront() {
        let s = AppState()
        s.clipboardChanged(item("A"))
        s.clipboardChanged(item("B"))
        let originalId = s.clipboard.last?.id
        s.clipboardChanged(item("A"))  // fresh instance, same content
        XCTAssertEqual(s.clipboard.count, 2, "a re-copy is not a new entry")
        XCTAssertEqual(s.clipboard.first?.text, "A")
        XCTAssertEqual(s.clipboard.first?.id, originalId, "identity must survive the move")
    }

    func testReassertOfCurrentFirstIsIgnored() {
        let s = AppState()
        s.clipboardChanged(item("A"))
        let id = s.clipboard.first?.id
        s.clipboardChanged(item("A"))
        XCTAssertEqual(s.clipboard.count, 1)
        XCTAssertEqual(s.clipboard.first?.id, id)
    }
}

@MainActor
final class WebMusicArbitrationTests: XCTestCase {
    private func np(_ title: String, tab: String, playing: Bool) -> NowPlaying {
        NowPlaying(app: "YouTube", title: title, artist: "a", playing: playing,
                   artworkURL: "", tab: tab)
    }

    /// Two playing tabs report every 2s each; the one on the bar must stay
    /// there instead of the title flapping with every report.
    func testDisplayedTabIsStickyAmongPlayingTabs() {
        let s = AppState()
        s.setWebNowPlaying(np("one", tab: "t1", playing: true))
        XCTAssertEqual(s.nowPlaying?.title, "one")
        s.setWebNowPlaying(np("two", tab: "t2", playing: true))
        XCTAssertEqual(s.nowPlaying?.title, "one", "a second playing tab must not steal the bar")
        s.setWebNowPlaying(np("one", tab: "t1", playing: false))
        XCTAssertEqual(s.nowPlaying?.title, "two", "when the shown tab pauses, the playing one wins")
    }

    func testNativePlayerBeatsWebTabs() {
        let s = AppState()
        s.setWebNowPlaying(np("web", tab: "t1", playing: true))
        s.composeNowPlaying(native: NowPlaying(app: "Spotify", title: "native", artist: "x",
                                               playing: true, artworkURL: ""))
        XCTAssertEqual(s.nowPlaying?.app, "Spotify")
    }
}

final class CommandRoutingTests: XCTestCase {
    /// The old popAll() let any polling tab drain every queued command —
    /// button presses landed on whichever player asked first.
    func testTargetedCommandsDoNotLeakAcrossTabs() {
        let q = CommandQueue()
        q.push("playpause")          // legacy untargeted lane
        q.push("next", tab: "t1")
        XCTAssertEqual(q.pop(for: "t2"), [], "another tab must not steal commands")
        XCTAssertEqual(q.pop(for: "t1"), ["next"])
        XCTAssertEqual(q.pop(for: ""), ["playpause"])
        XCTAssertEqual(q.pop(for: "t1"), [])
    }

    /// The route switch matches bare paths — a query string used to 404.
    func testQueryStringsSurviveRouting() {
        let (path, query) = EventServer.splitTarget("/music/commands?tab=abc123")
        XCTAssertEqual(path, "/music/commands")
        XCTAssertEqual(EventServer.queryValue(query, "tab"), "abc123")
        XCTAssertEqual(EventServer.splitTarget("/health").path, "/health")
        XCTAssertNil(EventServer.queryValue("", "tab"))
        XCTAssertEqual(EventServer.queryValue("a=1&tab=x", "tab"), "x")
    }
}
