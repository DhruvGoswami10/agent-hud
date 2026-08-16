import Foundation
import Network

/// Minimal loopback HTTP server: POST /event (JSON body) and GET /health.
/// Remote machines reach it through an SSH reverse tunnel, so loopback-only
/// binding covers both local and remote agents.
/// Thread-safe queue for music commands destined for browser tabs, which
/// poll GET /music/commands since the HUD can't reach into a web page.
final class CommandQueue {
    private let lock = NSLock()
    private var items: [(tab: String, cmd: String)] = []
    private var history: [String] = []

    /// Fires after every push with the target tab — the server uses it to
    /// answer a parked long-poll immediately instead of waiting to be asked.
    var onPush: ((String) -> Void)?

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func note(_ s: String) {
        history.append("\(Self.clock.string(from: Date())) \(s)")
        if history.count > 20 { history.removeFirst(history.count - 20) }
    }

    func push(_ c: String, tab: String = "") {
        lock.lock()
        items.append((tab, c))
        if items.count > 8 { items.removeFirst(items.count - 8) }
        note("push \(c) → \(tab.isEmpty ? "legacy" : tab)")
        lock.unlock()
        onPush?(tab)
    }

    /// Commands are addressed: a tab drains only its own (tab "" is the
    /// legacy untargeted lane), so with several players open one tab can't
    /// steal another's button press — the old popAll() did exactly that.
    func pop(for tab: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let mine = items.filter { $0.tab == tab }.map(\.cmd)
        items.removeAll { $0.tab == tab }
        if !mine.isEmpty { note("pop \(tab.isEmpty ? "legacy" : tab) ← \(mine.joined(separator: ","))") }
        return mine
    }

    /// Every push/pop with timestamps — the forensics for "who paused my
    /// music": if nothing is here, the HUD didn't send it.
    func recentActivity() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }
}

final class EventServer {
    private let port: UInt16
    private let onEvent: (AgentEvent) -> Void
    private let onSessions: (RegistryReport) -> Void
    private let onMusicState: (NowPlaying) -> Void
    private let onDebug: () -> String
    /// Optional: POST /music/commands → (command, explicit tab or nil).
    var onMusicCommand: ((String, String?) -> Void)?
    let musicCommands = CommandQueue()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agenthud.server")
    /// Long-polls waiting for a command (server-queue confined). Answered the
    /// instant a command is pushed — click-to-audio without the poll gap.
    private var parked: [(tab: String, conn: NWConnection, timeout: DispatchWorkItem)] = []
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
        musicCommands.onPush = { [weak self] tab in
            guard let self else { return }
            self.queue.async { self.deliverParked(tab) }
        }
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
        musicCommands.onPush = nil
        // Answer anyone still parked rather than leaving their request to
        // die on the wire — tabs treat a dropped poll as the HUD going away.
        queue.async { [weak self] in
            guard let self else { return }
            for p in self.parked {
                p.timeout.cancel()
                self.respondCommands(p.conn, [])
            }
            self.parked.removeAll()
        }
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
        // The switch matches bare paths; a query string must not 404 them.
        let (path, query) = Self.splitTarget(req.path)
        switch (req.method, path) {
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
                artworkURL: (obj["artwork_url"] as? String) ?? "",
                tab: (obj["tab"] as? String) ?? ""
            ))
            respond(conn, status: "200 OK", body: #"{"ok":true}"#)
        case ("GET", "/music/commands"):
            let tab = Self.queryValue(query, "tab") ?? ""
            let cmds = musicCommands.pop(for: tab)
            // wait=1 opts into long-polling: an empty answer parks until a
            // command lands or ~20s passes. Legacy clients keep instant
            // empties, exactly as before.
            if !cmds.isEmpty || Self.queryValue(query, "wait") == nil {
                respondCommands(conn, cmds)
            } else {
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.parked.removeAll { $0.conn === conn }
                    self.respondCommands(conn, [])
                }
                parked.append((tab, conn, timeout))
                if parked.count > 16 {  // runaway guard: oldest answers empty
                    let old = parked.removeFirst()
                    old.timeout.cancel()
                    respondCommands(old.conn, [])
                }
                queue.asyncAfter(deadline: .now() + 20, execute: timeout)
            }
        case ("POST", "/music/commands"):
            // Same path as clicking the bar's buttons — scriptable controls,
            // and the way to prove command delivery when debugging.
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let cmd = obj["command"] as? String, !cmd.isEmpty else {
                respond(conn, status: "400 Bad Request", body: #"{"ok":false}"#)
                return
            }
            onMusicCommand?(cmd, obj["tab"] as? String)
            respond(conn, status: "200 OK", body: #"{"ok":true}"#)
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
                    outcome: (j["outcome"] as? String) ?? "",
                    filesChanged: (j["files_changed"] as? Int) ?? 0,
                    linesAdded: (j["lines_added"] as? Int) ?? 0,
                    linesRemoved: (j["lines_removed"] as? Int) ?? 0,
                    topFile: (j["top_file"] as? String) ?? ""
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

    /// Answer every parked poll whose lane just received a command.
    private func deliverParked(_ tab: String) {
        var kept: [(tab: String, conn: NWConnection, timeout: DispatchWorkItem)] = []
        for p in parked {
            guard p.tab == tab else { kept.append(p); continue }
            let cmds = musicCommands.pop(for: p.tab)
            if cmds.isEmpty { kept.append(p); continue }
            p.timeout.cancel()
            respondCommands(p.conn, cmds)
        }
        parked = kept
    }

    private func respondCommands(_ conn: NWConnection, _ cmds: [String]) {
        let json = (try? JSONSerialization.data(withJSONObject: ["commands": cmds])) ?? Data("{\"commands\":[]}".utf8)
        respond(conn, status: "200 OK", body: String(decoding: json, as: UTF8.self))
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    static func splitTarget(_ target: String) -> (path: String, query: String) {
        guard let q = target.firstIndex(of: "?") else { return (target, "") }
        return (String(target[..<q]), String(target[target.index(after: q)...]))
    }

    static func queryValue(_ query: String, _ key: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == key { return String(kv[1]) }
        }
        return nil
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
