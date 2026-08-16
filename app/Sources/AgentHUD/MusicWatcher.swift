import AppKit

struct NowPlaying: Equatable {
    var app: String        // "Spotify", "Music", or a web source like "YouTube"
    var title: String
    var artist: String
    var playing: Bool
    var artworkURL: String // Spotify exposes one; Music doesn't
    var tab: String = ""   // browser-tab identity, so commands reach the right player

    var isWeb: Bool { app != "Spotify" && app != "Music" }
}

/// Polls Spotify / Apple Music via AppleScript (no private MediaRemote API —
/// Apple locked that down in recent macOS). First control triggers the
/// system's Automation permission prompt once per app.
@MainActor
final class MusicWatcher {
    private var timer: Timer?
    private let state: AppState

    init(state: AppState) { self.state = state }

    func start() {
        let t = Timer(timeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in MusicRegistry.shared?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        MusicRegistry.shared = self
        tick()
    }

    fileprivate func tick() {
        guard state.musicEnabled else {
            state.composeNowPlaying(native: nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let np = Self.poll()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MusicRegistry.shared?.state.composeNowPlaying(native: np) }
            }
        }
    }

    nonisolated static func control(_ cmd: String, app: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runOSA("tell application \"\(app)\" to \(cmd)")
        }
    }

    private nonisolated static func poll() -> NowPlaying? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if running.contains("com.spotify.client") {
            let out = runOSA("""
            tell application "Spotify"
                set s to player state as string
                try
                    return s & "|" & name of current track & "|" & artist of current track & "|" & artwork url of current track
                on error
                    return s & "|||"
                end try
            end tell
            """)
            if let p = out?.components(separatedBy: "|"), p.count >= 4, !p[1].isEmpty {
                return NowPlaying(app: "Spotify", title: p[1], artist: p[2], playing: p[0] == "playing", artworkURL: p[3])
            }
        }
        if running.contains("com.apple.Music") {
            let out = runOSA("""
            tell application "Music"
                set s to player state as string
                try
                    return s & "|" & name of current track & "|" & artist of current track
                on error
                    return s & "||"
                end try
            end tell
            """)
            if let p = out?.components(separatedBy: "|"), p.count >= 3, !p[1].isEmpty {
                return NowPlaying(app: "Music", title: p[1], artist: p[2], playing: p[0] == "playing", artworkURL: "")
            }
        }
        return nil
    }

    private nonisolated static func runOSA(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
private enum MusicRegistry {
    weak static var shared: MusicWatcher?
}
