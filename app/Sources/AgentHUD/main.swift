import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var server: EventServer!
    private var clipboardWatcher: ClipboardWatcher!
    private var musicWatcher: MusicWatcher!
    private var registryReporter: Process?
    private var aliasTimer: Timer?
    private var sweepTimer: Timer?
    private var reliefTimer: Timer?
    private var updateTimer: Timer?
    private var awakeTimer: Timer?
    private var hotKeyObserver: AnyCancellable?
    private var terminating = false
    private var notchController: NotchWindowController?
    private var previewController: PreviewWindowController!
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
        // The drawn MacBook renders the same HUD from the same state, so
        // running the floating panel alongside it shows everything twice.
        if !Playground.lid {
            notchController = NotchWindowController(state: state)
        }
        // The playground opens a drawn MacBook instead of fighting for the
        // real notch — there is no macOS simulator, and a VM has no cutout.
        previewController = PreviewWindowController(state: state)
        if Playground.lid {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.previewController.show() }
        }
        statusItemController = StatusItemController(state: state)
        SettingsWindowController.shared = SettingsWindowController(state: state)
        if !Playground.on { Notifier.shared.setup() }
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
        awakeTimer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in state.updateCaffeine() }
        }
        if let awakeTimer { RunLoop.main.add(awakeTimer, forMode: .common) }
        // Staged screenshots must never pick up the real pasteboard.
        if !Playground.noReporter {
            clipboardWatcher = ClipboardWatcher { item in state.clipboardChanged(item) }
            clipboardWatcher.start()
        }
        musicWatcher = MusicWatcher(state: state)
        if !Playground.noReporter { musicWatcher.start() }
        startLocalRegistryReporter()
        HostAliases.reload()
        aliasTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in HostAliases.reload() }
        }
        // Serving HTTP costs ~7KB of resident memory per request that macOS's
        // allocator keeps but never reuses — a few hundred MB a day of heap it
        // is holding for nothing, which is what made the HUD get slower the
        // longer it ran. The live heap is a tenth of that, so handing the free
        // pages back is all it takes. Cheap, and a no-op when there's nothing
        // to return.
        reliefTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            malloc_zone_pressure_relief(nil, 0)
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
        state.browserCommands = server.browserCommands
        server.onBrowserFocus = { id, ok in
            Task { @MainActor in state.browserFocusFinished(id: id, ok: ok) }
        }
        server.onMusicCommand = { cmd, tab in
            Task { @MainActor in state.externalMusicCommand(cmd, tab: tab) }
        }
        server.browserToken = SupportPaths.browserToken()
        server.onStatus = { value in Task { @MainActor in state.listenerStatus = value } }
        do {
            try server.start()
            WatchBridge.shared.start()
        } catch {
            state.listenerStatus = "failed: \(error)"
            NSLog("AgentHUD: failed to start event server on \(Playground.port): \(String(describing: error))")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        registryReporter?.terminationHandler = nil
        registryReporter?.terminate()
        server?.stop()
        WatchBridge.shared.stop(terminating: true)
    }

    /// The same python reporter used on remote boxes also feeds local sessions —
    /// it resolves real session names from transcript custom-title records,
    /// which the live registry loses on resume.
    private func startLocalRegistryReporter() {
        // Screenshots for the README are fed synthetic sessions on purpose —
        // the real ones carry private project names and internal hostnames.
        if Playground.noReporter { state.reporterStatus = "disabled for playground"; return }
        let path = SupportPaths.bin.appendingPathComponent("agent-hud-registry").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            state.reporterStatus = "missing reporter"
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
        let errors = Pipe()
        p.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let message = String(decoding: data.suffix(1000), as: UTF8.self)
            Task { @MainActor in self?.state.reporterProblem = message }
        }
        p.terminationHandler = { [weak self] _ in
            // A dead reporter silently freezes local sessions; relaunch it.
            Task { @MainActor in
                guard let self, !self.terminating else { return }
                self.state.reporterStatus = "stopped; retrying"
                NSLog("AgentHUD: local registry reporter died; relaunching in 5s")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !self.terminating else { return }
                self.startLocalRegistryReporter()
            }
        }
        do {
            try p.run()
            registryReporter = p
            state.reporterStatus = "running"
        } catch {
            state.reporterStatus = "failed to start"
            NSLog("AgentHUD: failed to start registry reporter: \(String(describing: error))")
        }
    }
}

// NSApplication.delegate is unowned; keep a strong reference for the app's lifetime.
@MainActor private var delegateRef: AppDelegate?

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--unregister-login-item") {
        if let error = LoginItem.set(false) { fputs(error + "\n", stderr); exit(1) }
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegateRef = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
