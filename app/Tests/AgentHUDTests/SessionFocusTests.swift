import XCTest
@testable import AgentHUD

@MainActor
final class SessionFocusTests: XCTestCase {
    private let workspace = "A1459D36-9666-44B4-BD6D-B27A5F97B0D9"
    private let surface = "E13F2348-1B32-4206-BCA2-042BDAC9F359"

    func testWarpAcceptsOnlySessionLinks() {
        let url = "warp://session/a1459d36966644b4bd6db27a5f97b0d9"
        let focus = SessionFocus(json: ["warp_url": url])
        XCTAssertEqual(focus.warpURL, url)
        XCTAssertEqual(focus.actionTitle, "Go to session")
        for invalid in ["warp://action/new_tab?path=/tmp", url + "?command=test", "warp://session/not-a-uuid",
                        "https://example.com/", "warp://user@session/" + workspace] {
            XCTAssertTrue(SessionFocus(json: ["warp_url": invalid]).warpURL.isEmpty)
        }
    }

    func testChangingTerminalDoesNotRetainAnUnrelatedPane() {
        let old = SessionFocus(json: ["application": "com.cmuxterm.app", "workspace": workspace, "surface": surface])
        let next = SessionFocus(json: ["application": "dev.warp.Warp-Stable",
                                      "warp_url": "warp://session/a1459d36966644b4bd6db27a5f97b0d9"])
        XCTAssertTrue(old.merging(next).workspace.isEmpty)
        XCTAssertTrue(old.merging(next).surface.isEmpty)
        XCTAssertEqual(old.merging(next).warpURL, next.warpURL)
    }

    func testTerminalIdentifiersAreValidated() {
        let valid = SessionFocus(json: ["application": "com.apple.Terminal", "tty": "/dev/ttys003"])
        XCTAssertEqual(valid.tty, "/dev/ttys003")
        XCTAssertTrue(SessionFocus(json: ["tty": "/dev/ttys003\nanything"]).tty.isEmpty)
        XCTAssertTrue(SessionFocus(json: ["terminal_id": "not a session"]).terminalID.isEmpty)
        XCTAssertTrue(SessionFocus(json: ["application": "/tmp/arbitrary-app"]).application.isEmpty)
        XCTAssertEqual(valid.actionTitle, "Go to session")
    }

    func testCmuxUsesItsPublicNavigationLinkFromStandaloneApps() {
        let focus = SessionFocus(json: ["workspace": workspace, "surface": surface])
        XCTAssertEqual(focus.cmuxURL?.absoluteString, "cmux://workspace/" + workspace + "/surface/" + surface)
        XCTAssertEqual(SessionFocus(json: ["workspace": workspace]).cmuxURL?.absoluteString,
                       "cmux://workspace/" + workspace)
        XCTAssertNil(SessionFocus(json: ["workspace": "../../anything"]).cmuxURL)
    }

    func testRemoteSSHConnectionIsNavigableAndSurvivesSparseRefreshes() {
        let connection = "192.0.2.10 49152 198.51.100.20 22"
        let focus = SessionFocus(json: ["ssh_connection": connection])
        XCTAssertTrue(focus.hasLocation)
        XCTAssertTrue(focus.canJumpBack(app: "claude", local: false))
        XCTAssertEqual(focus.merging(SessionFocus(cwd: "/tmp/project")).sshConnection, connection)
        let oldPane = SessionFocus(json: ["workspace": workspace, "surface": surface])
        XCTAssertTrue(oldPane.merging(focus).workspace.isEmpty,
                      "a different SSH connection must not retain an old pane")
        for invalid in ["host 22 server 22", "192.0.2.10 99999 198.51.100.20 22", "$(command)"] {
            XCTAssertTrue(SessionFocus(json: ["ssh_connection": invalid]).sshConnection.isEmpty)
        }
        XCTAssertFalse(SessionFocus(cwd: "/remote/path").canJumpBack(app: "claude", local: false))
    }

    func testAChangedBrowserClientDoesNotReuseAnOldTabNumber() {
        let old = SessionFocus(json: ["browser_client": workspace, "browser_tab": "12",
                                      "url": "https://chatgpt.com/c/one"])
        let next = old.merging(SessionFocus(json: ["browser_client": surface]))
        XCTAssertTrue(next.browserTab.isEmpty)
        XCTAssertFalse(next.hasBrowserTab)
        XCTAssertTrue(SessionFocus(json: ["url": "https://chatgpt.com:8000/c/one"]).url.isEmpty)
    }

    func testBrowserNavigationWaitsForTheMatchingAcknowledgment() throws {
        let (state, queue) = browserFixture()
        state.openPanel()
        state.focusSession(try XCTUnwrap(state.sessions.first))
        let command = try XCTUnwrap(queue.pop(for: workspace).first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any])
        let id = try XCTUnwrap(object["id"] as? String)
        XCTAssertEqual(object["tab"] as? String, "12")
        XCTAssertEqual(object["url"] as? String, "https://chatgpt.com/c/one")
        XCTAssertTrue(state.navigationBusy)
        XCTAssertTrue(state.hudState.isOpen)
        state.focusSession(try XCTUnwrap(state.sessions.first))
        XCTAssertTrue(queue.pop(for: workspace).isEmpty, "repeated clicks must not queue another focus")
        state.browserFocusFinished(id: UUID().uuidString, ok: true)
        XCTAssertTrue(state.navigationBusy, "an old tab's acknowledgment cannot finish this request")
        state.browserFocusFinished(id: id, ok: true)
        XCTAssertFalse(state.navigationBusy)
        XCTAssertTrue(state.hudState.isCollapsed)
    }

    func testFailedBrowserNavigationKeepsAnExplicitLinkFallback() throws {
        let (state, queue) = browserFixture()
        state.openPanel()
        state.focusSession(try XCTUnwrap(state.sessions.first))
        let command = try XCTUnwrap(queue.pop(for: workspace).first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any])
        state.browserFocusFinished(id: try XCTUnwrap(object["id"] as? String), ok: false)
        XCTAssertFalse(state.navigationBusy)
        XCTAssertTrue(state.navigationLinkFallback)
        XCTAssertFalse(state.navigationMessage.isEmpty)
        XCTAssertTrue(state.hudState.isOpen)
    }

    func testOldBrowserCommandsExpireInsteadOfStealingFocusLater() {
        let queue = CommandQueue(maxAge: 5)
        XCTAssertFalse(queue.isConnected(workspace))
        _ = queue.pop(for: workspace)
        XCTAssertTrue(queue.isConnected(workspace))
        XCTAssertFalse(queue.isConnected(workspace, now: Date().addingTimeInterval(46)))
        queue.push("old focus command", tab: workspace)
        XCTAssertTrue(queue.pop(for: workspace, now: Date().addingTimeInterval(6)).isEmpty)
    }

    private func browserFixture() -> (AppState, CommandQueue) {
        let state = AppState()
        let queue = CommandQueue(maxAge: 5)
        state.browserCommands = queue
        _ = queue.pop(for: workspace)
        state.apply(AgentEvent.from(json: ["event": "running", "host": "web", "app": "chatgpt",
            "session_id": "web-test", "focus": ["browser_client": workspace, "browser_tab": "12",
                "url": "https://chatgpt.com/c/one", "application": "com.google.Chrome"]])!)
        return (state, queue)
    }

    func testRegistryHeartbeatPreservesTheExactHookLocation() {
        let state = AppState()
        state.apply(AgentEvent.from(json: ["event": "running", "host": "test", "app": "codex",
            "session_id": "S", "cwd": "/tmp/project",
            "focus": ["workspace": workspace, "surface": surface]])!)
        let row = LocalSessionEntry(sessionId: "S", name: "test", cwd: "/tmp/project", status: "busy",
            updatedAt: Date().timeIntervalSince1970 * 1000, app: "codex",
            focus: SessionFocus(cwd: "/tmp/project"))
        state.syncRegistry(host: "test", entries: [row])
        XCTAssertEqual(state.sessions.first?.focus.workspace, workspace)
        XCTAssertEqual(state.sessions.first?.focus.surface, surface)
    }

    func testSparseCompletionPreservesTheExactHookLocation() {
        let state = AppState()
        state.apply(AgentEvent.from(json: ["event": "running", "host": "test", "app": "codex",
            "session_id": "S", "focus": ["workspace": workspace, "surface": surface]])!)
        state.apply(AgentEvent.from(json: ["event": "done", "host": "test", "app": "codex",
            "session_id": "S", "cwd": "/tmp/project"])!)
        XCTAssertEqual(state.sessions.first?.focus.workspace, workspace)
        XCTAssertEqual(state.sessions.first?.focus.surface, surface)
    }
}
