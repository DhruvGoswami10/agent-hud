import AppKit

/// Checks whether a newer Agent HUD has been tagged, and says so. It does not
/// download or install anything.
///
/// That restraint is deliberate. The app runs out of the git clone it was
/// built from — the reporter, the hooks and the tunnel keeper all live in
/// `bin/` next to it — so the only coherent unit to update is the repo, not
/// the .app. Pulling and executing code on a timer is also exactly the kind
/// of thing that should never happen without you watching, and the bundle is
/// ad-hoc signed, so a silent in-place swap would quietly reset the
/// Accessibility and Automation grants the keep-awake feature depends on.
/// So: this tells you, `bin/agent-hud-update` does it while you watch.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Tag of the newest release, once known.
    @Published private(set) var latest: String?
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?

    static let releasesAPI = URL(string: "https://api.github.com/repos/DhruvGoswami10/agent-hud/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/DhruvGoswami10/agent-hud/releases/latest")!

    /// Stamped by `make bundle` from `git describe`; falls back to the plist.
    static var current: String {
        let info = Bundle.main.infoDictionary
        if let v = info?["AgentHUDVersion"] as? String, !v.isEmpty { return v }
        return (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.isNewer(latest, than: Self.current)
    }

    /// Compares dotted numeric versions, ignoring a leading "v" and any
    /// `-7-gabc123` suffix `git describe` adds for commits past the tag.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numericParts(candidate), b = numericParts(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func numericParts(_ s: String) -> [Int] {
        let core = s.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "v" || $0 == "V" })
            .prefix(while: { $0.isNumber || $0 == "." })
        return core.split(separator: ".").compactMap { Int($0) }
    }

    func check(force: Bool = false) {
        guard !checking else { return }
        // Once every six hours is plenty for a tool you build yourself.
        if !force, let last = lastChecked, Date().timeIntervalSince(last) < 6 * 3600 { return }
        checking = true
        lastError = nil
        var req = URLRequest(url: Self.releasesAPI)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("agent-hud", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            var tag: String?
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                failure = "no releases published yet"
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "GitHub returned \(http.statusCode)"
            } else if let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tag = obj["tag_name"] as? String
                if tag == nil { failure = "no tag in response" }
            } else {
                failure = "unreadable response"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let u = Updater.shared
                    u.checking = false
                    u.lastChecked = Date()
                    u.latest = tag ?? u.latest
                    u.lastError = failure
                }
            }
        }.resume()
    }

    func openReleasePage() { NSWorkspace.shared.open(Self.releasesPage) }
}
