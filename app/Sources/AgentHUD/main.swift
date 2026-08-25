import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var server: EventServer!
    private var clipboardWatcher: ClipboardWatcher!
    private var musicWatcher: MusicWatcher!
    private var registryReporter: Process?
    private var aliasTimer: Timer?
    private var sweepTimer: Timer?
    private var updateTimer: Timer?
    private var awakeTimer: Timer?
    private var hotKeyObserver: AnyCancellable?
    private var terminating = false
    private var notchController: NotchWindowController!
    private var statusItemController: StatusItemController!

    @MainActor
    private func applyHotKey(_ state: AppState) {
        if state.dismissHotKeyEnabled {
            HotKey.shared.enable { [weak state] in state?.dismissNow() }
        } else {
            HotKey.shared.disable()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state
        notchController = NotchWindowController(state: state)
        statusItemController = StatusItemController(state: state)
        SettingsWindowController.shared = SettingsWindowController(state: state)
        Notifier.shared.setup()
        // Ask once shortly after launch too: the authorization callback can
        // land before the delegate is ready, and a permission revoked in
        // System Settings must show up without a relaunch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                Notifier.shared.refreshStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated { state.refreshNotificationStatus() }
                }
            }
        }
        applyHotKey(state)
        // Re-register when the preference changes, so the toggle takes effect
        // without a relaunch.
        hotKeyObserver = state.$dismissHotKeyEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyHotKey(state) }
            }
        if state.autoUpdateCheck { Updater.shared.check() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in if state.autoUpdateCheck { Updater.shared.check() } }
        }
        // Keeps a timed keep-awake hold honest — it must expire on its own
        // within seconds of its deadline, not at the next 30s sweep.
        awakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in state.updateCaffeine() }
        }
        clipboardWatcher = ClipboardWatcher { item in state.clipboardChanged(item) }
        clipboardWatcher.start()
        musicWatcher = MusicWatcher(state: state)
        musicWatcher.start()
        startLocalRegistryReporter()
        HostAliases.reload()
        aliasTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in HostAliases.reload() }
        }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                state.maintenanceSweep()
                Notifier.shared.refreshStatus()
                state.refreshNotificationStatus()
            }
        }
        // Converge fast after sleep: demote ghosts, re-arm the assertion.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in state.maintenanceSweep() }
        }
        server = EventServer(port: Playground.port, onEvent: { event in
            Task { @MainActor in state.apply(event) }
        }, onSessions: { report in
            Task { @MainActor in state.syncRegistry(report) }
        }, onMusicState: { np in
            Task { @MainActor in state.setWebNowPlaying(np) }
        }, onDebug: {
            DispatchQueue.main.sync { MainActor.assumeIsolated { state.debugDump() } }
        })
        server.onWatch = {
            DispatchQueue.main.sync { MainActor.assumeIsolated { state.watchPayload() } }
        }
        state.webMusicQueue = server.musicCommands
        server.onMusicCommand = { cmd, tab in
            Task { @MainActor in state.externalMusicCommand(cmd, tab: tab) }
        }
        do {
            try server.start()
        } catch {
            NSLog("AgentHUD: failed to start event server on \(Playground.port): \(String(describing: error))")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        registryReporter?.terminationHandler = nil
        registryReporter?.terminate()
        server?.stop()
    }

    /// The same python reporter used on remote boxes also feeds local sessions —
    /// it resolves real session names from transcript custom-title records,
    /// which the live registry loses on resume.
    private func startLocalRegistryReporter() {
        if !Playground.on {
            // Only the real instance may reap stray reporters — the playground
            // sharing this would kill the live app's feed.
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", "[a]gent-hud-registry"]
            try? kill.run()
            kill.waitUntilExit()
        }

        let path = ("~/agent-hud/bin/agent-hud-registry" as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            NSLog("AgentHUD: registry reporter missing at \(path)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        // Report under the canonical local label — gethostname() flips with
        // network state (corporate DNS names) and would split this machine
        // into two hosts.
        var env = ProcessInfo.processInfo.environment
        env["AGENT_HUD_HOST"] = "Mac"
        if Playground.on { env["AGENT_HUD_URL"] = "http://127.0.0.1:\(Playground.port)" }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            // A dead reporter silently freezes local sessions; relaunch it.
            Task { @MainActor in
                guard let self, !self.terminating else { return }
                NSLog("AgentHUD: local registry reporter died; relaunching in 5s")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !self.terminating else { return }
                self.startLocalRegistryReporter()
            }
        }
        do {
            try p.run()
            registryReporter = p
        } catch {
            NSLog("AgentHUD: failed to start registry reporter: \(String(describing: error))")
        }
    }
}

// NSApplication.delegate is unowned; keep a strong reference for the app's lifetime.
@MainActor private var delegateRef: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegateRef = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
