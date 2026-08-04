import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var state: AppState
    let metrics: NotchWindowController.Metrics
    @State private var showContent = false

    private var topRadius: CGFloat { metrics.hasNotch ? 0 : 10 }
    private var bottomRadius: CGFloat { state.hudState.isCollapsed ? 8 : 24 }

    var body: some View {
        let sz = NotchWindowController.contentSize(for: state.hudState, metrics: metrics,
                                                   aggregate: state.aggregate, sideBars: state.sideBars)
        ZStack(alignment: .top) {
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(.black)
                .overlay(
                    NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: .black.opacity(state.hudState.isCollapsed ? 0 : 0.5), radius: 16, y: 6)
            Group {
                switch state.hudState {
                case .collapsed:
                    CollapsedStrip(state: state, metrics: metrics)
                case .peek(let content):
                    PeekView(content: content, art: state.nowPlayingArt)
                        .padding(.top, metrics.notchHeight)
                        .opacity(showContent ? 1 : 0)
                case .open:
                    OpenPanel(state: state)
                        .padding(.top, metrics.hasNotch ? metrics.notchHeight : 12)
                        .opacity(showContent ? 1 : 0)
                }
            }
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        }
        .frame(width: sz.width, height: sz.height, alignment: .top)
        .animation(state.hudState.isCollapsed ? state.animStyle.collapseAnimation : state.animStyle.animation, value: sz)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { if !state.hudState.isOpen { state.openPanel() } }
        .onChange(of: state.hudState.isCollapsed) { _, collapsed in
            if collapsed {
                // Hide instantly so the shape retracts empty and clean.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { showContent = false }
            } else {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { showContent = false }
                // Reveal as the shape settles — synced to the animation style.
                withAnimation(.easeOut(duration: 0.2).delay(state.animStyle.contentDelay)) {
                    showContent = true
                }
            }
        }
    }
}

struct NotchShape: InsettableShape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> NotchShape {
        var s = self
        s.insetAmount += amount
        return s
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        return UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        ).path(in: r)
    }
}

// MARK: - Collapsed

/// Collapsed status: either two thin vertical bars hugging the notch's left
/// and right edges (bottom stays perfectly flush), or a thin glow line under
/// the notch's bottom edge. Toggled via "Side Indicator Bars" in the menu.
private struct CollapsedStrip: View {
    @ObservedObject var state: AppState
    let metrics: NotchWindowController.Metrics
    @State private var pulse = false

    var body: some View {
        if state.aggregate != .info {
            Group {
                if state.sideBars {
                    HStack {
                        sideBar
                        Spacer()
                        sideBar
                    }
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Capsule()
                        .fill(state.aggregate.color)
                        .frame(height: 2.5)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 1)
                        .blur(radius: 0.6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            .opacity(state.aggregate == .running && pulse ? 0.3 : 0.95)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }

    private var sideBar: some View {
        Capsule()
            .fill(state.aggregate.color)
            .frame(width: 3, height: max(10, metrics.notchHeight - 12))
            .blur(radius: 0.4)
    }
}

// MARK: - Peek

private struct PeekView: View {
    let content: PeekContent
    var art: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            switch content {
            case .event(let e):
                IconBadge(symbol: e.kind.symbol, color: e.kind.color)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(e.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        StatusChip(text: e.kind.verb, color: e.kind.color)
                    }
                    Text(e.message.isEmpty ? "—" : e.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let img = e.image { Thumb(image: img, side: 54) }
            case .clipboard(let c):
                IconBadge(symbol: c.kind == .image ? "photo" : (c.kind == .file ? "doc" : "doc.on.clipboard"),
                          color: Color(white: 0.85))
                if let img = c.image { Thumb(image: img, side: 56) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("COPIED")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .kerning(0.8)
                    if !c.text.isEmpty {
                        Text(c.text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            case .music(let np):
                if let art {
                    Thumb(image: art, side: 54)
                } else {
                    IconBadge(symbol: "music.note", color: Color(red: 1, green: 0.45, blue: 0.6))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(np.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(np.artist) · \(np.app)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.6))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IconBadge: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.14)))
    }
}

private struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

private struct Thumb: View {
    let image: NSImage
    let side: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Open panel (console)

private func kFmt(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1000 { return "\(n / 1000)k" }
    return "\(n)"
}

private struct OpenPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    MetersRow(state: state)
                    sessionsColumn
                    Spacer(minLength: 8)
                    if state.musicEnabled, let np = state.nowPlaying { musicBar(np) }
                    if !state.clipboard.isEmpty { clipboardStrip }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                DetailPane(state: state)
                    .frame(width: 236)
            }
            .frame(maxHeight: .infinity)
            PulseView(state: state)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent HUD").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Text(scopeLine).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            if state.runningCount > 0 { countChip(state.runningCount, "working", .running) }
            if state.attentionCount > 0 { countChip(state.attentionCount, "needs you", .attention) }
            awakeChip
            Button { state.clearEvents() } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Clear events")
            Button { state.collapse() } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Collapse")
        }
    }

    /// Coffee-cup awake indicator: filled amber = Mac is being kept awake
    /// (manual or auto-while-agents-work). Click toggles the manual hold.
    private var awakeChip: some View {
        HStack(spacing: 4) {
            Image(systemName: state.awakeActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 10))
            Text(state.awakeActive ? (state.keepAwake ? "awake · manual" : "awake · agents") : "sleep ok")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(state.awakeActive ? Color(red: 1, green: 0.76, blue: 0.35) : .white.opacity(0.4))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(state.awakeActive ? 0.1 : 0.05)))
        .contentShape(Capsule())
        .onTapGesture { state.keepAwake.toggle() }
        .help(state.keepAwake
              ? "Keeping Mac awake indefinitely — click to release"
              : (state.awakeActive ? "Auto-awake: agents are working (click to hold indefinitely)"
                                   : "Click to keep Mac awake indefinitely"))
    }

    private var scopeLine: String {
        let n = state.remoteHostCount
        let hosts = n > 0 ? "Local + \(n) SSH host\(n > 1 ? "s" : "")" : "Local"
        return "\(hosts) · \(state.sessions.count) session\(state.sessions.count == 1 ? "" : "s")"
    }

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("SESSIONS")
            ForEach(state.sessions.prefix(7)) { s in
                SessionCard(
                    session: s,
                    selected: state.selectedSession?.id == s.id,
                    onSelect: { state.selectedSessionId = s.id },
                    onReview: { state.focusTerminal() }
                )
            }
            if state.sessions.isEmpty {
                Text("No sessions yet — they appear as agents run.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func musicBar(_ np: NowPlaying) -> some View {
        HStack(spacing: 10) {
            if let art = state.nowPlayingArt {
                Thumb(image: art, side: 34)
            } else {
                IconBadge(symbol: "music.note", color: Color(red: 1, green: 0.45, blue: 0.6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(np.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("\(np.artist) · \(np.app)")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            musicButton("backward.fill", size: 10) { state.musicControl("previous") }
            musicButton(np.playing ? "pause.fill" : "play.fill", size: 14) { state.musicControl("playpause") }
            musicButton("forward.fill", size: 10) { state.musicControl("next") }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.055)))
    }

    private func musicButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var clipboardStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("CLIPBOARD")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.clipboard.prefix(8)) { ClipChip(item: $0) }
                }
            }
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35)).kerning(0.8)
    }

    private func countChip(_ count: Int, _ label: String, _ kind: EventKind) -> some View {
        HStack(spacing: 4) {
            Circle().fill(kind.color).frame(width: 5, height: 5)
            Text("\(count) \(label)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

/// Estimated Claude usage across all connected machines, ccusage-style.
/// The 5h bar is normalized against the busiest 5h window of the past week.
private struct MetersRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.estD7 > 0 {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.1))
                        .frame(width: 26, height: 26)
                    Text("C").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                }
                VStack(spacing: 5) {
                    meter("5h", state.estH5, max(state.estPeak, state.estH5, 1))
                    meter("7d", state.estD7, max(state.estPeak * 33, state.estD7, 1))
                }
                Text("EST.")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                    .kerning(0.6)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
            .help("Estimated tokens (input + cache-write + output) from all transcripts; 5h bar is relative to your busiest 5-hour window this week")
        }
    }

    private func meter(_ label: String, _ value: Int, _ denom: Int) -> some View {
        HStack(spacing: 7) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                .frame(width: 16, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(EventKind.running.color)
                        .frame(width: max(3, geo.size.width * min(1, Double(value) / Double(denom))))
                }
            }
            .frame(height: 4)
            Text(kFmt(value))
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct SessionCard: View {
    let session: SessionInfo
    let selected: Bool
    let onSelect: () -> Void
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(session.kind.color).frame(width: 6, height: 6)
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.1))
                    .frame(width: 25, height: 25)
                Text(providerLetter).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionDisplayName(session.sessionName, project: session.project))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if session.kind == .attention {
                Button(action: onReview) {
                    Text("Review")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(EventKind.attention.color))
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.updated, style: .relative)
                        .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.4))
                    if let f = session.ctxFraction {
                        Text("\(Int(f * 100))%")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(f > 0.8 ? EventKind.attention.color : .white.opacity(0.85))
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected
                      ? Color.white.opacity(0.12)
                      : (session.kind == .attention ? EventKind.attention.color.opacity(0.13) : Color.white.opacity(0.05)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var providerLetter: String {
        session.host == "web" ? String(session.project.prefix(1)).uppercased() : "C"
    }

    private var subtitle: String {
        let hostLabel = session.host == AppState.Host.local ? "Local" : HostAliases.display(session.host)
        if session.message.isEmpty { return hostLabel }
        return "\(String(session.message.prefix(38))) · \(hostLabel)"
    }
}

private struct DetailPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SELECTED SESSION")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35)).kerning(0.8)
            if let s = state.selectedSession {
                HStack(spacing: 6) {
                    Text(sessionDisplayName(s.sessionName, project: s.project))
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    Spacer(minLength: 4)
                    Text(s.host == AppState.Host.local ? "local" : HostAliases.display(s.host))
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                if !s.model.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                        Text(s.effort.isEmpty ? s.model : "\(s.model) · \(s.effort) effort")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                }
                if let f = s.ctxFraction {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Context").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Text("\(kFmt(s.ctxUsed)) / \(kFmt(s.effectiveCtxLimit))")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.1))
                                Capsule()
                                    .fill(f > 0.8 ? EventKind.attention.color : EventKind.running.color)
                                    .frame(width: max(4, geo.size.width * f))
                            }
                        }
                        .frame(height: 5)
                        HStack {
                            Text("\(Int(f * 100))% used").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                            Spacer()
                            Text("\(kFmt(max(0, s.effectiveCtxLimit - s.ctxUsed))) remaining")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                if s.lastIn > 0 || s.lastOut > 0 {
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                            Text(kFmt(s.lastIn)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Output").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                            Text(kFmt(s.lastOut)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                }
                Divider().overlay(.white.opacity(0.1))
                HStack(spacing: 5) {
                    Circle().fill(session: s)
                    Text(s.kind.verb).font(.system(size: 10, weight: .medium)).foregroundStyle(s.kind.color)
                    Spacer()
                    Text(s.updated, style: .relative).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }
                if !s.message.isEmpty {
                    Text(s.message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(3)
                }
            } else {
                Text("No session selected.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
    }
}

private extension Circle {
    func fill(session s: SessionInfo) -> some View {
        fill(s.kind.color).frame(width: 5, height: 5)
    }
}

private struct PulseView: View {
    @ObservedObject var state: AppState

    var body: some View {
        let rows = Array(state.sessions.prefix(3))
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("AGENT PULSE · LAST 90M")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35)).kerning(0.8)
                    Spacer()
                    legendDot(EventKind.running.color, "working")
                    legendDot(EventKind.attention.color, "waiting")
                }
                ForEach(rows) { s in
                    HStack(spacing: 8) {
                        Text(sessionDisplayName(s.sessionName, project: s.project))
                            .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.5))
                            .frame(width: 82, alignment: .leading).lineLimit(1)
                        HStack(spacing: 2) {
                            ForEach(0..<48, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(bucketColor(state.pulse[s.id], i))
                                    .frame(height: 5)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bucketColor(_ buf: [Int]?, _ i: Int) -> Color {
        let v = (buf?.indices.contains(i) == true) ? buf![i] : 0
        switch v {
        case 2: return EventKind.attention.color
        case 1: return EventKind.running.color
        default: return .white.opacity(0.08)
        }
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 5)
            Text(label).font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

private struct ClipChip: View {
    let item: ClipboardItem

    var body: some View {
        Group {
            if let img = item.image {
                Thumb(image: img, side: 40)
            } else {
                Text(item.text)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: 150, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            }
        }
        .onTapGesture { copyBack() }
        .help("Click to copy again")
    }

    private func copyBack() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let img = item.image {
            pb.writeObjects([img])
        } else {
            pb.setString(item.text, forType: .string)
        }
    }
}

