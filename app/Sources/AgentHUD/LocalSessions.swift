import Foundation

/// One row of Claude Code's live session registry (~/.claude/sessions/<pid>.json),
/// as reported to POST /sessions by bin/agent-hud-registry — the same reporter
/// runs locally (spawned by the app) and on remote boxes (through the tunnel).
struct LocalSessionEntry {
    let sessionId: String
    let name: String
    let cwd: String
    let status: String
    let updatedAt: Double
    var model: String = ""
    var effort: String = ""
    var ctxUsed: Int = 0
    var lastIn: Int = 0
    var lastOut: Int = 0
    var outcome: String = ""

    var isActive: Bool { status == "busy" || status == "shell" }
}

/// One real rate-limit window as Anthropic reports it (session / weekly /
/// per-model). Percentages are truth, not our token estimates.
struct LimitItem: Identifiable {
    var id: String { kind + label }
    let kind: String
    let label: String
    let percent: Double
    let severity: String
    let resetsAt: Date?

    var isCritical: Bool { severity == "critical" || percent >= 95 }
    var isWarning: Bool { severity == "warning" || (percent >= 75 && !isCritical) }
}

struct AccountLimits: Identifiable {
    let key: String           // account uuid (or email) — one card per account
    let source: String        // api | ccstatusline | claude.json
    let fetchedAt: Date
    let accountName: String
    let plan: String
    let items: [LimitItem]
    /// Machines currently logged into this account; filled in by AppState.
    var hosts: Set<String> = []

    var id: String { key }
    var isLive: Bool { Date().timeIntervalSince(fetchedAt) < 1800 }

    static func from(json: [String: Any]) -> AccountLimits? {
        guard let raw = json["items"] as? [[String: Any]], !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let account = (json["account"] as? [String: Any]) ?? [:]
        let items = raw.compactMap { r -> LimitItem? in
            guard let label = r["label"] as? String,
                  let percent = r["percent"] as? Double else { return nil }
            let resets = (r["resets_at"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            return LimitItem(kind: (r["kind"] as? String) ?? label,
                             label: label, percent: percent,
                             severity: (r["severity"] as? String) ?? "normal",
                             resetsAt: resets)
        }
        guard !items.isEmpty else { return nil }
        let key = (account["uuid"] as? String)
            ?? (account["email"] as? String)
            ?? (account["name"] as? String) ?? "default"
        return AccountLimits(
            key: key,
            source: (json["source"] as? String) ?? "unknown",
            fetchedAt: Date(timeIntervalSince1970: (json["fetched_at"] as? Double) ?? 0),
            accountName: (account["name"] as? String) ?? "",
            plan: (account["plan"] as? String) ?? "",
            items: items)
    }
}

/// Everything one machine's reporter sends in a single POST /sessions.
struct RegistryReport {
    let host: String
    let entries: [LocalSessionEntry]
    var usage: [String: Int] = [:]
    var hours: [Int: Int] = [:]
    var limits: AccountLimits?
}
