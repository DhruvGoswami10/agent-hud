import XCTest
@testable import AgentHUD

@MainActor
final class ReliabilityTests: XCTestCase {
    func testClaudeRegistryDoesNotOwnCursorTask() {
        let s = AppState()
        s.apply(AgentEvent(kind: .running, host: "box", project: "project", sessionId: "cursor",
                          sessionName: "task", message: "working", hook: "beforeSubmitPrompt",
                          app: "cursor", image: nil, ts: Date(timeIntervalSinceNow: -300)))
        s.syncRegistry(host: "box", entries: [])
        XCTAssertEqual(s.sessions.first?.kind, .running)
    }

    func testUnknownContextCapacityHasNoPercentage() {
        var s = SessionInfo(id: "S", host: "box", project: "p", sessionName: "task",
                            kind: .running, message: "", updated: Date())
        s.ctxUsed = 220_001
        XCTAssertNil(s.ctxFraction)
    }

    func testClearEventsPreservesLiveSessions() {
        let s = AppState()
        s.apply(AgentEvent(kind: .running, host: "box", project: "p", sessionId: "S",
                          sessionName: "task", message: "working", hook: "t", image: nil, ts: Date()))
        s.clearEvents()
        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertTrue(s.events.isEmpty)
    }

    func testClipboardUsesFullIdentityAndKeepsWhitespace() throws {
        let prefix = String(repeating: "x", count: 900)
        let a = try XCTUnwrap(ClipboardWatcher.item(from: .text(prefix + "A\n ")))
        let b = try XCTUnwrap(ClipboardWatcher.item(from: .text(prefix + "B\n ")))
        XCTAssertNotEqual(a.signature, b.signature)
        XCTAssertEqual(a.fullText, prefix + "A\n ")
        let fileA = try XCTUnwrap(ClipboardWatcher.item(from: .files([URL(fileURLWithPath: "/A/report.pdf")])))
        let fileB = try XCTUnwrap(ClipboardWatcher.item(from: .files([URL(fileURLWithPath: "/B/report.pdf")])))
        XCTAssertNotEqual(fileA.signature, fileB.signature)
    }

    func testOversizedClipboardCannotPretendToRestoreOriginal() throws {
        let item = try XCTUnwrap(ClipboardWatcher.item(from: .text(String(repeating: "x", count: 128_001))))
        XCTAssertFalse(item.isRestorable)
        XCTAssertTrue(item.fullText.isEmpty)
        XCTAssertEqual(item.text.count, 800)
    }

    func testProvidersWithSameSessionIDAreDistinct() {
        let s = AppState()
        for app in ["claude", "codex", "cursor"] {
            s.apply(AgentEvent(kind: .running, host: "box", project: "p", sessionId: "same",
                              sessionName: "task", message: "working", hook: "t", app: app, image: nil, ts: Date()))
        }
        XCTAssertEqual(Set(s.sessions.map(\.id)).count, 3)
    }

    func testStaleRegistryCannotReviveExplicitCompletion() {
        let s = AppState()
        let busy = LocalSessionEntry(sessionId: "S", name: "n", cwd: "/tmp/p", status: "busy",
                                     updatedAt: Date(timeIntervalSinceNow: -5).timeIntervalSince1970 * 1000, app: "codex")
        s.syncRegistry(host: "box", entries: [busy])
        s.apply(AgentEvent(kind: .done, host: "box", project: "p", sessionId: "S",
                          sessionName: "", message: "finished", hook: "notify", app: "codex", image: nil, ts: Date()))
        s.syncRegistry(host: "box", entries: [busy])
        XCTAssertEqual(s.sessions.first?.kind, .done)
        s.syncRegistry(host: "box", entries: [])
        XCTAssertEqual(s.sessions.first?.outcome, .finished)
    }

    func testExpiredLimitsDisappearWithoutAnotherSuccessfulReading() {
        let s = AppState()
        let limit = AccountLimits(key: "a", source: "api", fetchedAt: Date(), accountName: "test", plan: "",
                                  items: [LimitItem(kind: "5h", label: "5h", percent: 5, severity: "normal", resetsAt: nil)], retention: 1)
        s.syncRegistry(RegistryReport(host: "box", entries: [], limits: [limit]))
        XCTAssertEqual(s.accountLimits.count, 1)
        s.maintenanceSweep(now: Date(timeIntervalSinceNow: 2))
        XCTAssertTrue(s.accountLimits.isEmpty)
    }

    func testActiveMusicWinsOverPausedSpotify() {
        let paused = NowPlaying(app: "Spotify", title: "A", artist: "", playing: false, artworkURL: "")
        let active = NowPlaying(app: "Music", title: "B", artist: "", playing: true, artworkURL: "")
        XCTAssertEqual(MusicWatcher.preferred([paused, active]), active)
    }

    func testEdgeCanvasFitsVisibleScreenAtBothExtremes() {
        let screen = CGRect(x: 0, y: 24, width: 1440, height: 852)
        for anchor in [0.22, 0.80] {
            let rect = NotchWindowController.anchorRect(for: CGSize(width: 800, height: 600), screen: screen,
                metrics: .init(notchWidth: 0, notchHeight: 0, hasNotch: false, edge: .right), anchor: anchor, dropY: 0)
            XCTAssertTrue(screen.contains(rect))
        }
    }

    func testTimedHoldRestoresItsOriginalDeadline() {
        let d = UserDefaults.standard
        let savedHold = d.object(forKey: "keepAwake")
        let savedDeadline = d.object(forKey: "keepAwakeUntil")
        defer {
            d.set(savedHold, forKey: "keepAwake")
            d.set(savedDeadline, forKey: "keepAwakeUntil")
        }
        let s = AppState()
        s.holdAwake(minutes: 15)
        let restored = AppState()
        XCTAssertEqual(restored.keepAwakeUntil, s.keepAwakeUntil)
        d.set(Date(timeIntervalSinceNow: -1), forKey: "keepAwakeUntil")
        let expired = AppState()
        XCTAssertFalse(expired.keepAwake)
        XCTAssertNil(expired.keepAwakeUntil)
    }
}
