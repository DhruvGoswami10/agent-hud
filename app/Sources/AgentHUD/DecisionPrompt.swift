import Foundation

/// Display data only. Receiving a prompt through /event never grants an action.
struct DecisionPrompt: Equatable {
    let id: String
    let kind: String
    let title: String
    let detail: String

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, id.count <= 256,
              let kind = json["kind"] as? String,
              ["permission", "question", "plan", "input"].contains(kind),
              let title = json["title"] as? String, !title.isEmpty, title.count <= 200,
              let detail = json["detail"] as? String, detail.utf8.count <= 65_536 else { return nil }
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
    }
}

struct ApprovalRequest {
    static let lifetime: TimeInterval = 120
    let id: String
    let event: AgentEvent
    let deadline: Date
    let clientID: String

    init?(json: [String: Any], now: Date = Date()) {
        guard let clientID = json["request_id"] as? String, UUID(uuidString: clientID) != nil,
              let sid = json["session_id"] as? String, !sid.isEmpty, sid.count <= 256,
              let host = json["host"] as? String, !host.isEmpty, host.count <= 255,
              let tool = json["tool_name"] as? String, !tool.isEmpty, tool.count <= 160,
              tool.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil,
              !["AskUserQuestion", "ExitPlanMode"].contains(tool),
              let input = json["tool_input"] as? [String: Any],
              JSONSerialization.isValidJSONObject(input),
              let bytes = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              bytes.count <= 32_768 else { return nil }
        // All parameters remain visible, including flags beyond a shell command.
        var detail = String(decoding: bytes, as: UTF8.self)
        if ["Bash", "PowerShell"].contains(tool), let command = input["command"] as? String {
            var rest = input
            rest.removeValue(forKey: "command")
            detail = command
            if !rest.isEmpty, let other = try? JSONSerialization.data(withJSONObject: rest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                detail += "\n\n" + String(decoding: other, as: UTF8.self)
            }
        }
        // A client cannot reuse an old notification's action identity. This
        // native-only ID is fresh even when a caller retries its own nonce.
        let id = UUID().uuidString
        var obj = json
        obj["event"] = "attention"
        obj["app"] = "claude"
        obj["hook"] = "PermissionRequest"
        obj["event_id"] = "permission:" + id
        obj["message"] = "Allow " + tool + "?"
        obj["prompt"] = ["id": id, "kind": "permission", "title": "Allow " + tool + "?", "detail": detail]
        guard let event = AgentEvent.from(json: obj), event.prompt != nil else { return nil }
        self.id = id
        self.clientID = clientID
        self.event = event
        deadline = now.addingTimeInterval(Self.lifetime)
    }
}

enum ApprovalResolution: String {
    case allow, deny, session, expired, disconnected

    var label: String {
        switch self {
        case .allow: return "Approval sent"
        case .deny: return "Rejection sent"
        case .session: return "Continue in the session"
        case .expired: return "Answer in the session"
        case .disconnected: return "Request is no longer connected"
        }
    }
}

/// A reply goes only to the exact waiting hook connection. There is deliberately
/// no HTTP endpoint that can approve a request; only the native UI can resolve it.
final class PermissionBroker {
    private let lock = NSLock()
    private struct Entry {
        let request: ApprovalRequest
        let finish: (ApprovalResolution) -> Void
    }
    private var entries: [String: Entry] = [:]

    func offer(_ request: ApprovalRequest, finish: @escaping (ApprovalResolution) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[request.id] == nil, entries.count < 32 else { return false }
        entries[request.id] = Entry(request: request, finish: finish)
        return true
    }

    @discardableResult
    func resolve(_ id: String, as choice: ApprovalResolution, now: Date = Date()) -> Bool {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return false }
        let actual: ApprovalResolution = now >= entry.request.deadline ? .expired : choice
        entry.finish(actual)
        return actual == choice
    }

    func cancelAll() {
        lock.lock()
        let old = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        old.forEach { $0.finish(.disconnected) }
    }
}
