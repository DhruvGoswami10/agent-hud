import Foundation
import SwiftUI
import CryptoKit
import Security

/// One line from the Mac's GET /watch.
struct WatchSession: Decodable, Identifiable, Hashable {
    let id: String
    let outcome: String
    let name: String
    let host: String
    let kind: String
    let app: String
    var model: String = ""
    let message: String
    let ago: Int
    var ctx: Int = 0
    var files: Int = 0
    var added: Int = 0
    var removed: Int = 0
    var tokens: Int = 0
    var turns: Int = 0


    var color: Color {
        switch kind {
        case "running":   return Color(red: 0.35, green: 0.65, blue: 1.0)
        case "attention": return Color(red: 1.0, green: 0.62, blue: 0.2)
        case "done":
            if outcome == "error" { return .red }
            if outcome == "interrupted" { return .orange }
            return outcome == "finished" ? Color(red: 0.4, green: 0.85, blue: 0.5) : .gray
        default:          return .gray
        }
    }

    /// Elapsed, as a wrist wants it: m:ss under an hour, then h:mm.
    func elapsed(plus offset: Int = 0) -> String {
        let t = ago + offset
        if t < 3600 { return String(format: "%d:%02d", t / 60, t % 60) }
        return String(format: "%dh%02d", t / 3600, (t % 3600) / 60)
    }

    /// How far into the current minute the run is — the dial's fill, so the
    /// marks sweep like a second hand and wrap on the minute.
    func minuteFraction(plus offset: Int = 0) -> Double {
        Double((ago + offset) % 60) / 60.0
    }

    /// 53,975,688 → "54.0M". A wrist has no room for grouping separators.
    var tokensShort: String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.0fk", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    var where_: String { host == "local" ? "this Mac" : host }

    var since: String {
        if ago < 60 { return "\(ago)s" }
        if ago < 3600 { return "\(ago / 60)m" }
        return "\(ago / 3600)h"
    }
}

struct WatchLimit: Decodable, Identifiable {
    let id: String
    let account: String
    let provider: String
    let label: String
    let percent: Double
    let plan: String
    let resets: String


    /// Amber past three-quarters, red when it's effectively gone — the whole
    /// point of putting this on a wrist is deciding whether to keep going.
    var color: Color {
        if percent >= 95 { return Color(red: 1, green: 0.42, blue: 0.35) }
        if percent >= 75 { return Color(red: 1, green: 0.76, blue: 0.35) }
        return Color(red: 0.35, green: 0.65, blue: 1.0)
    }
}

struct Wrapped: Decodable {
    var day = 0, week = 0, peakTokens = 0
    var peakHour = ""
    var files = 0, added = 0, removed = 0, turns = 0, hosts = 0

    static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

struct WatchSnapshot: Decodable {
    var wrapped = Wrapped()
    var running = 0
    var attention = 0
    var awake = false
    var awakeReason = ""
    var sessions: [WatchSession] = []
    var limits: [WatchLimit] = []

    /// What the face should be doing: attention outranks work, work outranks rest.
    var mood: Mood {
        if attention > 0 { return .needsYou }
        if running > 0 { return .working }
        return .resting
    }

    /// The one that deserves the whole screen: anything wanting you first,
    /// then whatever is actually working, then the most recent thing.
    var focus: WatchSession? {
        sessions.first { $0.kind == "attention" }
            ?? sessions.first { $0.kind == "running" }
            ?? sessions.first
    }

    var headline: String {
        if attention > 0 { return "\(attention) need\(attention == 1 ? "s" : "") you" }
        if running > 0 { return "\(running) working" }
        return sessions.isEmpty ? "nothing running" : "all quiet"
    }
}

enum Mood {
    case working, needsYou, resting

    var color: Color {
        switch self {
        case .working:  return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .needsYou: return Color(red: 1.0, green: 0.76, blue: 0.35)
        case .resting:  return Color(red: 0.5, green: 0.62, blue: 0.79)
        }
    }
}

/// Foreground-only polling. TLS certificate and token are paired out of band.
@MainActor
final class Hub: ObservableObject {
    @Published private(set) var snap = WatchSnapshot()
    @Published private(set) var reachable = false
    @Published private(set) var sinceSync = 0
    @Published var pairingText = WatchPairingStore.load()
    @Published private(set) var connectionStatus = "Pair your Mac"
    private var timer: Timer?
    private var second: Timer?
    private var request: URLSessionDataTask?
    private var session: URLSession?
    private var started = false
    private var config: WatchConnection?
    private var generation = 0

    func pair() {
        guard let parsed = WatchConnection(pairingText) else {
            connectionStatus = "Paste the complete pairing link from the Mac"
            return
        }
        generation += 1
        config = parsed
        WatchPairingStore.save(pairingText)
        session?.invalidateAndCancel()
        request = nil
        session = URLSession(configuration: .ephemeral, delegate: PinnedMac(connection: parsed), delegateQueue: nil)
        started = false
        tick()
    }

    func start() {
        guard timer == nil else { return }
        if config == nil { pair() }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        second = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sinceSync += 1 }
        }
    }

    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        second?.invalidate(); second = nil
        request?.cancel(); request = nil
        started = false
    }

    private func announce(previous: WatchSnapshot, next: WatchSnapshot) {
        guard started else { return }
        let was = Dictionary(previous.sessions.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        for s in next.sessions where was[s.id] != s.kind {
            switch s.kind {
            case "attention": Haptics.needsYou()
            case "done" where was[s.id] == "running":
                if s.outcome == "finished" { Haptics.done() }
                else if s.outcome == "error" { Haptics.failed() }
            case "running": if was[s.id] != nil { Haptics.started() }
            default: break
            }
        }
    }

    func tick() {
        guard request == nil, let config, let session else { return }
        let currentGeneration = generation
        var req = URLRequest(url: config.endpoint)
        req.timeoutInterval = 4
        req.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        request = session.dataTask(with: req) { [weak self] data, response, _ in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.request = nil
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                      let next = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else {
                    self.reachable = false
                    self.connectionStatus = "Mac unavailable · check Wi-Fi and pairing"
                    return
                }
                self.announce(previous: self.snap, next: next)
                self.snap = next; self.sinceSync = 0; self.reachable = true
                self.connectionStatus = "Connected securely"
                self.started = true
            }
        }
        request?.resume()
    }
}

struct WatchConnection: Sendable {
    let endpoint: URL
    let token: String
    let pin: String
    init?(_ link: String) {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "agenthud", components.host == "pair" else { return nil }
        let fields = Dictionary((components.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } },
                                uniquingKeysWith: { _, last in last })
        guard let host = fields["host"], Self.isLocalAddress(host),
              let port = fields["port"].flatMap(Int.init), (1...65535).contains(port),
              let token = fields["token"], let pin = fields["pin"],
              [token, pin].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else { return nil }
        var url = URLComponents(); url.scheme = "https"; url.host = host; url.port = port; url.path = "/watch"
        guard let endpoint = url.url else { return nil }
        self.endpoint = endpoint; self.token = token; self.pin = pin
    }

    static func isLocalAddress(_ host: String) -> Bool {
        if host.hasSuffix(".local"), host.range(of: "^[A-Za-z0-9-]+\\.local$", options: .regularExpression) != nil { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ $0.range(of: "^[0-9]{1,3}$", options: .regularExpression) != nil }) else { return false }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return false }
        return numbers[0] == 10 || numbers[0] == 127 || (numbers[0] == 192 && numbers[1] == 168)
            || (numbers[0] == 172 && (16...31).contains(numbers[1])) || (numbers[0] == 169 && numbers[1] == 254)
    }
}

/// The exact paired certificate is the trust anchor. Also validate its
/// signature and expiry; a matching fingerprint never means "accept anything".
final class PinnedMac: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let connection: WatchConnection
    init(connection: WatchConnection) { self.connection = connection }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == connection.endpoint.host,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let data = SecCertificateCopyData(certificate) as Data
        let pin = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard pin == connection.pin else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        // The paired fingerprint supplies identity across DHCP/mDNS changes.
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // never forward the token to another host
    }
}

/// Pairing tokens stay in the device keychain, not preferences or synced data.
enum WatchPairingStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "AgentHUDWatch", kSecAttrAccount as String: "paired-mac"]
    static func load() -> String {
        #if targetEnvironment(simulator)
        // Deterministic simulator QA without a phone keyboard or real tokens.
        if let supplied = UserDefaults.standard.string(forKey: "hudPairingURL") { return supplied }
        #endif
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ value: String) {
        SecItemDelete(query as CFDictionary)
        var q = query; q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
