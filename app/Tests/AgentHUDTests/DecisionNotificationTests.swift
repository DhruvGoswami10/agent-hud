import XCTest
import SwiftUI
@testable import AgentHUD

private func approval(_ session: String = "one", id: String = UUID().uuidString, now: Date = Date()) -> ApprovalRequest {
    ApprovalRequest(json: ["request_id": id, "session_id": session, "host": "test", "session_name": session,
                           "tool_name": "Bash", "tool_input": ["command": "printf 'demo'", "timeout": 1000]], now: now)!
}

final class PermissionBrokerTests: XCTestCase {
    func testRepliesAreBoundToOneRequestAndConsumedOnce() {
        let broker = PermissionBroker(), first = approval(), second = approval("two")
        var replies: [String] = []
        XCTAssertTrue(broker.offer(first) { replies.append("one:" + $0.rawValue) })
        XCTAssertTrue(broker.offer(second) { replies.append("two:" + $0.rawValue) })
        XCTAssertFalse(broker.offer(first) { _ in XCTFail("duplicate must not replace a pending hook") })
        XCTAssertTrue(broker.resolve(second.id, as: .deny))
        XCTAssertEqual(replies, ["two:deny"])
        XCTAssertFalse(broker.resolve(second.id, as: .allow))
        XCTAssertTrue(broker.resolve(first.id, as: .allow))
        XCTAssertEqual(replies, ["two:deny", "one:allow"])
    }

    func testAnExpiredRequestCannotBeApproved() {
        let now = Date(), request = approval(now: Date().addingTimeInterval(-121)), broker = PermissionBroker()
        var reply: ApprovalResolution?
        XCTAssertTrue(broker.offer(request) { reply = $0 })
        XCTAssertFalse(broker.resolve(request.id, as: .allow, now: now))
        XCTAssertEqual(reply, .expired)
    }

    func testDisconnectAndShutdownNeverApprove() {
        let broker = PermissionBroker(), first = approval(), second = approval("two")
        var replies: [ApprovalResolution] = []
        _ = broker.offer(first) { replies.append($0) }
        _ = broker.offer(second) { replies.append($0) }
        XCTAssertTrue(broker.resolve(first.id, as: .disconnected))
        broker.cancelAll()
        XCTAssertEqual(replies, [.disconnected, .disconnected])
        XCTAssertFalse(broker.resolve(second.id, as: .allow))
    }

    func testQuestionsAndInvalidRequestsCannotAcquireApprovalButtons() {
        let base: [String: Any] = ["request_id": UUID().uuidString, "session_id": "one", "host": "test",
                                   "tool_name": "Bash", "tool_input": ["command": "echo demo"]]
        for changes: [String: Any] in [
            ["request_id": "not-an-id"], ["session_id": ""], ["host": ""],
            ["tool_name": "AskUserQuestion"], ["tool_name": "ExitPlanMode"],
            ["tool_input": ["command": String(repeating: "x", count: 40_000)]]
        ] {
            XCTAssertNil(ApprovalRequest(json: base.merging(changes) { _, newer in newer }))
        }
    }

    func testTheCardRetainsEveryToolParameter() {
        let request = approval()
        XCTAssertTrue(request.event.prompt!.detail.contains("printf 'demo'"))
        XCTAssertTrue(request.event.prompt!.detail.contains("timeout"))
        XCTAssertTrue(request.event.prompt!.detail.contains("1000"))
        XCTAssertEqual(request.event.prompt!.id, request.id)
    }

    func testRetryingAClientNonceCannotReuseAnOldCardsActionIdentity() {
        let nonce = UUID().uuidString
        let first = approval(id: nonce), second = approval(id: nonce)
        XCTAssertEqual(first.clientID, second.clientID)
        XCTAssertNotEqual(first.id, second.id)
    }
}

@MainActor
final class DecisionNotificationTests: XCTestCase {
    private func state() -> AppState {
        let state = AppState()
        state.muted = false
        state.sounds = false
        state.systemNotifications = false
        return state
    }

    private func visibleID(_ state: AppState) -> String? {
        if case .peek(.event(let event)) = state.hudState { return event.prompt?.id }
        return nil
    }

    func testAnotherSessionQueuesWithoutMovingTheCurrentButtons() {
        let state = state(), first = approval(), second = approval("two")
        state.receiveApproval(first)
        state.receiveApproval(second)
        XCTAssertEqual(visibleID(state), first.id)
        XCTAssertEqual(state.queuedAgentNotifications.map { $0.prompt!.id }, [second.id])
        XCTAssertEqual(state.decisionEvents.count, 2)
        XCTAssertTrue(state.canAnswerApproval(first.id))
        XCTAssertTrue(state.canAnswerApproval(second.id))
    }

    func testCardDismissalDoesNotAnswerAndAdvancesTheQueue() async {
        let state = state(), first = approval(), second = approval("two")
        state.approvalResponder = { _, _ in XCTFail("dismissal must not answer"); return false }
        state.receiveApproval(first)
        state.receiveApproval(second)
        state.dismissNotification()
        XCTAssertTrue(state.hudState.isCollapsed)
        XCTAssertEqual(state.decisionEvents.count, 2)
        try? await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(visibleID(state), second.id)
        state.showDecision(first.id)
        XCTAssertEqual(visibleID(state), first.id, "a dismissed request remains reviewable")
    }

    func testOnlyTheClickedRequestIsAnsweredAndDoubleClicksDoNothing() {
        let state = state(), first = approval(), second = approval("two")
        var calls: [String] = []
        state.approvalResponder = { id, choice in calls.append(id + ":" + choice.rawValue); return true }
        state.receiveApproval(first)
        state.receiveApproval(second)
        state.answerApproval(first.id, as: .deny)
        state.answerApproval(first.id, as: .allow)
        XCTAssertEqual(calls, [first.id + ":deny"])
        XCTAssertTrue(state.canAnswerApproval(second.id))
        XCTAssertFalse(state.canAnswerApproval(first.id))
    }

    func testReplyMovesOnlyTheAnsweredSessionBackToWork() {
        let state = state(), first = approval(), second = approval("two")
        state.receiveApproval(first)
        state.receiveApproval(second)
        state.finishApproval(first.id, as: .allow)
        XCTAssertEqual(state.sessions.first(where: { $0.id == first.event.sourceKey })?.kind, .running)
        XCTAssertEqual(state.sessions.first(where: { $0.id == second.event.sourceKey })?.kind, .attention)
    }

    func testAnsweringAQuestionDoesNotCancelAParallelPermissionInThatSession() {
        let state = state(), request = approval()
        state.receiveApproval(request)
        state.apply(AgentEvent.from(json: ["event": "attention", "host": "test", "app": "claude", "session_id": "one",
            "hook": "PreToolUse", "prompt": ["id": "question", "kind": "question", "title": "Choose",
                                               "detail": "Which option?"]])!)
        state.approvalResponder = { _, _ in XCTFail("answering a question must not resolve another permission"); return false }
        state.apply(AgentEvent.from(json: ["event": "running", "host": "test", "app": "claude", "session_id": "one",
            "hook": "PostToolUse", "resolved_prompt_id": "question"])!)
        XCTAssertTrue(state.canAnswerApproval(request.id))
        XCTAssertEqual(state.decisionEvents.count, 1)
        XCTAssertEqual(state.sessions.first?.kind, .attention)
    }

    func testAPlainEventCannotCreateAnApprovalCapability() {
        let state = state(), request = approval()
        state.apply(request.event)
        XCTAssertFalse(state.canAnswerApproval(request.id))
        state.approvalResponder = { _, _ in XCTFail("unconnected event cannot approve"); return true }
        state.answerApproval(request.id, as: .allow)
    }

    func testDisconnectRemovesButtonsAndAStaleClickDoesNothing() {
        let state = state(), request = approval()
        state.receiveApproval(request)
        state.finishApproval(request.id, as: .disconnected)
        XCTAssertFalse(state.canAnswerApproval(request.id))
        XCTAssertTrue(state.decisionEvents.isEmpty)
        XCTAssertEqual(state.decisionResults[request.id], "Request is no longer connected")
        state.approvalResponder = { _, _ in XCTFail("stale click"); return true }
        state.answerApproval(request.id, as: .allow)
    }

    func testDelayedClaudeNotificationDoesNotReopenADismissedRequest() {
        let state = state(), request = approval()
        state.receiveApproval(request)
        state.dismissNotification()
        state.apply(AgentEvent.from(json: ["event": "attention", "app": "claude", "host": "test",
                                           "session_id": "one", "hook": "Notification", "message": "Needs permission"])!)
        XCTAssertTrue(state.hudState.isCollapsed)
        XCTAssertTrue(state.queuedAgentNotifications.isEmpty)
        XCTAssertEqual(state.decisionEvents.count, 1)
    }

    func testRegistryCannotFinishARequestThatIsStillWaiting() {
        let state = state(), request = approval()
        state.receiveApproval(request)
        state.syncRegistry(host: "test", entries: [LocalSessionEntry(sessionId: "one", name: "one", cwd: "/tmp",
            status: "idle", updatedAt: Date().timeIntervalSince1970 * 1000, outcome: "finished", app: "claude")])
        XCTAssertEqual(state.sessions.first?.kind, .attention)
        XCTAssertTrue(state.canAnswerApproval(request.id))
    }

    func testGoToSessionReleasesOnlyItsHookWithoutGrantingPermission() {
        let state = state(), first = approval(), second = approval("two")
        var choices: [String] = [], destinations: [String] = []
        state.approvalResponder = { id, choice in choices.append(id + ":" + choice.rawValue); return true }
        state.sessionOpener = { _, _, _, completion in
            destinations.append(state.selectedSessionId ?? "")
            completion(nil)
        }
        state.receiveApproval(first)
        state.receiveApproval(second)
        state.focusSession(state.sessions.first(where: { $0.id == second.event.sourceKey })!)
        XCTAssertEqual(choices, [second.id + ":session"])
        XCTAssertEqual(destinations, [second.event.sourceKey])
        XCTAssertTrue(state.hudState.isCollapsed)
    }

    func testAnAnswerInClaudeClearsOnlyThatSessionsQuestion() {
        let state = state()
        for sid in ["one", "two"] {
            state.apply(AgentEvent.from(json: ["event": "attention", "app": "claude", "host": "test", "session_id": sid,
                "hook": "PreToolUse", "prompt": ["id": sid, "kind": "question", "title": "Choose a database",
                "detail": "Postgres or SQLite?"]])!)
        }
        state.apply(AgentEvent.from(json: ["event": "running", "app": "claude", "host": "test", "session_id": "one",
                                           "hook": "PostToolUse"])!)
        XCTAssertEqual(state.decisionEvents.map { $0.sessionId }, ["two"])
    }

    func testMusicCannotReplaceAnApprovalCard() {
        let state = state(), request = approval()
        state.receiveApproval(request)
        state.setWebNowPlaying(NowPlaying(app: "YouTube", title: "Demo music", artist: "Demo", playing: true, artworkURL: ""))
        XCTAssertEqual(visibleID(state), request.id)
    }

    func testHoverCannotMoveApprovalButtonsByOpeningTheFullPanel() {
        let state = state(), request = approval()
        state.hoverExpandsPeek = true
        defer { state.hoverExpandsPeek = false }
        state.receiveApproval(request)
        state.hoverChanged(true)
        XCTAssertEqual(visibleID(state), request.id)
    }

    func testExplicitReviewStillWorksWhenNotificationsAreMuted() {
        let state = state(), request = approval()
        state.receiveApproval(request)
        state.muted = true
        state.showDecision(request.id)
        XCTAssertEqual(visibleID(state), request.id)
        state.muted = false
    }

    func testMovingFromTheExpandedPanelToARequestDoesNotImmediatelyCollapseIt() async {
        let state = state(), request = approval()
        state.receiveApproval(request)
        state.hoverCollapseDelay = 0.01
        defer { state.hoverCollapseDelay = 0.4 }
        state.showDecision(request.id)
        state.hoverChanged(false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(visibleID(state), request.id)
    }

    func testRenderDecisionCards() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENT_HUD_SNAPSHOT_DIR"] else { return }
        let state = state(), request = approval("Notch polish")
        state.receiveApproval(request)
        state.receiveApproval(approval("Other session"))
        let question = AgentEvent.from(json: ["event": "attention", "host": "Demo", "app": "claude",
            "session_id": "questions", "session_name": "Project setup", "prompt": ["id": "questions",
            "kind": "question", "title": "Claude has two questions", "detail":
            "1. Which database should this project use?\n  • Postgres\n  • SQLite\n  • MySQL\n  • Redis\n  • Something else\n\n2. Where should it run?\n  • Locally\n  • On the server"]])!
        for (name, event) in [("permission", request.event), ("questions", question)] {
            // ImageRenderer omits AppKit-backed selectable text/scroll views.
            // Capture the actual native hosting view instead.
            let hosting = NSHostingView(rootView: DecisionNotificationView(state: state, event: event)
                .frame(width: 520, height: 244, alignment: .top).background(.black))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 244),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 244)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            window.close()
        }
    }
}
