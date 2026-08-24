import AppKit
import SwiftUI
import Combine
import SystemConfiguration

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var hudState: HUDState = .collapsed
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var clipboard: [ClipboardItem] = []
    @Published private(set) var pendingAttention = 0
    @Published private(set) var eventsReceived = 0

    @Published var systemNotifications: Bool { didSet { UserDefaults.standard.set(systemNotifications, forKey: "systemNotifications") } }
    @Published var sounds: Bool { didSet { UserDefaults.standard.set(sounds, forKey: "sounds") } }
    @Published var expandOnCopy: Bool { didSet { UserDefaults.standard.set(expandOnCopy, forKey: "expandOnCopy") } }
    @Published var sideBars: Bool {
        didSet {
            UserDefaults.standard.set(sideBars, forKey: "sideBars")
            refreshCollapsedFrame()
        }
    }
    @Published var musicEnabled: Bool { didSet { UserDefaults.standard.set(musicEnabled, forKey: "musicEnabled") } }
    @Published var animStyle: AnimStyle { didSet { UserDefaults.standard.set(animStyle.rawValue, forKey: "animStyle") } }
    @Published var keepAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "keepAwake")
            updateCaffeine()
        }
    }
    @Published var autoAwake: Bool {
        didSet {
            UserDefaults.standard.set(autoAwake, forKey: "autoAwake")
            updateCaffeine()
        }
    }
    @Published var muted: Bool { didSet { UserDefaults.standard.set(muted, forKey: "muted") } }

    // MARK: - Timing & behaviour preferences (Settings window)

    /// How long each kind of slide-out stays before retracting on its own.
    /// These were hard-coded; a peek that lands mid-thought needs to be
    /// short by preference, not by argument.
    @Published var attentionPeekSeconds: Double { didSet { UserDefaults.standard.set(attentionPeekSeconds, forKey: "attentionPeekSeconds") } }
    @Published var donePeekSeconds: Double { didSet { UserDefaults.standard.set(donePeekSeconds, forKey: "donePeekSeconds") } }
    @Published var clipboardPeekSeconds: Double { didSet { UserDefaults.standard.set(clipboardPeekSeconds, forKey: "clipboardPeekSeconds") } }
    @Published var musicPeekSeconds: Double { didSet { UserDefaults.standard.set(musicPeekSeconds, forKey: "musicPeekSeconds") } }
    /// Grace between the pointer leaving the HUD and it retracting. The old
    /// hard-coded 0.15s made the panel feel like it was running away.
    @Published var hoverCollapseDelay: Double { didSet { UserDefaults.standard.set(hoverCollapseDelay, forKey: "hoverCollapseDelay") } }
    /// Show a dim resting indicator when nothing is happening, instead of the
    /// notch going completely invisible.
    @Published var alwaysShowIndicator: Bool {
        didSet {
            UserDefaults.standard.set(alwaysShowIndicator, forKey: "alwaysShowIndicator")
            refreshCollapsedFrame()
        }
    }
    @Published var dismissHotKeyEnabled: Bool { didSet { UserDefaults.standard.set(dismissHotKeyEnabled, forKey: "dismissHotKeyEnabled") } }
    @Published var clickPeekDismisses: Bool { didSet { UserDefaults.standard.set(clickPeekDismisses, forKey: "clickPeekDismisses") } }
    /// Whether moving the pointer onto a slide-out grows it into the full
    /// panel. Off by default: reaching for a slide-out to dismiss it meant
    /// the panel expanded under the cursor before the click ever landed, so
    /// "click to dismiss" was unreachable in practice. Hovering the collapsed
    /// notch still opens the panel either way.
    @Published var hoverExpandsPeek: Bool { didSet { UserDefaults.standard.set(hoverExpandsPeek, forKey: "hoverExpandsPeek") } }

    /// Manual hold keeps the screen lit (and defeats the lock). Off makes a
    /// manual hold system-only — the Amphetamine "allow display sleep" case.
    @Published var keepScreenOn: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn")
            updateCaffeine()
        }
    }
    /// When a manual hold should end. nil = indefinite (the old behaviour).
    @Published private(set) var keepAwakeUntil: Date?
    @Published var autoUpdateCheck: Bool { didSet { UserDefaults.standard.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }

    /// Mirrors what the OS reports, refreshed after every change — the user
    /// can revoke this in System Settings and we must not claim otherwise.
    @Published private(set) var openAtLogin = false
    @Published private(set) var loginItemProblem: String?

    /// macOS is refusing to show our banners. Worth surfacing loudly: the
    /// sound and the banner are separate channels, so a denied permission
    /// produced chimes with nothing on screen to explain them.
    @Published private(set) var notificationsBlocked = false
    @Published private(set) var notificationPermission = "not checked"

    func refreshNotificationStatus() {
        notificationPermission = Notifier.shared.status
        notificationsBlocked = systemNotifications && !Notifier.shared.canPost
    }

    /// Deep-link into the Notifications pane so the fix is one click away.
    func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    func setOpenAtLogin(_ on: Bool) {
        loginItemProblem = LoginItem.set(on)
        openAtLogin = LoginItem.isEnabled
    }

    func refreshLoginItem() { openAtLogin = LoginItem.isEnabled }

    /// Start (or extend) the manual hold. `minutes == 0` means indefinite.
    func holdAwake(minutes: Int) {
        keepAwakeUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        keepAwake = true
    }

    func releaseAwakeHold() {
        keepAwakeUntil = nil
        keepAwake = false
    }

    /// Whether a timed manual hold has run out. An indefinite hold (nil
    /// deadline) never expires — that is what "indefinitely" means.
    nonisolated static func holdExpired(keepAwake: Bool, until: Date?, now: Date) -> Bool {
        guard keepAwake, let until else { return false }
        return now >= until
    }

    /// Remaining manual hold, for the menu title and the settings window.
    var awakeRemaining: TimeInterval? {
        guard keepAwake, let until = keepAwakeUntil else { return nil }
        return max(0, until.timeIntervalSinceNow)
    }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var nowPlayingArt: NSImage?
    @Published private(set) var nowPlayingArtColor: NSColor?

    /// Set by NotchWindowController; resizes the panel window for a target state.
    var frameUpdater: ((HUDState) -> Void)?

    @Published var selectedSessionId: String?

    /// When the peek shows a copied image, the island morphs to its shape.
    var peekPreviewSize: CGSize? {
        if case .peek(.clipboard(let c)) = hudState, let img = c.image {
            return hudFitSize(img.size, in: CGSize(width: 210, height: 130))
        }
        return nil
    }

    var selectedSession: SessionInfo? {
        if let id = selectedSessionId, let s = sessions.first(where: { $0.id == id }) { return s }
        return sessions.first
    }

    var remoteHostCount: Int {
        Set(sessions.map(\.host)).filter { !Host.isLocal($0) && $0 != "web" }.count
    }

    enum Host {
        /// Every local name form collapses to this one label. The Mac answers
        /// to several names (hostname, LocalHostName, ComputerName) and DHCP
        /// can swap the DNS one mid-day — without normalization the same
        /// machine splits into two "hosts" with duplicate session cards.
        static let canonicalLocal = "Mac"

        private static var names: Set<String> = []
        private static var namesAt = Date.distantPast

        /// Refreshed rather than computed once: the hostname changes with
        /// network state, and a name learned at launch can go stale.
        static func localNames() -> Set<String> {
            if Date().timeIntervalSince(namesAt) > 60 {
                var s: Set<String> = [firstComponent(canonicalLocal)]
                s.insert(firstComponent(ProcessInfo.processInfo.hostName))
                var buf = [CChar](repeating: 0, count: 256)
                if gethostname(&buf, buf.count) == 0 { s.insert(firstComponent(String(cString: buf))) }
                if let n = SCDynamicStoreCopyLocalHostName(nil) as String? { s.insert(firstComponent(n)) }
                if let n = SCDynamicStoreCopyComputerName(nil, nil) as String? { s.insert(firstComponent(n)) }
                names = s
                namesAt = Date()
            }
            return names
        }

        private static func firstComponent(_ h: String) -> String {
            (h.split(separator: ".").first.map(String.init) ?? h).lowercased()
        }

        static func isLocal(_ host: String) -> Bool { localNames().contains(firstComponent(host)) }

        static func normalize(_ host: String) -> String { isLocal(host) ? canonicalLocal : host }
    }

    /// JSON snapshot for GET /debug — the observability we owe ourselves.
    func debugDump() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let evs = events.prefix(50).map { e -> [String: String] in
            ["t": fmt.string(from: e.ts), "kind": e.kind.rawValue, "label": e.label,
             "hook": e.hook, "msg": String(e.message.prefix(80))]
        }
        let sess = sessions.map { s -> [String: String] in
            ["name": sessionDisplayName(s.sessionName, project: s.project),
             "host": s.host, "kind": s.kind.rawValue]
        }
        let hud: String
        switch hudState {
        case .collapsed: hud = "collapsed"
        case .peek: hud = "peek"
        case .open: hud = "open"
        }
        let obj: [String: Any] = [
            "events": evs, "sessions": sess,
            "hud": ["stage": hud, "hovering": hovering,
                    "aggregate": aggregate.rawValue] as [String: Any],
            "notifications": [
                "permission": Notifier.shared.status,
                "canPost": Notifier.shared.canPost,
                "delivered": Notifier.shared.deliveredCount,
                "suppressed": Notifier.shared.suppressedCount,
                "enabledInApp": systemNotifications,
                "soundsInApp": sounds,
            ] as [String: Any],
            "alerts": alertLog.prefix(25).map { r -> [String: String] in
                ["t": fmt.string(from: r.ts), "kind": r.kind.rawValue, "hook": r.hook,
                 "label": r.label, "chimed": r.alerted ? "yes" : "no", "why": r.reason]
            },
            "muted": muted, "banners": systemNotifications, "sounds": sounds,
            "awake": ["reason": awakeReason, "active": awakeActive,
                      "assertionAlive": Caffeine.shared.assertionAlive,
                      "jiggleAuthorized": Caffeine.shared.jiggleAuthorized],
            "hostLastReport": hostLastReport.mapValues { "\(Int(Date().timeIntervalSince($0)))s ago" },
            "music": [
                "bar": nowPlaying.map {
                    "\($0.app) · \($0.title) · \($0.playing ? "playing" : "paused") · tab=\($0.tab.isEmpty ? "legacy" : $0.tab)"
                } ?? "none",
                "tabs": webStates.map { key, v in
                    "\(key.isEmpty ? "legacy" : key): \(v.np.title) \(v.np.playing ? "▶" : "⏸") \(Int(Date().timeIntervalSince(v.ts)))s ago"
                },
                "commands": webMusicQueue?.recentActivity() ?? [],
            ] as [String: Any],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func focusTerminal() {
        for bid in ["com.cmuxterm.app", "com.googlecode.iterm2", "com.apple.Terminal"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    private var collapseTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private(set) var hovering = false

    init() {
        let d = UserDefaults.standard
        systemNotifications = d.object(forKey: "systemNotifications") as? Bool ?? true
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        expandOnCopy = d.object(forKey: "expandOnCopy") as? Bool ?? true
        sideBars = d.object(forKey: "sideBars") as? Bool ?? true
        musicEnabled = d.object(forKey: "musicEnabled") as? Bool ?? true
        animStyle = AnimStyle(rawValue: d.string(forKey: "animStyle") ?? "") ?? .bouncy
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? false
        autoAwake = d.object(forKey: "autoAwake") as? Bool ?? true
        muted = d.object(forKey: "muted") as? Bool ?? false
        attentionPeekSeconds = d.object(forKey: "attentionPeekSeconds") as? Double ?? 30
        donePeekSeconds = d.object(forKey: "donePeekSeconds") as? Double ?? 7
        clipboardPeekSeconds = d.object(forKey: "clipboardPeekSeconds") as? Double ?? 3.5
        musicPeekSeconds = d.object(forKey: "musicPeekSeconds") as? Double ?? 4
        hoverCollapseDelay = d.object(forKey: "hoverCollapseDelay") as? Double ?? 0.6
        alwaysShowIndicator = d.object(forKey: "alwaysShowIndicator") as? Bool ?? false
        dismissHotKeyEnabled = d.object(forKey: "dismissHotKeyEnabled") as? Bool ?? true
        clickPeekDismisses = d.object(forKey: "clickPeekDismisses") as? Bool ?? true
        hoverExpandsPeek = d.object(forKey: "hoverExpandsPeek") as? Bool ?? false
        keepScreenOn = d.object(forKey: "keepScreenOn") as? Bool ?? true
        autoUpdateCheck = d.object(forKey: "autoUpdateCheck") as? Bool ?? true
        openAtLogin = LoginItem.isEnabled
        updateCaffeine()
    }

    // MARK: - Derived

    var runningCount: Int { sessions.filter { $0.kind == .running }.count }
    var attentionCount: Int { sessions.filter { $0.kind == .attention }.count }

    var aggregate: EventKind {
        if attentionCount > 0 || pendingAttention > 0 { return .attention }
        if runningCount > 0 { return .running }
        if let last = sessions.map(\.updated).max(), Date().timeIntervalSince(last) < 300,
           sessions.contains(where: { $0.kind == .done }) { return .done }
        return .info
    }

    // MARK: - Agent events

    /// Runs shorter than this get only the silent peek — you were probably
    /// watching that session anyway; banners are for runs you walked away from.
    static let longRunThreshold: TimeInterval = 45
    var runStarts: [String: Date] = [:]  // internal for tests

    /// How long a run lasted. An unknown start means unknown length, which
    /// must read as short: treating it as infinite made every finish without
    /// a recorded start ring the bell, and starts are lost on app restart.
    nonisolated static func runLength(start: Date?, end: Date) -> TimeInterval {
        guard let start else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    /// Remember when a run began so its length can be judged at the end.
    /// Every path that turns a card "running" must call this — the registry
    /// paths included, or their finishes have no length to judge.
    private func noteRunStart(_ key: String, at ts: Date = Date()) {
        if runStarts[key] == nil { runStarts[key] = ts }
    }

    /// Why each recent event did or didn't chime. "Random chimes" is only
    /// diagnosable if the app can say what it thought it was doing.
    struct AlertRecord {
        let ts: Date
        let label: String
        let kind: EventKind
        let hook: String
        let runSeconds: TimeInterval
        let alerted: Bool
        let reason: String
    }
    private(set) var alertLog: [AlertRecord] = []

    private func noteAlertDecision(_ e: AgentEvent, runDuration: TimeInterval, alerted: Bool) {
        let reason: String
        if muted {
            reason = "muted"
        } else {
            switch e.kind {
            case .attention: reason = "needs-you always alerts"
            case .done:
                reason = runDuration >= Self.longRunThreshold
                    ? "run was \(Int(runDuration))s (≥ \(Int(Self.longRunThreshold))s)"
                    : "run was \(Int(runDuration))s (< \(Int(Self.longRunThreshold))s)"
            case .running, .info: reason = "\(e.kind.rawValue) never alerts"
            }
        }
        alertLog.insert(AlertRecord(ts: e.ts, label: e.label, kind: e.kind, hook: e.hook,
                                    runSeconds: runDuration, alerted: alerted, reason: reason),
                        at: 0)
        if alertLog.count > 40 { alertLog.removeLast(alertLog.count - 40) }
    }

    /// Whether an event earns a banner + sound, as opposed to a silent peek.
    static func shouldAlert(kind: EventKind, runDuration: TimeInterval, muted: Bool) -> Bool {
        guard !muted else { return false }
        switch kind {
        case .attention: return true
        case .done: return runDuration >= longRunThreshold
        case .running, .info: return false
        }
    }

    func apply(_ rawEvent: AgentEvent) {
        let event = rawEvent.with(host: Host.normalize(rawEvent.host))
        eventsReceived += 1
        events.insert(event, at: 0)
        if events.count > 150 { events.removeLast(events.count - 150) }

        if event.kind == .running { noteRunStart(event.sourceKey, at: event.ts) }
        // An unknown start is NOT a long run. Treating it as infinite meant
        // every finish without a recorded start rang the bell — and starts
        // are lost on every app restart, so a relaunch turned ordinary
        // three-second turns into chimes for the rest of the day.
        let runDuration = Self.runLength(start: runStarts[event.sourceKey], end: event.ts)
        if event.kind == .done { runStarts.removeValue(forKey: event.sourceKey) }

        upsertSession(event)

        if !hudState.isOpen {
            switch event.kind {
            case .attention: show(.peek(.event(event)), autoCollapse: attentionPeekSeconds)
            case .done: show(.peek(.event(event)), autoCollapse: donePeekSeconds)
            case .running, .info: break  // your own prompt isn't news
            }
        }
        let alerted = Self.shouldAlert(kind: event.kind, runDuration: runDuration, muted: muted)
        noteAlertDecision(event, runDuration: runDuration, alerted: alerted)
        if alerted {
            Notifier.shared.post(for: event, enabled: systemNotifications)
            if sounds { Sound.play(for: event.kind) }
        }
        refreshCollapsedFrame()
    }

    /// Collapsed width depends on aggregate status (side wings); resize in place.
    private func refreshCollapsedFrame() {
        updateCaffeine()
        if hudState.isCollapsed { frameUpdater?(.collapsed) }
    }

    @Published private(set) var awakeActive = false
    @Published private(set) var awakeReason = ""
    var lastBusyAt: Date?  // internal for tests

    /// Auto mode keeps the system up for a while after the last agent goes
    /// quiet, so reverse tunnels survive gaps between bursty overnight runs.
    /// Once the Mac sleeps, no remote event can ever wake it — auto-awake can
    /// extend wakefulness but never restore it.
    nonisolated static let autoLinger: TimeInterval = 600

    /// Pure policy: which hold do we want right now?
    /// Attention counts as busy — an agent waiting for approval is exactly
    /// when reachability matters most.
    nonisolated static func desiredHold(keepAwake: Bool, autoAwake: Bool,
                                        running: Int, attention: Int,
                                        lastBusyAge: TimeInterval?,
                                        keepScreenOn: Bool = true) -> Caffeine.Mode {
        // A manual hold keeps the screen lit by default; turning that off
        // makes it system-only, so the Mac stays up with a dark display.
        if keepAwake { return keepScreenOn ? .display : .system }
        guard autoAwake else { return .off }
        if running > 0 || attention > 0 { return .system }
        if let age = lastBusyAge, age < autoLinger { return .system }
        return .off
    }

    func updateCaffeine() {
        let now = Date()
        // A timed hold ends itself — the whole point of asking for 30 minutes
        // rather than "on".
        if Self.holdExpired(keepAwake: keepAwake, until: keepAwakeUntil, now: now) {
            keepAwakeUntil = nil
            keepAwake = false   // re-enters updateCaffeine via didSet
            return
        }
        if runningCount > 0 || attentionCount > 0 { lastBusyAt = now }
        let mode = Self.desiredHold(keepAwake: keepAwake, autoAwake: autoAwake,
                                    running: runningCount, attention: attentionCount,
                                    lastBusyAge: lastBusyAt.map { now.timeIntervalSince($0) },
                                    keepScreenOn: keepScreenOn)
        let alive = Caffeine.shared.set(mode: mode)
        let active = alive && mode != .off
        if active != awakeActive { awakeActive = active }
        let reason: String
        switch mode {
        case .off: reason = ""
        case .display: reason = "manual"
        case .system: reason = (runningCount > 0 || attentionCount > 0) ? "agents" : "cooldown"
        }
        if reason != awakeReason { awakeReason = reason }
    }

    private func upsertSession(_ e: AgentEvent) {
        guard e.kind != .info else { return }
        let wasAttention = sessions.first(where: { $0.id == e.sourceKey })?.kind == .attention
        if let i = sessions.firstIndex(where: { $0.id == e.sourceKey }) {
            if wasAttention && e.kind != .attention {
                pendingAttention = max(0, pendingAttention - 1)
            }
            sessions[i].kind = e.kind
            sessions[i].message = e.message
            sessions[i].updated = e.ts
            if !e.project.isEmpty { sessions[i].project = e.project }
            if !e.sessionName.isEmpty { sessions[i].sessionName = e.sessionName }
        } else {
            sessions.append(SessionInfo(id: e.sourceKey, host: e.host, project: e.project,
                                        sessionName: e.sessionName, kind: e.kind,
                                        message: e.message, updated: e.ts))
        }
        // One count per waiting session, not per notification. Claude Code
        // fires Notification repeatedly for a single session (two permission
        // prompts in a turn is routine), and the decrement only ever ran on a
        // transition out of .attention — so the residue left the collapsed
        // notch glowing orange after everything had actually finished.
        if e.kind == .attention && !wasAttention { pendingAttention += 1 }
        sortSessions()
        if sessions.count > 12 {
            // Evicted cards must hand back what they were holding, or the
            // counter (and the glow) leaks for the life of the app.
            for evicted in sessions.suffix(sessions.count - 12) {
                if evicted.kind == .attention { pendingAttention = max(0, pendingAttention - 1) }
                runStarts.removeValue(forKey: evicted.id)
                latestEntries.removeValue(forKey: evicted.id)
            }
            sessions.removeLast(sessions.count - 12)
        }
    }

    /// Attention first, then running, then finished — every path that changes
    /// a card's kind must re-sort, or a dead card can sit in a visible slot
    /// while a live one hides past the display cutoff.
    private func sortSessions() {
        sessions.sort { a, b in
            let ra = Self.rank(a.kind), rb = Self.rank(b.kind)
            return ra == rb ? a.updated > b.updated : ra < rb
        }
    }

    /// Bookkeeping for a card leaving the running/attention world outside
    /// apply(): the run-start must not survive to poison a future resume's
    /// duration (spurious long-run chime), and the list must re-rank.
    private func demoteQuietly(id: String, message: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        demoteQuietly(at: i, message: message)
    }

    private func demoteQuietly(at i: Int, message: String) {
        if sessions[i].kind == .attention { pendingAttention = max(0, pendingAttention - 1) }
        runStarts.removeValue(forKey: sessions[i].id)
        sessions[i].kind = .done
        sessions[i].message = message
        sessions[i].updated = Date()
        sortSessions()
    }

    private static func rank(_ k: EventKind) -> Int {
        switch k {
        case .attention: return 0
        case .running: return 1
        case .done: return 2
        case .info: return 3
        }
    }

    // MARK: - Session registry sync (~/.claude/sessions, local or reported by a remote box)

    private var registryActive: [String: Set<String>] = [:]

    @Published private(set) var hostUsage: [String: [String: Int]] = [:]
    @Published private(set) var hostHours: [String: [Int: Int]] = [:]
    var hostLastReport: [String: Date] = [:]  // internal for tests
    private var latestEntries: [String: LocalSessionEntry] = [:]
    private var pendingFinish: [String: Task<Void, Never>] = [:]

    /// A host reporting every ~5s that goes silent this long has lost its
    /// tunnel or reporter; its "running" sessions are frozen ghosts.
    static let hostSilenceCutoff: TimeInterval = 90

    /// Browser tabs never POST /sessions — they send transition events plus a
    /// ~30s heartbeat while generating. A "web" card older than this belongs
    /// to a closed or crashed tab.
    static let webSilenceCutoff: TimeInterval = 150

    /// Hook-only hosts with neither registry nor heartbeat: safety net so a
    /// ghost can't hold the Mac awake forever, generous enough for real turns.
    static let orphanSilenceCutoff: TimeInterval = 3600

    /// A running/attention card whose session the host's own registry doesn't
    /// list is an orphan (its terminal died); grace covers report races.
    static let registryOrphanGrace: TimeInterval = 180

    /// Periodic self-healing: demote sessions from silent hosts (a dead
    /// tunnel must not hold the Mac awake all night), prune old finishes,
    /// and re-arm/retry the power assertion. Runs on a timer and on wake.
    func maintenanceSweep(now: Date = Date()) {
        // Collected first, demoted after: demoteQuietly re-sorts, and mutating
        // the array under an index loop skipped ghosts — each extra one held
        // the Mac awake for another sweep.
        let doomed = sessions.filter { s in
            guard s.kind == .running || s.kind == .attention else { return false }
            if let seen = hostLastReport[s.host] {
                return now.timeIntervalSince(seen) > Self.hostSilenceCutoff
            }
            // Hosts that never report (web tabs, hook-only sources) are
            // judged by the card's own last update instead.
            let cutoff = s.host == "web" ? Self.webSilenceCutoff : Self.orphanSilenceCutoff
            return now.timeIntervalSince(s.updated) > cutoff
        }.map(\.id)
        for id in doomed { demoteQuietly(id: id, message: "lost contact") }
        let mutated = !doomed.isEmpty
        let before = sessions.count
        sessions.removeAll { $0.kind == .done && now.timeIntervalSince($0.updated) > 1800 }
        if mutated || sessions.count != before {
            refreshCollapsedFrame()
        } else {
            updateCaffeine()
        }
    }

    /// Token burn per hour across all machines, last 48 cells oldest→newest.
    var burnCells: [(hour: Int, tokens: Int)] {
        let nh = Int(Date().timeIntervalSince1970) / 3600
        return ((nh - 47)...nh).map { h in
            (h, hostHours.values.reduce(0) { $0 + ($1[h] ?? 0) })
        }
    }

    var estH5: Int { hostUsage.values.reduce(0) { $0 + ($1["h5"] ?? 0) } }
    var estD7: Int { hostUsage.values.reduce(0) { $0 + ($1["d7"] ?? 0) } }
    var estPeak: Int { hostUsage.values.reduce(0) { $0 + ($1["h5_peak"] ?? 0) } }

    /// Real limits, one entry per Claude account. Each machine reports the
    /// account it is logged into, so a work login on the Mac and a personal
    /// login on a dev box both get their own card. Within an account the
    /// freshest reading wins, since limits are account-wide.
    @Published private(set) var accountLimits: [AccountLimits] = []
    private var limitsByAccount: [String: AccountLimits] = [:]
    private var hostAccount: [String: String] = [:]

    /// Readings older than this are dropped — an account nobody is using
    /// shouldn't linger on the HUD.
    static let limitsRetention: TimeInterval = 3600

    func syncRegistry(_ report: RegistryReport) {
        let host = Host.normalize(report.host)
        syncRegistry(host: host, entries: report.entries,
                     usage: report.usage, hours: report.hours)
        guard let limits = report.limits else { return }
        hostAccount[host] = limits.key
        if limits.fetchedAt >= (limitsByAccount[limits.key]?.fetchedAt ?? .distantPast) {
            limitsByAccount[limits.key] = limits
        }
        rebuildAccountLimits()
    }

    private func rebuildAccountLimits() {
        let now = Date()
        var byAccount: [String: Set<String>] = [:]
        for (host, key) in hostAccount { byAccount[key, default: []].insert(host) }
        accountLimits = limitsByAccount.values
            .filter { now.timeIntervalSince($0.fetchedAt) < Self.limitsRetention }
            .map { limits in
                var l = limits
                l.hosts = byAccount[limits.key] ?? []
                return l
            }
            .filter { !$0.hosts.isEmpty }   // an account nobody reports is gone
            .sorted { $0.fetchedAt > $1.fetchedAt }
        limitsByAccount = limitsByAccount.filter { key, _ in byAccount[key] != nil }
    }

    func syncRegistry(host rawHost: String, entries: [LocalSessionEntry], usage: [String: Int] = [:], hours: [Int: Int] = [:]) {
        let host = Host.normalize(rawHost)
        hostLastReport[host] = Date()
        if !usage.isEmpty { hostUsage[host] = usage }
        if !hours.isEmpty { hostHours[host] = hours }
        let primed = registryActive[host] != nil
        let last = registryActive[host] ?? []
        let present = Set(entries.map(\.sessionId))
        var activeNow = Set<String>()
        for e in entries { latestEntries["\(host)#\(e.sessionId)"] = e }
        for e in entries where e.isActive {
            activeNow.insert(e.sessionId)
            localSessionActive(e, host: host, announce: primed && !last.contains(e.sessionId))
        }
        if primed {
            for e in entries where last.contains(e.sessionId) && !e.isActive {
                localSessionFinished(e, host: host)
            }
            for id in last.subtracting(activeNow).subtracting(present) {
                localSessionGone(id, host: host)
            }
        }
        registryActive[host] = activeNow
        // Hook-created cards for sessions this host's own registry doesn't
        // list (the terminal died before or between reports) must not stay
        // "working" forever — the stuck-attention class of ghosts.
        let prefix = "\(host)#"
        let orphans = sessions.filter { s in
            guard s.id.hasPrefix(prefix),
                  s.kind == .running || s.kind == .attention else { return false }
            let sid = String(s.id.dropFirst(prefix.count))
            return !sid.isEmpty && !present.contains(sid)
                && Date().timeIntervalSince(s.updated) > Self.registryOrphanGrace
        }.map(\.id)
        for id in orphans { demoteQuietly(id: id, message: "session ended") }
        let mutated = !orphans.isEmpty
        // Snapshots for sessions this host no longer lists are dead weight —
        // nothing evicted them, so the dictionary grew for the life of the
        // app. A finish still waiting on its verdict keeps its snapshot.
        latestEntries = latestEntries.filter { key, _ in
            guard key.hasPrefix(prefix) else { return true }
            let sid = String(key.dropFirst(prefix.count))
            return present.contains(sid) || pendingFinish[key] != nil
        }
        // Drop long-finished sessions so the list stays live.
        let stale = sessions.contains { $0.kind == .done && Date().timeIntervalSince($0.updated) > 1800 }
        if stale {
            sessions.removeAll { $0.kind == .done && Date().timeIntervalSince($0.updated) > 1800 }
        }
        if mutated || stale { refreshCollapsedFrame() }
    }

    private func localSessionActive(_ e: LocalSessionEntry, host: String, announce: Bool) {
        let key = "\(host)#\(e.sessionId)"
        // Session became active again before a pending finish resolved —
        // that blip (e.g. prompt + instant Esc + retype) wasn't a real end.
        if let pending = pendingFinish[key] {
            pending.cancel()
            pendingFinish[key] = nil
        }
        let project = (e.cwd as NSString).lastPathComponent
        if let i = sessions.firstIndex(where: { $0.id == key }) {
            if !e.name.isEmpty { sessions[i].sessionName = e.name }
            applyStats(e, at: i)
            if sessions[i].kind == .done {
                sessions[i].kind = .running
                sessions[i].updated = Date()
                noteRunStart(key)   // a revived run is a new run
                refreshCollapsedFrame()
            }
            return
        }
        let ev = AgentEvent(kind: .running, host: host, project: project, sessionId: e.sessionId,
                            sessionName: e.name, message: "started", hook: "registry", image: nil, ts: Date())
        if announce {
            apply(ev)
        } else {
            // Silent adoption (sessions already running when the app started):
            // still record the start, or their first finish can't be measured.
            noteRunStart(key)
            upsertSession(ev)
            refreshCollapsedFrame()
        }
        if let i = sessions.firstIndex(where: { $0.id == key }) { applyStats(e, at: i) }
    }

    private func applyStats(_ e: LocalSessionEntry, at i: Int) {
        if !e.model.isEmpty { sessions[i].model = e.model }
        if !e.effort.isEmpty { sessions[i].effort = e.effort }
        if e.ctxUsed > 0 {
            sessions[i].ctxUsed = e.ctxUsed
            sessions[i].lastIn = e.lastIn
            sessions[i].lastOut = e.lastOut
        }
        if e.filesChanged > 0 {
            sessions[i].filesChanged = e.filesChanged
            sessions[i].linesAdded = e.linesAdded
            sessions[i].linesRemoved = e.linesRemoved
            sessions[i].topFile = e.topFile
        }
    }

    /// How long a status flip waits for a fresher snapshot before judging the
    /// outcome. Shrunk by tests; 6s in production.
    var finishVerdictDelay: TimeInterval = 6

    private func localSessionFinished(_ e: LocalSessionEntry, host: String) {
        let key = "\(host)#\(e.sessionId)"
        // Attention counts too: a session that dies while waiting for approval
        // must resolve rather than glow orange forever.
        guard let i = sessions.firstIndex(where: { $0.id == key }),
              sessions[i].kind == .running || sessions[i].kind == .attention else { return }
        // Don't trust the outcome at the instant of the status flip — the
        // interrupt/error markers may not be flushed or rescanned yet. Wait
        // for a fresher snapshot, then judge. A hook Stop event landing in
        // the meantime wins (kind is no longer .running → we stay silent).
        pendingFinish[key]?.cancel()
        pendingFinish[key] = Task { [weak self, delay = finishVerdictDelay] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingFinish[key] = nil
            guard let i = self.sessions.firstIndex(where: { $0.id == key }),
                  self.sessions[i].kind == .running || self.sessions[i].kind == .attention else { return }
            let fresh = self.latestEntries[key] ?? e
            let name = fresh.name.isEmpty ? self.sessions[i].sessionName : fresh.name
            let message: String
            switch fresh.outcome {
            case "interrupted": message = "interrupted by you"
            case "error": message = "ended with an error ⚠︎"
            default: message = "finished"
            }
            self.apply(AgentEvent(kind: .done, host: host,
                                  project: (fresh.cwd as NSString).lastPathComponent,
                                  sessionId: fresh.sessionId, sessionName: name, message: message,
                                  hook: "registry", image: nil, ts: Date()))
        }
    }

    private func localSessionGone(_ sessionId: String, host: String) {
        let key = "\(host)#\(sessionId)"
        guard let i = sessions.firstIndex(where: { $0.id == key }) else { return }
        if sessions[i].kind == .running || sessions[i].kind == .attention {
            // A vanished session is bookkeeping, not an achievement — demote
            // quietly. Routing these through apply() made them chime like
            // real finishes: random Glass all day as terminals died.
            demoteQuietly(at: i, message: "session ended")
        } else {
            sessions.remove(at: i)
        }
        refreshCollapsedFrame()
    }

    // MARK: - Music

    /// Set by AppDelegate; commands for browser-based players queue here.
    var webMusicQueue: CommandQueue?
    private var lastNative: NowPlaying?
    /// One state per browser tab — two playing tabs must not share a slot.
    private var webStates: [String: (np: NowPlaying, ts: Date)] = [:]
    private var lastMusicTitle = ""

    /// Browsers throttle background-tab timers to roughly once a minute, so a
    /// short freshness window would make a playing YouTube tab flicker in and
    /// out of existence every time you click onto another display.
    private static let webMusicFreshness: TimeInterval = 90

    /// Tabs running the pre-update script all report tab="" — one shared slot
    /// meant a paused tab overwrote the playing tab's state every 2s and the
    /// bar flapped (play/pause flicker, peek storms, wrong-tab pauses). Keyed
    /// by title, each legacy tab gets its own slot too.
    private func webKey(_ np: NowPlaying) -> String {
        np.tab.isEmpty ? "legacy:\(np.title)" : np.tab
    }

    func setWebNowPlaying(_ np: NowPlaying) {
        if np.tab.isEmpty, np.playing {
            // A playing legacy report supersedes other playing legacy entries:
            // a same-tab track change must land instantly, while a paused tab
            // keeps its own slot and can't clobber the playing one.
            webStates = webStates.filter { key, v in
                !(key.hasPrefix("legacy:") && v.np.playing) || key == webKey(np)
            }
        }
        webStates[webKey(np)] = (np, Date())
        composeNowPlaying(native: lastNative)
    }

    /// Prefer whichever source is actually playing; native app wins ties.
    /// Among several playing tabs the one already on the bar stays — two tabs
    /// both reporting every 2s must not take turns flapping the title —
    /// otherwise the freshest report wins.
    func composeNowPlaying(native: NowPlaying?) {
        lastNative = native
        guard musicEnabled else {
            setNowPlaying(nil)
            return
        }
        let now = Date()
        webStates = webStates.filter { now.timeIntervalSince($0.value.ts) < Self.webMusicFreshness }
        let playing = webStates.filter { $0.value.np.playing }
        let sticky = nowPlaying.flatMap { cur in cur.isWeb ? playing[webKey(cur)]?.np : nil }
        let web = sticky
            ?? playing.values.max(by: { $0.ts < $1.ts })?.np
            ?? webStates.values.max(by: { $0.ts < $1.ts })?.np
        let pick: NowPlaying?
        if let n = native, n.playing {
            pick = n
        } else if let w = web, w.playing {
            pick = w
        } else {
            pick = native ?? web
        }
        setNowPlaying(pick)
    }

    /// The click-to-icon promise: browser tabs pull commands and report state
    /// on their own (throttled) clock, so a playpause click flips the bar
    /// immediately and real reports reconcile it — otherwise the icon froze,
    /// people clicked again, and the extra toggles paused/played at random.
    private var optimisticPlay: (title: String, value: Bool, until: Date)?

    func musicControl(_ cmd: String) {
        guard let np = nowPlaying else { return }
        if np.isWeb {
            webMusicQueue?.push(cmd, tab: np.tab)
            if cmd == "playpause" {
                let target = !np.playing
                optimisticPlay = (np.title, target, Date().addingTimeInterval(8))
                var flipped = np
                flipped.playing = target
                nowPlaying = flipped
            }
        } else {
            // Only known verbs cross into AppleScript — an unmapped command
            // used to be forwarded verbatim, which made the music endpoint a
            // remote shell for anything that could reach the listener.
            let map = ["playpause": "playpause", "next": "next track", "previous": "previous track"]
            guard let verb = map[cmd] else { return }
            MusicWatcher.control(verb, app: np.app)
        }
    }

    /// POST /music/commands lands here: with an explicit tab it queues raw
    /// (diagnostics — prove delivery with a "noop"); without one it takes
    /// exactly the path a button click takes.
    func externalMusicCommand(_ cmd: String, tab: String?) {
        if let tab {
            webMusicQueue?.push(cmd, tab: tab)
        } else {
            musicControl(cmd)
        }
    }

    /// Click on the now-playing title: bring the player forward — the native
    /// app, or the exact tab that's playing (a targeted command the tab picks
    /// up, plus raising the browser itself).
    func musicFocus() {
        guard let np = nowPlaying else { return }
        if np.isWeb {
            webMusicQueue?.push("focus", tab: np.tab)
            for bid in ["com.google.Chrome", "com.apple.Safari",
                        "company.thebrowser.Browser", "com.microsoft.edgemac"] {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                    app.activate(options: [])
                    break
                }
            }
        } else {
            let bid = np.app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
            NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.activate(options: [])
        }
    }

    /// Titles peeked recently — a title that leaves the bar and returns
    /// within this window (two tabs trading places, throttled background
    /// reports) is not a new song and must not peek again.
    private var recentPeeks: [String: Date] = [:]
    private static let peekEncore: TimeInterval = 180

    /// Bumped per artwork request so a slow fetch can't overwrite a newer one.
    private var artworkGeneration = 0

    private func setNowPlaying(_ incoming: NowPlaying?) {
        var np = incoming
        if let o = optimisticPlay {
            if Date() > o.until || (np?.title == o.title && np?.playing == o.value) {
                optimisticPlay = nil  // the tab confirmed, or the promise expired
            } else if np?.title == o.title, np?.isWeb == true {
                np?.playing = o.value  // hold the promise while the command travels
            }
        }
        // Reports arrive every 2s; identical state must not churn the UI.
        if nowPlaying != np { nowPlaying = np }
        // Keyed off the last *announced* track, not the current value: a track
        // briefly going stale and coming back is not a new song, and must not
        // re-peek or re-fetch artwork.
        guard let np, np.title != lastMusicTitle else { return }
        lastMusicTitle = np.title
        nowPlayingArt = nil
        nowPlayingArtColor = nil
        if !np.artworkURL.isEmpty, let url = URL(string: np.artworkURL) {
            // Skipping tracks used to leave whichever fetch finished last on
            // screen — track B playing under track A's art and glow. Only the
            // newest request may paint.
            artworkGeneration &+= 1
            let generation = artworkGeneration
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                let thumb = img.hudThumbnail(maxDim: 240)
                let avg = thumb.averageColor
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.artworkGeneration == generation else { return }
                        self.nowPlayingArt = thumb
                        self.nowPlayingArtColor = avg
                    }
                }
            }.resume()
        }
        let lastPeek = recentPeeks[np.title]
        if np.playing && !hudState.isOpen,
           lastPeek.map({ Date().timeIntervalSince($0) > Self.peekEncore }) ?? true {
            recentPeeks[np.title] = Date()
            recentPeeks = recentPeeks.filter { Date().timeIntervalSince($0.value) < Self.peekEncore }
            show(.peek(.music(np)), autoCollapse: musicPeekSeconds)
        }
    }

    // MARK: - Clipboard

    func clipboardChanged(_ item: ClipboardItem) {
        // Identical content is a re-assert, not a new copy — see
        // clipboardSignature. Common when switching apps/displays.
        guard clipboard.first?.signature != item.signature else { return }
        if let i = clipboard.firstIndex(where: { $0.signature == item.signature }) {
            // Re-copy of an older chip (usually a click on it): move the
            // existing item so its view — mid "Copied" flash — survives,
            // and skip the peek; you were looking right at it.
            let existing = clipboard.remove(at: i)
            clipboard.insert(existing, at: 0)
            return
        }
        clipboard.insert(item, at: 0)
        if clipboard.count > 10 { clipboard.removeLast(clipboard.count - 10) }
        if expandOnCopy && !hudState.isOpen {
            show(.peek(.clipboard(item)), autoCollapse: clipboardPeekSeconds)
        }
    }

    // MARK: - HUD state machine

    func openPanel() {
        pendingAttention = 0
        show(.open, autoCollapse: hovering ? nil : 18)
    }

    func collapse() {
        show(.collapsed, autoCollapse: nil)
    }

    /// Retract whatever is showing, right now — the escape hatch for a peek
    /// that lands in the middle of something. Hovering must not immediately
    /// re-open it, so the hover gate is told to stand down too.
    func dismissNow() {
        hovering = false
        hoverTask?.cancel()
        collapse()
    }

    /// Resolve one card by hand. Routes through the quiet demote so the
    /// attention count and the run-start are released properly.
    func dismiss(sessionId id: String) {
        demoteQuietly(id: id, message: "dismissed")
        refreshCollapsedFrame()
    }

    func clearEvents() {
        events.removeAll()
        sessions.removeAll()
        pendingAttention = 0
        refreshCollapsedFrame()
    }

    func hoverChanged(_ h: Bool) {
        hovering = h
        hoverTask?.cancel()
        if h {
            // Cancelling the collapse also parks a hovered slide-out: it stays
            // put while you read it instead of retracting out from under you.
            collapseTask?.cancel()
            if case .peek = hudState, !hoverExpandsPeek { return }
            if !hudState.isOpen { openPanel() }
        } else {
            // Grace so edge-skimming and a wandering pointer inside the panel
            // don't snap it shut mid-read.
            scheduleCollapse(after: hoverCollapseDelay)
        }
    }

    /// Expand-then-collapse cycle so animation styles can be compared live.
    func previewAnimation() {
        openPanel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard let self, !Task.isCancelled, !self.hovering else { return }
            self.collapse()
        }
    }

    private func scheduleCollapse(after t: TimeInterval) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.hovering else { return }
            self.collapse()
        }
    }

    private func show(_ target: HUDState, autoCollapse: TimeInterval?) {
        collapseTask?.cancel()
        withAnimation(target.isCollapsed ? animStyle.collapseAnimation : animStyle.animation) { hudState = target }
        if let t = autoCollapse { scheduleCollapse(after: t) }
    }
}

enum AnimStyle: String, CaseIterable {
    case snappy, smooth, bouncy

    var animation: Animation {
        switch self {
        // dampingFraction 1.0 = critically damped: smooth stop, zero overshoot.
        case .snappy: return .spring(response: 0.28, dampingFraction: 1.0)
        case .smooth: return .spring(response: 0.45, dampingFraction: 1.0)
        case .bouncy: return .spring(response: 0.42, dampingFraction: 0.62)
        }
    }

    /// Retract is deliberately quicker than expand.
    var collapseAnimation: Animation {
        switch self {
        case .snappy: return .spring(response: 0.18, dampingFraction: 1.0)
        case .smooth: return .spring(response: 0.28, dampingFraction: 1.0)
        case .bouncy: return .spring(response: 0.26, dampingFraction: 0.85)
        }
    }

    var label: String { rawValue.capitalized }

    /// When the content fade-in starts, tuned so it lands as the shape settles.
    var contentDelay: Double {
        switch self {
        case .snappy: return 0.12
        case .smooth: return 0.22
        case .bouncy: return 0.20
        }
    }
}
