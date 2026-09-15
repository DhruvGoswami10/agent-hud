import XCTest
import Combine
@testable import AgentHUD

/// A registry heartbeat arrives every few seconds from every machine and
/// almost always carries numbers the HUD already has. Each `@Published` write
/// republishes the whole object — re-running every mounted SwiftUI view and
/// rebuilding the menu-bar icon — so an unchanged heartbeat has to be silent.
/// Left unguarded this grew the app by hundreds of MB a day and eventually
/// pegged a core.
@MainActor
final class HeartbeatCostTests: XCTestCase {
    private var bag: Set<AnyCancellable> = []

    private func entry(ctx: Int = 1000, name: String = "work", files: Int = 2) -> LocalSessionEntry {
        LocalSessionEntry(sessionId: "s1", name: name, cwd: "/p/proj", status: "busy",
                          updatedAt: Date().timeIntervalSince1970 * 1000,
                          model: "claude-opus-5", effort: "high", ctxUsed: ctx,
                          lastIn: 10, lastOut: 5, outcome: "",
                          filesChanged: files, linesAdded: 8, linesRemoved: 1,
                          topFile: "App.swift", app: "claude", totalTokens: 900, turns: 3)
    }

    /// Counts publishes while `body` runs.
    private func publishes(of s: AppState, _ body: () -> Void) -> Int {
        var n = 0
        let c = s.objectWillChange.sink { _ in n += 1 }
        body()
        c.cancel()
        return n
    }

    func testIdenticalHeartbeatPublishesNothing() {
        let s = AppState()
        let usage = ["h5": 100, "d7": 400, "h5_peak": 50]
        let hours = [480_000: 25]
        s.syncRegistry(host: "mac", entries: [entry()], usage: usage, hours: hours)
        s.syncRegistry(host: "mac", entries: [entry()], usage: usage, hours: hours)  // settle
        let n = publishes(of: s) {
            s.syncRegistry(host: "mac", entries: [entry()], usage: usage, hours: hours)
        }
        XCTAssertEqual(n, 0, "an unchanged heartbeat must not republish the whole app")
    }

    func testChangedStatsStillPublish() {
        let s = AppState()
        s.syncRegistry(host: "mac", entries: [entry(ctx: 1000)], usage: ["h5": 1], hours: [:])
        s.syncRegistry(host: "mac", entries: [entry(ctx: 1000)], usage: ["h5": 1], hours: [:])
        let n = publishes(of: s) {
            s.syncRegistry(host: "mac", entries: [entry(ctx: 9999)], usage: ["h5": 1], hours: [:])
        }
        XCTAssertGreaterThan(n, 0, "real progress must still reach the UI")
        XCTAssertEqual(s.sessions.first(where: { $0.id == "Mac#s1" })?.ctxUsed, 9999)
    }

    func testChangedUsageStillPublishes() {
        let s = AppState()
        s.syncRegistry(host: "mac", entries: [entry()], usage: ["h5": 100], hours: [:])
        s.syncRegistry(host: "mac", entries: [entry()], usage: ["h5": 100], hours: [:])
        let n = publishes(of: s) {
            s.syncRegistry(host: "mac", entries: [entry()], usage: ["h5": 250], hours: [:])
        }
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(s.estH5, 250)
    }

    func testRenamingASessionStillPublishes() {
        let s = AppState()
        s.syncRegistry(host: "mac", entries: [entry(name: "old")], usage: [:], hours: [:])
        s.syncRegistry(host: "mac", entries: [entry(name: "old")], usage: [:], hours: [:])
        let n = publishes(of: s) {
            s.syncRegistry(host: "mac", entries: [entry(name: "renamed")], usage: [:], hours: [:])
        }
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(s.sessions.first(where: { $0.id == "Mac#s1" })?.sessionName, "renamed")
    }

    /// Liveness must survive the silence: a quiet heartbeat still records that
    /// the machine reported, or the sweep would demote it as lost contact.
    func testQuietHeartbeatStillCountsAsContact() {
        let s = AppState()
        s.syncRegistry(host: "mac", entries: [entry()], usage: ["h5": 1], hours: [:])
        s.hostLastReport["Mac"] = Date(timeIntervalSinceNow: -300)
        s.syncRegistry(host: "mac", entries: [entry()], usage: ["h5": 1], hours: [:])
        let age = Date().timeIntervalSince(s.hostLastReport["Mac"] ?? .distantPast)
        XCTAssertLessThan(age, 5, "a silent heartbeat is still contact")
    }

    /// The stats that ride along with a heartbeat are only worth a publish
    /// when one of them actually moved.
    func testSessionInfoEqualityCoversTheReportedFields() {
        var a = SessionInfo(id: "x", host: "Mac", project: "p", sessionName: "n",
                            kind: .running, message: "m", updated: Date())
        let b = a
        XCTAssertEqual(a, b)
        a.totalTokens = 5
        XCTAssertNotEqual(a, b, "token counts must count as a change")
    }
}
