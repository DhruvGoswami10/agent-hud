import XCTest
@testable import AgentHUD

final class PermissionTransportTests: XCTestCase {
    private func server() async throws -> EventServer {
        let ready = expectation(description: "loopback listener ready")
        let server = EventServer(port: 0, onEvent: { _ in }, onSessions: { _ in }, onMusicState: { _ in })
        server.browserToken = "test-bridge-token"
        server.onStatus = { status in if status.hasPrefix("listening") { ready.fulfill() } }
        try server.start()
        await fulfillment(of: [ready], timeout: 3)
        return server
    }

    private func request(_ server: EventServer, path: String = "/approval") throws -> URLRequest {
        let port = try XCTUnwrap(server.listeningPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": "98FBE66D-D22D-4FF7-A66B-A93A62397E72", "session_id": "demo", "host": "test",
            "tool_name": "Bash", "tool_input": ["command": "printf 'synthetic test'"]
        ])
        return request
    }

    func testTheWaitingHookReceivesOnlyItsExplicitDecision() async throws {
        let server = try await server()
        defer { server.stop() }
        server.onApproval = { request in
            XCTAssertNotEqual(request.id, request.clientID)
            XCTAssertTrue(server.permissions.resolve(request.id, as: .deny))
        }
        let (data, response) = try await URLSession.shared.data(for: request(server))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(reply["request_id"], "98FBE66D-D22D-4FF7-A66B-A93A62397E72")
        XCTAssertEqual(reply["decision"], "deny")
    }

    func testEvenAPairedExtensionCannotCreateApprovalRequests() async throws {
        let server = try await server()
        defer { server.stop() }
        server.onApproval = { _ in XCTFail("browser must not create native permission requests") }
        var request = try request(server)
        request.setValue("chrome-extension://test", forHTTPHeaderField: "Origin")
        request.setValue("test-bridge-token", forHTTPHeaderField: "X-Agent-HUD-Token")
        request.setValue("browser", forHTTPHeaderField: "X-Agent-HUD-Client")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    }

    func testThereIsNoHTTPApproveEndpoint() async throws {
        let server = try await server()
        defer { server.stop() }
        let (_, response) = try await URLSession.shared.data(for: request(server, path: "/approval/resolve"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testClosingTheHookConnectionRevokesTheRequest() async throws {
        let server = try await server()
        defer { server.stop() }
        let offered = expectation(description: "request offered"), revoked = expectation(description: "request revoked")
        server.onApproval = { _ in offered.fulfill() }
        server.onApprovalEnded = { _, resolution in
            XCTAssertEqual(resolution, .disconnected)
            revoked.fulfill()
        }
        let request = try request(server)
        let task = Task { try await URLSession.shared.data(for: request) }
        await fulfillment(of: [offered], timeout: 3)
        task.cancel()
        _ = try? await task.value
        await fulfillment(of: [revoked], timeout: 3)
    }
}
