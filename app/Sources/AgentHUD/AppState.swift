import AppKit
import SwiftUI
import Combine

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
        Set(sessions.map(\.host)).subtracting([Host.local, "web"]).count
    }

    enum Host {
        static let local = String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "mac")
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
        let obj: [String: Any] = [
            "events": evs, "sessions": sess,
            "muted": muted, "banners": systemNotifications, "sounds": sounds,
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
    private var runStarts: [String: Date] = [:]

    /// Whether an event earns a banner + sound, as opposed to a silent peek.
    static func shouldAlert(kind: EventKind, runDuration: TimeInterval, muted: Bool) -> Bool {
        guard !muted else { return false }
        switch kind {
        case .attention: return true
        case .done: return runDuration >= longRunThreshold
        case .running, .info: return false
        }
    }

    func apply(_ event: AgentEvent) {
        eventsReceived += 1
        events.insert(event, at: 0)
        if events.count > 150 { events.removeLast(events.count - 150) }

        if event.kind == .running, runStarts[event.sourceKey] == nil {
            runStarts[event.sourceKey] = event.ts
        }
        let runDuration = runStarts[event.sourceKey].map { event.ts.timeIntervalSince($0) } ?? .infinity
        if event.kind == .done { runStarts.removeValue(forKey: event.sourceKey) }

        upsertSession(event)

        if !hudState.isOpen {
            switch event.kind {
            case .attention: show(.peek(.event(event)), autoCollapse: 30)
            case .done: show(.peek(.event(event)), autoCollapse: 7)
            case .running, .info: break  // your own prompt isn't news
            }
        }
        if Self.shouldAlert(kind: event.kind, runDuration: runDuration, muted: muted) {
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

    func updateCaffeine() {
        let on = keepAwake || (autoAwake && runningCount > 0)
        if on != awakeActive { awakeActive = on }
        Caffeine.shared.set(on: on, displayAwake: keepAwake)
    }

    private func upsertSession(_ e: AgentEvent) {
        guard e.kind != .info else { return }
        if let i = sessions.firstIndex(where: { $0.id == e.sourceKey }) {
            if sessions[i].kind == .attention && e.kind != .attention {
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
        if e.kind == .attention { pendingAttention += 1 }
        sessions.sort { a, b in
            let ra = Self.rank(a.kind), rb = Self.rank(b.kind)
            return ra == rb ? a.updated > b.updated : ra < rb
        }
        if sessions.count > 12 { sessions.removeLast(sessions.count - 12) }
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
    private var latestEntries: [String: LocalSessionEntry] = [:]
    private var pendingFinish: [String: Task<Void, Never>] = [:]

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

    func syncRegistry(host: String, entries: [LocalSessionEntry], usage: [String: Int] = [:], hours: [Int: Int] = [:]) {
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
        // Drop long-finished sessions so the list stays live.
        let stale = sessions.contains { $0.kind == .done && Date().timeIntervalSince($0.updated) > 1800 }
        if stale {
            sessions.removeAll { $0.kind == .done && Date().timeIntervalSince($0.updated) > 1800 }
            refreshCollapsedFrame()
        }
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
                refreshCollapsedFrame()
            }
            return
        }
        let ev = AgentEvent(kind: .running, host: host, project: project, sessionId: e.sessionId,
                            sessionName: e.name, message: "started", hook: "registry", image: nil, ts: Date())
        if announce {
            apply(ev)
        } else {
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
    }

    private func localSessionFinished(_ e: LocalSessionEntry, host: String) {
        let key = "\(host)#\(e.sessionId)"
        guard let i = sessions.firstIndex(where: { $0.id == key }),
              sessions[i].kind == .running else { return }
        // Don't trust the outcome at the instant of the status flip — the
        // interrupt/error markers may not be flushed or rescanned yet. Wait
        // for a fresher snapshot, then judge. A hook Stop event landing in
        // the meantime wins (kind is no longer .running → we stay silent).
        pendingFinish[key]?.cancel()
        pendingFinish[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pendingFinish[key] = nil
            guard let i = self.sessions.firstIndex(where: { $0.id == key }),
                  self.sessions[i].kind == .running else { return }
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
        if sessions[i].kind == .running {
            let s = sessions[i]
            apply(AgentEvent(kind: .done, host: host, project: s.project, sessionId: sessionId,
                             sessionName: s.sessionName, message: "session ended",
                             hook: "registry", image: nil, ts: Date()))
        } else {
            sessions.remove(at: i)
            refreshCollapsedFrame()
        }
    }

    // MARK: - Music

    /// Set by AppDelegate; commands for browser-based players queue here.
    var webMusicQueue: CommandQueue?
    private var lastNative: NowPlaying?
    private var webNowPlaying: NowPlaying?
    private var webNowPlayingTs = Date.distantPast
    private var lastMusicTitle = ""

    /// Browsers throttle background-tab timers to roughly once a minute, so a
    /// short freshness window would make a playing YouTube tab flicker in and
    /// out of existence every time you click onto another display.
    private static let webMusicFreshness: TimeInterval = 90

    func setWebNowPlaying(_ np: NowPlaying) {
        webNowPlaying = np
        webNowPlayingTs = Date()
        composeNowPlaying(native: lastNative)
    }

    /// Prefer whichever source is actually playing; native app wins ties.
    func composeNowPlaying(native: NowPlaying?) {
        lastNative = native
        guard musicEnabled else {
            setNowPlaying(nil)
            return
        }
        let web = Date().timeIntervalSince(webNowPlayingTs) < Self.webMusicFreshness ? webNowPlaying : nil
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

    func musicControl(_ cmd: String) {
        guard let np = nowPlaying else { return }
        if np.app == "Spotify" || np.app == "Music" {
            let map = ["playpause": "playpause", "next": "next track", "previous": "previous track"]
            MusicWatcher.control(map[cmd] ?? cmd, app: np.app)
        } else {
            webMusicQueue?.push(cmd)
        }
    }

    private func setNowPlaying(_ np: NowPlaying?) {
        nowPlaying = np
        // Keyed off the last *announced* track, not the current value: a track
        // briefly going stale and coming back is not a new song, and must not
        // re-peek or re-fetch artwork.
        guard let np, np.title != lastMusicTitle else { return }
        lastMusicTitle = np.title
        nowPlayingArt = nil
        nowPlayingArtColor = nil
        if !np.artworkURL.isEmpty, let url = URL(string: np.artworkURL) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                let thumb = img.hudThumbnail(maxDim: 240)
                let avg = thumb.averageColor
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.nowPlayingArt = thumb
                        self.nowPlayingArtColor = avg
                    }
                }
            }.resume()
        }
        if np.playing && !hudState.isOpen {
            show(.peek(.music(np)), autoCollapse: 4)
        }
    }

    // MARK: - Clipboard

    func clipboardChanged(_ item: ClipboardItem) {
        // Identical content is a re-assert, not a new copy — see
        // clipboardSignature. Common when switching apps/displays.
        guard clipboard.first?.signature != item.signature else { return }
        clipboard.insert(item, at: 0)
        if clipboard.count > 10 { clipboard.removeLast(clipboard.count - 10) }
        if expandOnCopy && !hudState.isOpen {
            show(.peek(.clipboard(item)), autoCollapse: 3.5)
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
            collapseTask?.cancel()
            if !hudState.isOpen { openPanel() }
        } else {
            // Tiny grace so edge-skimming doesn't flicker; retract feels immediate.
            scheduleCollapse(after: 0.15)
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
