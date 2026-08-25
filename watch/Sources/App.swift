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

// MARK: - now — one dial, no scrolling

/// Screen one answers one question and stops. Everything that used to sit
/// under here (files changed, the message) moved to the detail view, because
/// a wrist screen you have to scroll is a screen you didn't design.
struct NowView: View {
    @EnvironmentObject var hub: Hub

    var body: some View {
        VStack(spacing: 6) {
            if let s = hub.snap.focus {
                SessionRing(session: s, offset: hub.sinceSync)
                Text(s.name)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hub.snap.running > 1 ? "+\(hub.snap.running - 1) more · \(s.host)"
                                          : (hub.snap.awake ? "awake · \(hub.snap.awakeReason)" : s.host))
                    .font(.system(size: 10))
                    .foregroundStyle(hub.snap.awake && hub.snap.running <= 1
                                     ? Color(red: 1, green: 0.76, blue: 0.35) : .secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: hub.reachable ? "moon.zzz.fill" : "wifi.slash")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(hub.reachable ? "nothing running" : "no Mac")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - sessions

struct SessionsView: View {
    @EnvironmentObject var hub: Hub
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if hub.snap.sessions.isEmpty {
                    Text(hub.reachable ? "no sessions" : "can't reach the Mac")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(hub.snap.sessions.prefix(5), id: \.id) { s in
                    NavigationLink(value: s) {
                        HStack(spacing: 8) {
                            // the same instrument, shrunk to a bullet
                            TickDial(fraction: min(1, Double(s.ctx) / 100),
                                     color: s.color, size: 26, ticks: 12,
                                     spinner: s.kind == "running") { EmptyView() }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Text(s.kind == "running"
                                     ? s.elapsed(plus: hub.sinceSync) : s.since)
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(s.kind == "attention" ? s.color.opacity(0.22)
                                                        : Color.white.opacity(0.06)))
                }
            }
            .listStyle(.carousel)
            .navigationTitle(hub.snap.headline)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WatchSession.self) { SessionDetail(session: $0) }
        }
    }
}

// MARK: - limits

struct LimitsView: View {
    @EnvironmentObject var hub: Hub

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if hub.snap.limits.isEmpty {
                Text("no live limits").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(hub.snap.limits.first?.plan ?? "")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(hub.snap.limits) { l in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(l.label).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(Int(l.percent.rounded()))%")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(l.color)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.14))
                                Capsule().fill(l.color)
                                    .frame(width: max(3, geo.size.width * min(1, l.percent / 100)))
                            }
                        }
                        .frame(height: 4)
                        Text(l.resets).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
