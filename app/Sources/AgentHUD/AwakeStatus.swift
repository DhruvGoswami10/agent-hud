import Foundation

enum AwakeMode: String, CaseIterable {
    case off, auto, manual

    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .off: return "moon"
        case .auto: return "bolt"
        case .manual: return "cup.and.saucer"
        }
    }
}

/// One description for the badge, controls and Settings. A selected mode
/// expresses intent; only a live assertion can earn the "Active" label.
struct AwakeStatus {
    let mode: AwakeMode
    let requested: Caffeine.Mode
    let assertionAlive: Bool
    let remaining: TimeInterval?
    let running: Int
    let attention: Int
    let graceRemaining: TimeInterval
    let idleResetAllowed: Bool

    var active: Bool { requested != .off && assertionAlive }
    var failed: Bool { requested != .off && !assertionAlive }
    var displayOn: Bool { active && requested == .display }
    var status: String { failed ? "Not active" : active ? "Active" : mode == .auto ? "Ready" : "Off" }
    var title: String {
        if failed { return "Couldn’t keep Mac awake" }
        if active { return displayOn ? "Screen stays on" : "Mac stays awake" }
        return mode == .auto ? "Ready for agents" : "Sleep allowed"
    }
    var detail: String {
        if failed { return "Sleep prevention is unavailable · Retrying" }
        switch mode {
        case .off: return "Agent HUD is not preventing sleep"
        case .manual:
            guard let remaining else { return "Until you stop it" }
            return remaining > 0 ? "\(Self.clock(remaining)) remaining" : "Ending hold…"
        case .auto:
            if attention > 0 { return attention == 1 ? "An agent needs your attention" : "\(attention) agents need your attention" }
            if running > 0 { return running == 1 ? "An agent is working" : "\(running) agents are working" }
            if active, graceRemaining > 0 { return "\(Self.clock(graceRemaining)) until sleep is allowed" }
            return "No active hold · Sleep is allowed"
        }
    }
    var badgeTitle: String {
        if failed { return "Hold unavailable" }
        return active ? (displayOn ? "Screen on" : "Mac awake") : "Sleep allowed"
    }
    var badgeDetail: String {
        if failed { return "\(mode.label) · Retrying" }
        switch mode {
        case .off: return "Keep Awake · Off"
        case .manual:
            return "Manual · " + (remaining.map { $0 > 0 ? Self.minutesLeft($0) : "Ending…" } ?? "Until stopped")
        case .auto:
            if attention > 0 { return "Auto · Needs you" }
            if running > 0 { return "Auto · Agents working" }
            return "Auto · " + (active && graceRemaining > 0 ? Self.minutesLeft(graceRemaining) : "Ready")
        }
    }
    var badgeSymbol: String {
        failed ? "exclamationmark.triangle" : mode == .manual && remaining != nil ? "timer" : mode.symbol
    }
    var symbol: String {
        if failed { return "exclamationmark.triangle" }
        if !active { return "moon" }
        if mode == .auto { return running == 0 && attention == 0 ? "timer" : "bolt" }
        return displayOn ? "display" : "laptopcomputer"
    }
    var lockDescription: String {
        displayOn && idleResetAllowed ? "Idle-lock prevention enabled." : "Auto-lock follows macOS settings."
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func minutesLeft(_ seconds: TimeInterval) -> String {
        "\(max(1, Int(ceil(seconds / 60)))) min left"
    }
}
