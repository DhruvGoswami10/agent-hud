import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var server: EventServer!
    private var clipboardWatcher: ClipboardWatcher!
    private var musicWatcher: MusicWatcher!
    private var registryReporter: Process?
    private var aliasTimer: Timer?
    private var notchController: NotchWindowController!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state
        notchController = NotchWindowController(state: state)
        statusItemController = StatusItemController(state: state)
        Notifier.shared.setup()
        clipboardWatcher = ClipboardWatcher { item in state.clipboardChanged(item) }
        clipboardWatcher.start()
        musicWatcher = MusicWatcher(state: state)
        musicWatcher.start()
        startLocalRegistryReporter()
        HostAliases.reload()
        aliasTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in HostAliases.reload() }
        }
        server = EventServer(port: 48085, onEvent: { event in
            Task { @MainActor in state.apply(event) }
        }, onSessions: { host, entries, usage, hours in
            Task { @MainActor in state.syncRegistry(host: host, entries: entries, usage: usage, hours: hours) }
        }, onMusicState: { np in
            Task { @MainActor in state.setWebNowPlaying(np) }
        })
        state.webMusicQueue = server.musicCommands
        do {
            try server.start()
        } catch {
            NSLog("AgentHUD: failed to start event server on 48085: \(String(describing: error))")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        registryReporter?.terminate()
        server?.stop()
    }

    /// The same python reporter used on remote boxes also feeds local sessions —
    /// it resolves real session names from transcript custom-title records,
    /// which the live registry loses on resume.
    private func startLocalRegistryReporter() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "[a]gent-hud-registry"]
        try? kill.run()
        kill.waitUntilExit()

        let path = ("~/agent-hud/bin/agent-hud-registry" as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            NSLog("AgentHUD: registry reporter missing at \(path)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
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
