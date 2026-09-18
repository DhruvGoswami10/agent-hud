import AppKit

/// Navigation metadata, never executable commands supplied by an adapter.
struct SessionFocus: Equatable, Sendable {
    var workspace = ""
    var surface = ""
    var url = ""
    var cwd = ""
    var application = ""
    var warpURL = ""
    var terminalID = ""
    var tty = ""
    var browserClient = ""
    var browserTab = ""

    init(json: [String: Any] = [:], cwd: String = "") {
        self.cwd = cwd.hasPrefix("/") ? cwd : ""
        workspace = Self.uuid(json["workspace"] as? String)
        surface = Self.uuid(json["surface"] as? String)
        if let raw = json["url"] as? String, let u = URL(string: raw), u.scheme == "https",
           ["chatgpt.com", "chat.openai.com", "claude.ai"].contains(u.host ?? ""),
           u.user == nil, u.password == nil, u.port == nil {
            url = u.absoluteString
        }
        let app = json["application"] as? String ?? ""
        if Self.applications.contains(app) { application = app }
        if let raw = json["warp_url"] as? String, Self.isWarpSessionURL(raw) { warpURL = raw }
        terminalID = Self.uuid(json["terminal_id"] as? String)
        if let raw = json["tty"] as? String,
           raw.range(of: #"^/dev/(ttys?\d+|pts/\d+)$"#, options: .regularExpression) != nil { tty = raw }
        browserClient = Self.uuid(json["browser_client"] as? String)
        if let raw = json["browser_tab"] as? String,
           raw.range(of: #"^\d{1,12}$"#, options: .regularExpression) != nil { browserTab = raw }
    }

    private static func uuid(_ raw: String?) -> String {
        guard let raw, UUID(uuidString: raw) != nil else { return "" }
        return raw
    }

    static let applications = ["com.cmuxterm.app", "com.googlecode.iterm2", "com.apple.Terminal",
        "com.todesktop.230313mzl4w4u92", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty", "com.github.wez.wezterm", "com.microsoft.VSCode",
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"]
    var hasBrowserTab: Bool { !url.isEmpty && !browserClient.isEmpty && !browserTab.isEmpty }
    var hasLocation: Bool {
        !workspace.isEmpty || !url.isEmpty || !cwd.isEmpty || !application.isEmpty || !warpURL.isEmpty || hasBrowserTab
    }

    static func isWarpSessionURL(_ raw: String) -> Bool {
        guard let u = URLComponents(string: raw), ["warp", "warppreview", "warposs"].contains(u.scheme ?? ""),
              u.host == "session", u.user == nil, u.password == nil, u.port == nil,
              u.query == nil, u.fragment == nil else { return false }
        let id = String(u.path.dropFirst())
        return u.path.hasPrefix("/") && (UUID(uuidString: id) != nil ||
            id.range(of: #"^[0-9a-fA-F]{32}$"#, options: .regularExpression) != nil)
    }

    /// Reporters often know only the folder. They must not erase a location
    /// supplied by the agent's hook, or every heartbeat breaks jump-back.
    func merging(_ newer: SessionFocus) -> SessionFocus {
        var result = self
        if !newer.application.isEmpty, newer.application != application {
            result.workspace = ""; result.surface = ""; result.warpURL = ""
            result.terminalID = ""; result.tty = ""
            result.url = ""; result.browserClient = ""; result.browserTab = ""
        }
        if !newer.workspace.isEmpty, newer.workspace != workspace { result.surface = "" }
        if !newer.browserClient.isEmpty, newer.browserClient != browserClient { result.browserTab = "" }
        if !newer.terminalID.isEmpty, newer.terminalID != terminalID { result.tty = "" }
        if !newer.workspace.isEmpty { result.workspace = newer.workspace }
        if !newer.surface.isEmpty { result.surface = newer.surface }
        if !newer.url.isEmpty { result.url = newer.url }
        if !newer.cwd.isEmpty { result.cwd = newer.cwd }
        if !newer.application.isEmpty { result.application = newer.application }
        if !newer.warpURL.isEmpty { result.warpURL = newer.warpURL }
        if !newer.terminalID.isEmpty { result.terminalID = newer.terminalID }
        if !newer.tty.isEmpty { result.tty = newer.tty }
        if !newer.browserClient.isEmpty { result.browserClient = newer.browserClient }
        if !newer.browserTab.isEmpty { result.browserTab = newer.browserTab }
        return result
    }

    func actionTitle(app: String, local: Bool = true) -> String {
        if hasBrowserTab || !warpURL.isEmpty { return "Open session" }
        if !url.isEmpty { return "Open conversation" }
        if !workspace.isEmpty || (local && (!terminalID.isEmpty || !tty.isEmpty)) { return "Open session" }
        if local, app == "cursor", !cwd.isEmpty { return "Open workspace" }
        if application.hasPrefix("dev.warp.") { return "Open Warp" }
        return application.isEmpty ? "Location unavailable" : "Open app"
    }

    @MainActor
    func open(app: String, local: Bool, completion: @escaping @MainActor (String?) -> Void) {
        if !warpURL.isEmpty, let u = URL(string: warpURL) {
            completion(NSWorkspace.shared.open(u) ? nil : "Warp could not open this session.")
            return
        }
        if !url.isEmpty, let u = URL(string: url) {
            if let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application) {
                NSWorkspace.shared.open([u], withApplicationAt: browser, configuration: .init()) { _, error in
                    Task { @MainActor in completion(error?.localizedDescription) }
                }
            } else { completion(NSWorkspace.shared.open(u) ? nil : "The conversation could not be opened.") }
            return
        }
        // UUIDs identify a local cmux pane even when its agent runs over SSH.
        if !workspace.isEmpty {
            let tool = "/Applications/cmux.app/Contents/Resources/bin/cmux"
            if FileManager.default.isExecutableFile(atPath: tool) {
                let commands = [["select-workspace", "--workspace", workspace]] +
                    (surface.isEmpty ? [] : [["focus-panel", "--panel", surface, "--workspace", workspace]])
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = commands.allSatisfy { Self.run(tool, arguments: $0) }
                    DispatchQueue.main.async {
                        if ok { Self.activate("com.cmuxterm.app") }
                        completion(ok ? nil : "This cmux pane is no longer available.")
                    }
                }
                return
            }
            completion("cmux is not available on this Mac.")
            return
        }
        if local, ["com.apple.Terminal", "com.googlecode.iterm2"].contains(application),
           !tty.isEmpty || !terminalID.isEmpty {
            let script = application == "com.apple.Terminal" ? Self.terminalScript : Self.itermScript
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = Self.run("/usr/bin/osascript", arguments: ["-e", script, tty, terminalID])
                DispatchQueue.main.async {
                    completion(ok ? nil : "Could not select this terminal session. It may have closed, or need macOS Automation access.")
                }
            }
            return
        }
        if local, app == "cursor", !cwd.isEmpty,
           let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: editor,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                Task { @MainActor in completion(error?.localizedDescription) }
            }
            return
        }
        if !application.isEmpty, let target = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application) {
            NSWorkspace.shared.openApplication(at: target, configuration: .init()) { _, error in
                Task { @MainActor in completion(error?.localizedDescription) }
            }
            return
        }
        completion("This session has not reported its location yet. Its next agent turn can capture it.")
    }

    private static func run(_ tool: String, arguments: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        p.waitUntilExit(); timeout.cancel()
        return p.terminationStatus == 0
    }

    @MainActor private static func activate(_ identifier: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.activate(options: [.activateAllWindows])
    }

    // Arguments stay data. Never interpolate a path, identifier, or command
    // received from a hook into AppleScript source.
    private static let terminalScript = """
    on run argv
        set wantedTTY to item 1 of argv
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if wantedTTY is not "" and tty of t is wantedTTY then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        error "Session not found"
    end run
    """

    private static let itermScript = """
    on run argv
        set wantedTTY to item 1 of argv
        set wantedID to item 2 of argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (wantedID is not "" and unique id of s is wantedID) or (wantedID is "" and wantedTTY is not "" and tty of s is wantedTTY) then
                            select s
                            select t
                            select w
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        error "Session not found"
    end run
    """
}
