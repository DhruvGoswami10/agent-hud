import Foundation
import SwiftUI

/// One line from the Mac's GET /watch.
struct WatchSession: Decodable, Identifiable, Hashable {
    let name: String
    let host: String
    let kind: String
    let app: String
    var model: String = ""
    let message: String
    let ago: Int
    var ctx: Int = 0
    var files: Int = 0
    var added: Int = 0
    var removed: Int = 0

    var id: String { "\(host)#\(name)" }

    var color: Color {
        switch kind {
        case "running":   return Color(red: 0.35, green: 0.65, blue: 1.0)
        case "attention": return Color(red: 1.0, green: 0.62, blue: 0.2)
        case "done":      return Color(red: 0.4, green: 0.85, blue: 0.5)
        default:          return .gray
        }
    }

    /// Elapsed, as a wrist wants it: m:ss under an hour, then h:mm.
    func elapsed(plus offset: Int = 0) -> String {
        let t = ago + offset
        if t < 3600 { return String(format: "%d:%02d", t / 60, t % 60) }
        return String(format: "%dh%02d", t / 3600, (t % 3600) / 60)
    }

    /// How far into the current minute the run is — the dial's fill, so the
    /// marks sweep like a second hand and wrap on the minute.
    func minuteFraction(plus offset: Int = 0) -> Double {
        Double((ago + offset) % 60) / 60.0
    }

    var since: String {
        if ago < 60 { return "\(ago)s" }
        if ago < 3600 { return "\(ago / 60)m" }
        return "\(ago / 3600)h"
    }
}

struct WatchLimit: Decodable, Identifiable {
    let label: String
    let percent: Double
    let plan: String
    let resets: String

    var id: String { label }

    /// Amber past three-quarters, red when it's effectively gone — the whole
    /// point of putting this on a wrist is deciding whether to keep going.
    var color: Color {
        if percent >= 95 { return Color(red: 1, green: 0.42, blue: 0.35) }
        if percent >= 75 { return Color(red: 1, green: 0.76, blue: 0.35) }
        return Color(red: 0.35, green: 0.65, blue: 1.0)
    }
}

struct WatchSnapshot: Decodable {
    var running = 0
    var attention = 0
    var awake = false
    var awakeReason = ""
    var sessions: [WatchSession] = []
    var limits: [WatchLimit] = []

    /// What the face should be doing: attention outranks work, work outranks rest.
    var mood: Mood {
        if attention > 0 { return .needsYou }
        if running > 0 { return .working }
        return .resting
    }

    /// The one that deserves the whole screen: anything wanting you first,
    /// then whatever is actually working, then the most recent thing.
    var focus: WatchSession? {
        sessions.first { $0.kind == "attention" }
            ?? sessions.first { $0.kind == "running" }
            ?? sessions.first
    }

    var headline: String {
        if attention > 0 { return "\(attention) need\(attention == 1 ? "s" : "") you" }
        if running > 0 { return "\(running) working" }
        return sessions.isEmpty ? "nothing running" : "all quiet"
    }
}

enum Mood {
    case working, needsYou, resting

    var color: Color {
        switch self {
        case .working:  return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .needsYou: return Color(red: 1.0, green: 0.76, blue: 0.35)
        case .resting:  return Color(red: 0.5, green: 0.62, blue: 0.79)
        }
    }
}

/// Polls the Mac. In the simulator 127.0.0.1 is the Mac itself, because the
/// simulator shares the host's network stack; on a real watch this has to be
/// the Mac's LAN address instead (see the README).
@MainActor
final class Hub: ObservableObject {
    @Published private(set) var snap = WatchSnapshot()
    @Published private(set) var reachable = false
    /// Seconds since the last successful poll. The Mac sends whole-second
    /// ages every 3s; adding this makes the clock tick like a clock.
    @Published private(set) var sinceSync = 0
    @Published var host = UserDefaults.standard.string(forKey: "hudHost") ?? "127.0.0.1"

    private var timer: Timer?
    private var second: Timer?

    func start() {
        tick()
        // The first poll is the world as it already is, not news.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.started = true }
        let t = Timer(timeInterval: 3, repeats: true) { _ in Task { @MainActor in self.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let s = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in self.sinceSync += 1 }
        }
        RunLoop.main.add(s, forMode: .common)
        second = s
    }

    /// Buzz only on genuine transitions, and only once each — a poller that
    /// taps your wrist every three seconds is worse than no watch app.
    private func announce(previous: WatchSnapshot, next: WatchSnapshot) {
        guard started else { return }
        let was = Dictionary(previous.sessions.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        for s in next.sessions {
            let before = was[s.id]
            guard before != s.kind else { continue }
            switch s.kind {
            case "attention": Haptics.needsYou()
            case "done":
                // Only for something we actually watched start.
                if before == "running" {
                    s.message.contains("error") ? Haptics.failed() : Haptics.done()
                }
            case "running": if before != nil { Haptics.started() }
            default: break
            }
        }
    }

    private var started = false

    func tick() {
        guard let url = URL(string: "http://\(host):48085/watch") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let s = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else {
                Task { @MainActor in self.reachable = false }
                return
            }
            Task { @MainActor in
                self.announce(previous: self.snap, next: s)
                self.snap = s
                self.sinceSync = 0
                self.reachable = true
            }
        }.resume()
    }
}
