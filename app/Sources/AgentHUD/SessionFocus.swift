import AppKit
import Network

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
    var sshConnection = ""

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
        if let raw = json["ssh_connection"] as? String, raw.count <= 160 {
            let p = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            if p.count == 4, (IPv4Address(p[0]) != nil || IPv6Address(p[0]) != nil),
               (IPv4Address(p[2]) != nil || IPv6Address(p[2]) != nil),
               let clientPort = UInt16(p[1]), clientPort > 0,
               let serverPort = UInt16(p[3]), serverPort > 0 {
                sshConnection = p.joined(separator: " ")
            }
        }
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
        !workspace.isEmpty || !url.isEmpty || !cwd.isEmpty || !application.isEmpty || !warpURL.isEmpty || hasBrowserTab || !sshConnection.isEmpty
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
        if !newer.sshConnection.isEmpty, newer.sshConnection != sshConnection {
            result.workspace = ""; result.surface = ""; result.warpURL = ""
            result.terminalID = ""; result.tty = ""; result.application = ""
        }
        if !newer.application.isEmpty, newer.application != application {
            result.workspace = ""; result.surface = ""; result.warpURL = ""
            result.terminalID = ""; result.tty = ""
            result.url = ""; result.browserClient = ""; result.browserTab = ""
            result.sshConnection = ""
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
        if !newer.sshConnection.isEmpty { result.sshConnection = newer.sshConnection }
        return result
    }

    var actionTitle: String { "Go to session" }

    func canJumpBack(app: String, local: Bool) -> Bool {
        !workspace.isEmpty || !warpURL.isEmpty || !url.isEmpty || !sshConnection.isEmpty ||
            !application.isEmpty || (local && app == "cursor" && !cwd.isEmpty)
    }

    var cmuxURL: URL? {
        guard !workspace.isEmpty else { return nil }
        let path = "cmux://workspace/" + workspace + (surface.isEmpty ? "" : "/surface/" + surface)
        return URL(string: path)
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
        // The public navigation link works from a standalone menu-bar app.
        // Its private control socket correctly rejects non-cmux processes.
        if let target = cmuxURL {
            completion(NSWorkspace.shared.open(target) ? nil : "cmux could not open this session.")
            return
        }
        if !sshConnection.isEmpty {
            let helper = SupportPaths.bin.appendingPathComponent("hud_ssh_focus.py").path
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.resolveSSH(helper: helper, connection: sshConnection)
                DispatchQueue.main.async {
                    if let json = result["focus"] as? [String: Any] {
                        var resolved = SessionFocus(json: json)
                        resolved.sshConnection = ""
                        resolved.open(app: app, local: true, completion: completion)
                    } else {
                        completion(result["error"] as? String ?? "Could not find this session's connected terminal.")
                    }
                }
            }
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
        completion("This session has no linked terminal or browser window yet.")
    }

    private static func resolveSSH(helper: String, connection: String) -> [String: Any] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", helper, "--resolve", connection]
        let pipe = Pipe(); process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0, data.count <= 8192 else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
