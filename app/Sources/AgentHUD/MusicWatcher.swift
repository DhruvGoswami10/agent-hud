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

    /// One poll at a time. osascript blocks while the Automation consent
    /// prompt is up (or while a player hangs), and the 3s timer used to keep
    /// launching more — dozens of stuck processes, each pinning a GCD thread,
    /// all firing at once the moment you clicked Allow.
    private var polling = false

    fileprivate func tick() {
        guard state.musicEnabled else {
            state.composeNowPlaying(native: nil)
            return
        }
        guard !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let np = Self.poll()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MusicRegistry.shared?.polling = false
                    MusicRegistry.shared?.state.composeNowPlaying(native: np)
                }
            }
        }
    }

    /// The only player verbs that may ever reach osascript, and the only apps
    /// they may be aimed at. A command string can arrive from POST
    /// /music/commands — i.e. from anything that can reach the listener —
    /// and it used to be interpolated into the script unchecked, so
    /// "pause\ndo shell script \"…\"" ran arbitrary shell as you.
    nonisolated private static let allowedVerbs: Set<String> = [
        "playpause", "play", "pause", "next track", "previous track",
    ]
    nonisolated private static let allowedApps: Set<String> = ["Spotify", "Music"]

    nonisolated static func control(_ cmd: String, app: String) {
        guard allowedVerbs.contains(cmd), allowedApps.contains(app) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runOSA("tell application \"\(app)\" to \(cmd)")
        }
    }

    /// ASCII unit separator. A literal "|" used to be the field delimiter, so
    /// a track called "Wolf|Sheep" shifted every field along — title cut at
    /// the pipe, artist showing the remainder, artwork URL never loading.
    nonisolated private static let sep = "\u{1F}"

    private nonisolated static func poll() -> NowPlaying? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if running.contains("com.spotify.client") {
            let out = runOSA("""
            tell application "Spotify"
                set sep to character id 31
                set s to player state as string
                try
                    return s & sep & name of current track & sep & artist of current track & sep & artwork url of current track
                on error
                    return s & sep & sep & sep
                end try
            end tell
            """)
            if let p = out?.components(separatedBy: sep), p.count >= 4, !p[1].isEmpty {
                return NowPlaying(app: "Spotify", title: p[1], artist: p[2], playing: p[0] == "playing", artworkURL: p[3])
            }
        }
        if running.contains("com.apple.Music") {
            let out = runOSA("""
            tell application "Music"
                set sep to character id 31
                set s to player state as string
                try
                    return s & sep & name of current track & sep & artist of current track
                on error
                    return s & sep & sep
                end try
            end tell
            """)
            if let p = out?.components(separatedBy: sep), p.count >= 3, !p[1].isEmpty {
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
        // A wedged player (or a pending consent dialog) must not block this
        // thread forever — AppleScript's own timeout is ~2 minutes.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
private enum MusicRegistry {
    weak static var shared: MusicWatcher?
}
