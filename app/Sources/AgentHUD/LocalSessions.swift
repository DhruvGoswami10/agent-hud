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
    var filesChanged: Int = 0
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    var topFile: String = ""
    var app: String = ""
    var totalTokens: Int = 0
    var turns: Int = 0

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
    let source: String        // api | ccstatusline | claude.json | codex-rollout
    let fetchedAt: Date
    let accountName: String
    let plan: String
    let items: [LimitItem]
    /// Which assistant these limits belong to: one machine can be logged into
    /// Claude and Codex at once, and each gets its own card.
    var provider: Provider = .claude
    /// How long this reading stays on the HUD. Claude's is re-fetched from the
    /// API every few minutes, so an hour is generous; Codex only publishes
    /// numbers when a turn runs, so its reading is allowed to sit for the day.
    var retention: TimeInterval = 3600
    /// Machines currently logged into this account; filled in by AppState.
    var hosts: Set<String> = []

    var id: String { key }
    var isLive: Bool { Date().timeIntervalSince(fetchedAt) < 1800 }
    /// True when the numbers were read off a transcript rather than fetched:
    /// they are as new as the last turn, so "stale" is their resting state
    /// and would be a warning about nothing.
    var isSnapshot: Bool { source == "codex-rollout" }

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
            items: items,
            // Absent on reports from an older reporter — those are Claude's.
            provider: Provider(rawValue: (json["provider"] as? String) ?? "") ?? .claude,
            retention: (json["retention_seconds"] as? Double) ?? 3600)
    }
}

/// Everything one machine's reporter sends in a single POST /sessions.
struct RegistryReport {
    let host: String
    let entries: [LocalSessionEntry]
    var usage: [String: Int] = [:]
    var hours: [Int: Int] = [:]
    /// One entry per assistant the machine is logged into (Claude, Codex …).
    var limits: [AccountLimits] = []
}
