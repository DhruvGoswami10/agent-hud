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
