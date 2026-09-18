import AppKit

/// Navigation metadata, never executable commands supplied by an adapter.
struct SessionFocus: Equatable {
    var workspace = ""
    var surface = ""
    var url = ""
    var cwd = ""
    var application = ""

    init(json: [String: Any] = [:], cwd: String = "") {
        self.cwd = cwd.hasPrefix("/") ? cwd : ""
        workspace = Self.uuid(json["workspace"] as? String)
        surface = Self.uuid(json["surface"] as? String)
        if let raw = json["url"] as? String, let u = URL(string: raw), u.scheme == "https",
           ["chatgpt.com", "chat.openai.com", "claude.ai"].contains(u.host ?? ""), u.user == nil {
            url = u.absoluteString
        }
        let app = json["application"] as? String ?? ""
        if Self.applications.contains(app) { application = app }
    }

    private static func uuid(_ raw: String?) -> String {
        guard let raw, UUID(uuidString: raw) != nil else { return "" }
        return raw
    }

    static let applications = ["com.cmuxterm.app", "com.googlecode.iterm2", "com.apple.Terminal",
                               "com.todesktop.230313mzl4w4u92"]
    var hasLocation: Bool { !workspace.isEmpty || !url.isEmpty || !cwd.isEmpty || !application.isEmpty }

    func actionTitle(app: String) -> String {
        if !url.isEmpty { return "Open conversation" }
        if !workspace.isEmpty { return "Open pane" }
        if app == "cursor", !cwd.isEmpty { return "Open workspace" }
        return "Open app"
    }

    @MainActor
    func open(app: String, local: Bool) {
        if !url.isEmpty, let u = URL(string: url) { NSWorkspace.shared.open(u); return }
        if local, !workspace.isEmpty {
            let tool = "/Applications/cmux.app/Contents/Resources/bin/cmux"
            if FileManager.default.isExecutableFile(atPath: tool) {
                let commands = [["select-workspace", "--workspace", workspace]] +
                    (surface.isEmpty ? [] : [["focus-panel", "--panel", surface, "--workspace", workspace]])
                DispatchQueue.global(qos: .userInitiated).async {
                    for args in commands {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
                        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                        do { try p.run(); p.waitUntilExit() } catch { break }
                    }
                    DispatchQueue.main.async { Self.activate("com.cmuxterm.app") }
                }
                return
            }
        }
        if local, app == "cursor", !cwd.isEmpty,
           let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: editor,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if !application.isEmpty { Self.activate(application); return }
        let candidates = app == "cursor" ? ["com.todesktop.230313mzl4w4u92"] : Array(Self.applications.prefix(3))
        if let bid = candidates.first(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
            Self.activate(bid)
        }
    }

    @MainActor private static func activate(_ identifier: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.activate(options: [.activateAllWindows])
    }
}
