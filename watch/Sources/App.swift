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
            SessionsView().tag(0)     // the main screen; tap a row for its dial
            WrappedView().tag(1)      // what the week actually looked like
            LimitsView().tag(2)       // what's left in the tank
        }
        .tabViewStyle(.verticalPage)
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
                            TickDial(fraction: s.kind == "running"
                                        ? s.minuteFraction(plus: hub.sinceSync) : 1,
                                     color: s.color, size: 26, ticks: 12) { EmptyView() }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 4) {
                                    Text(s.kind == "running"
                                         ? s.elapsed(plus: hub.sinceSync) : s.since)
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                    Text("·")
                                    Text(s.tokensShort).monospacedDigit()
                                    Text("·")
                                    Text(s.where_).lineLimit(1)
                                }
                                .font(.system(size: 9.5, design: .rounded))
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

// MARK: - wrapped — what the week actually looked like

/// The one screen that isn't about right now. Everything here is measured,
/// not estimated: token counts come from the transcripts, the peak hour from
/// the same hourly buckets that draw the burn strip on the Mac.
struct WrappedView: View {
    @EnvironmentObject var hub: Hub

    var body: some View {
        let w = hub.snap.wrapped
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("LAST 7 DAYS")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.7)
                    .foregroundStyle(.secondary)

                stat(Wrapped.short(w.week), "tokens burned", Color(red: 0.35, green: 0.65, blue: 1.0))

                HStack(spacing: 8) {
                    small(Wrapped.short(w.day), "today")
                    small("\(w.turns)", "turns")
                }
                HStack(spacing: 8) {
                    small("\(w.files)", "files")
                    small("\(w.hosts)", w.hosts == 1 ? "machine" : "machines")
                }
                if w.added + w.removed > 0 {
                    HStack(spacing: 6) {
                        Text("+\(w.added)")
                            .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
                        Text("−\(w.removed)")
                            .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.45))
                        Text("lines").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                if !w.peakHour.isEmpty {
                    Text("busiest at \(w.peakHour) · \(Wrapped.short(w.peakTokens))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 5)
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func small(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
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
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.snappy, value: l.percent)
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
