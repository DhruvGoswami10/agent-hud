import SwiftUI

@main
struct AgentHUDWatchApp: App {
    @StateObject private var hub = Hub()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(hub).onAppear { hub.start() }
        }
    }
}

/// Three pages, swipe between them: the glance, the sessions, the limits.
/// A wrist gets one idea per screen.
struct RootView: View {
    @EnvironmentObject var hub: Hub
    // `-startTab 1` on launch opens straight to a page — handy for grabbing
    // screenshots of the simulator without a crown to turn.
    @State private var tab = UserDefaults.standard.integer(forKey: "startTab")

    var body: some View {
        TabView(selection: $tab) {
            NowView().tag(0)          // the one that's working
            SessionsView().tag(1)     // everything else
            LimitsView().tag(2)       // what's left in the tank
        }
        .tabViewStyle(.verticalPage)
    }
}

// MARK: - now — one session, the whole screen

/// Screen one is a single answer: what is running, and for how long. The
/// clock ticks every second (the Mac only reports every three), because a
/// timer that jumps in threes doesn't read as live.
struct NowView: View {
    @EnvironmentObject var hub: Hub

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let s = hub.snap.focus {
                    SessionRing(session: s, offset: hub.sinceSync)
                        .padding(.top, 2)
                    Text(s.name)
                        .font(.system(size: 15, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(hub.snap.running > 1
                         ? "+\(hub.snap.running - 1) more working"
                         : s.host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if s.files > 0 {
                        HStack(spacing: 7) {
                            Text("\(s.files) files").font(.system(size: 11, weight: .semibold))
                            Text("+\(s.added)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
                            Text("−\(s.removed)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.45))
                        }
                        .padding(.vertical, 5).padding(.horizontal, 9)
                        .background(Capsule().fill(.white.opacity(0.09)))
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: hub.reachable ? "moon.zzz.fill" : "wifi.slash")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text(hub.reachable ? "nothing running" : "can't reach the Mac")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 34)
                }
                if hub.snap.awake {
                    Label("awake · \(hub.snap.awakeReason)", systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 1, green: 0.76, blue: 0.35))
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - sessions

struct SessionsView: View {
    @EnvironmentObject var hub: Hub

    // `-openFirst 1` pushes straight into the first session — again, so the
    // simulator can be screenshotted without a finger.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if hub.snap.sessions.isEmpty {
                    Text(hub.reachable ? "no sessions" : "can't reach the Mac")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(hub.snap.sessions) { s in
                    NavigationLink(destination: SessionDetail(session: s)) {
                        HStack(spacing: 9) {
                            // A small ring per row: the same idea as the big
                            // one, so the list reads as a set of dials.
                            ZStack {
                                Circle().stroke(.white.opacity(0.14), lineWidth: 3)
                                Circle()
                                    .trim(from: 0, to: max(0.02, Double(s.ctx) / 100))
                                    .stroke(s.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                if s.kind == "attention" {
                                    Circle().fill(s.color).frame(width: 6, height: 6)
                                }
                            }
                            .frame(width: 26, height: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                Text(s.kind == "running" ? "working · \(s.elapsed(plus: hub.sinceSync))" : "\(s.kind) · \(s.since)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(s.kind == "attention" ? s.color.opacity(0.22) : Color.white.opacity(0.07))
                    )
                }
            }
            .navigationTitle(hub.snap.headline)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WatchSession.self) { SessionDetail(session: $0) }
            .onChange(of: hub.snap.sessions.count) { _, n in
                if UserDefaults.standard.bool(forKey: "openFirst"),
                   path.isEmpty, let first = hub.snap.sessions.first {
                    path.append(first)
                }
            }
        }
    }
}

// MARK: - limits

struct LimitsView: View {
    @EnvironmentObject var hub: Hub

    var body: some View {
        List {
            if hub.snap.limits.isEmpty {
                Text("no live limits").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(hub.snap.limits) { l in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(l.label).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(Int(l.percent.rounded()))%")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(l.color)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.14))
                            Capsule().fill(l.color)
                                .frame(width: max(3, geo.size.width * min(1, l.percent / 100)))
                        }
                    }
                    .frame(height: 5)
                    if !l.resets.isEmpty {
                        Text(l.resets).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Limits")
    }
}
