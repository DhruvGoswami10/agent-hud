import Foundation
import Network

/// Minimal loopback HTTP server: POST /event (JSON body) and GET /health.
/// Remote machines reach it through an SSH reverse tunnel, so loopback-only
/// binding covers both local and remote agents.
/// Thread-safe queue for music commands destined for browser tabs, which
/// poll GET /music/commands since the HUD can't reach into a web page.
final class CommandQueue {
    private let lock = NSLock()
    private var items: [String] = []

    func push(_ c: String) {
        lock.lock()
        items.append(c)
        if items.count > 8 { items.removeFirst(items.count - 8) }
        lock.unlock()
    }

    func popAll() -> [String] {
        lock.lock()
        defer { items.removeAll(); lock.unlock() }
        return items
    }
}

final class EventServer {
    private let port: UInt16
    private let onEvent: (AgentEvent) -> Void
    private let onSessions: (RegistryReport) -> Void
    private let onMusicState: (NowPlaying) -> Void
    private let onDebug: () -> String
    let musicCommands = CommandQueue()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agenthud.server")
    private let lock = NSLock()
    private var received = 0
    private var musicReceived = 0

    init(port: UInt16,
         onEvent: @escaping (AgentEvent) -> Void,
         onSessions: @escaping (RegistryReport) -> Void,
         onMusicState: @escaping (NowPlaying) -> Void,
         onDebug: @escaping () -> String = { "{}" }) {
        self.port = port
        self.onEvent = onEvent
        self.onSessions = onSessions
        self.onMusicState = onMusicState
        self.onDebug = onDebug
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
        NSLog("AgentHUD: listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parseRequest(buf) {
                self.route(conn, req)
            } else if isComplete || error != nil || buf.count > 8_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func route(_ conn: NWConnection, _ req: (method: String, path: String, body: Data)) {
        switch (req.method, req.path) {
        case ("OPTIONS", _):
            // CORS/Private-Network preflight for browser-extension content scripts.
            let head = "HTTP/1.1 204 No Content\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                + "Access-Control-Allow-Headers: Content-Type\r\n"
                + "Access-Control-Allow-Private-Network: true\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
        case ("POST", "/music/state"):
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let title = obj["title"] as? String, !title.isEmpty else {
                respond(conn, status: "400 Bad Request", body: #"{"ok":false}"#)
                return
            }
            lock.lock(); musicReceived += 1; lock.unlock()
            onMusicState(NowPlaying(
                app: (obj["source"] as? String) ?? "Web",
                title: title,
                artist: (obj["artist"] as? String) ?? "",
                playing: (obj["playing"] as? Bool) ?? false,
                artworkURL: (obj["artwork_url"] as? String) ?? ""
            ))
            respond(conn, status: "200 OK", body: #"{"ok":true}"#)
        case ("GET", "/music/commands"):
            let cmds = musicCommands.popAll()
            let json = (try? JSONSerialization.data(withJSONObject: ["commands": cmds])) ?? Data("{\"commands\":[]}".utf8)
            respond(conn, status: "200 OK", body: String(decoding: json, as: UTF8.self))
        case ("POST", "/event"):
            guard
                let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                let event = AgentEvent.from(json: obj)
            else {
                respond(conn, status: "400 Bad Request", body: #"{"ok":false,"error":"bad event json"}"#)
                return
            }
            lock.lock(); received += 1; let n = received; lock.unlock()
            onEvent(event)
            respond(conn, status: "200 OK", body: #"{"ok":true,"received":\#(n)}"#)
        case ("POST", "/sessions"):
            guard
                let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                let host = obj["host"] as? String,
                let arr = obj["sessions"] as? [[String: Any]]
            else {
                respond(conn, status: "400 Bad Request", body: #"{"ok":false,"error":"bad sessions json"}"#)
                return
            }
            let entries = arr.compactMap { j -> LocalSessionEntry? in
                guard let sid = j["sessionId"] as? String else { return nil }
                return LocalSessionEntry(
                    sessionId: sid,
                    name: (j["name"] as? String) ?? "",
                    cwd: (j["cwd"] as? String) ?? "",
                    status: (j["status"] as? String) ?? "",
                    updatedAt: (j["updatedAt"] as? Double) ?? 0,
                    model: (j["model"] as? String) ?? "",
                    effort: (j["effort"] as? String) ?? "",
                    ctxUsed: (j["ctx_used"] as? Int) ?? 0,
                    lastIn: (j["last_in"] as? Int) ?? 0,
                    lastOut: (j["last_out"] as? Int) ?? 0,
                    outcome: (j["outcome"] as? String) ?? ""
                )
            }
            let usageObj = (obj["usage"] as? [String: Any]) ?? [:]
            var usage: [String: Int] = [:]
            for key in ["h5", "d7", "h5_peak"] { usage[key] = (usageObj[key] as? Int) ?? 0 }
            var hours: [Int: Int] = [:]
            if let hs = usageObj["hours"] as? [String: Int] {
                for (k, v) in hs { if let hk = Int(k) { hours[hk] = v } }
            }
            let limits = (obj["limits"] as? [String: Any]).flatMap(AccountLimits.from(json:))
            onSessions(RegistryReport(host: host, entries: entries, usage: usage,
                                      hours: hours, limits: limits))
            respond(conn, status: "200 OK", body: #"{"ok":true,"sessions":\#(entries.count)}"#)
        case ("GET", "/debug"):
            respond(conn, status: "200 OK", body: onDebug())
        case ("GET", "/health"):
            lock.lock(); let n = received; let m = musicReceived; lock.unlock()
            respond(conn, status: "200 OK", body: #"{"ok":true,"received":\#(n),"music":\#(m)}"#)
        default:
            respond(conn, status: "404 Not Found", body: #"{"ok":false}"#)
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    static func parseRequest(_ data: Data) -> (method: String, path: String, body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return (String(parts[0]), String(parts[1]), Data(body.prefix(contentLength)))
    }
}
