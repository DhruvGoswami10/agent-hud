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
                                                   aggregate: state.aggregate, sideBars: state.sideBars,
                                                   peekPreview: state.peekPreviewSize)
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
                    PeekView(content: content, art: state.nowPlayingArt,
                             artColor: state.nowPlayingArtColor.map(Color.init(nsColor:)))
                        .padding(.top, metrics.notchHeight)
                        .opacity(showContent ? 1 : 0)
                case .open:
                    OpenPanel(state: state)
                        .padding(.top, metrics.hasNotch ? metrics.notchHeight : 12)
                        .opacity(showContent ? 1 : 0)
                }
            }
            // Fill the whole shape before clipping — otherwise the clip hugs
            // the content's own bounds and glows render as a second card.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        }
        .frame(width: sz.width, height: sz.height, alignment: .top)
        .animation(state.hudState.isCollapsed ? state.animStyle.collapseAnimation : state.animStyle.animation, value: sz)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { if !state.hudState.isOpen { state.openPanel() } }
        .onChange(of: state.hudState.stage) { _, stage in
            // Every stage change resizes the shape; content must never be
            // visible mid-growth (it reflows and overlaps). Hide instantly,
            // reveal as the shape settles — including peek → open on hover.
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { showContent = false }
            if stage != 0 {
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
    var artColor: Color?

    /// Dynamic-Island-style ambient glow color for this peek.
    private var glow: Color {
        switch content {
        case .event(let e): return e.kind.color
        case .clipboard: return Color(white: 0.75)
        case .music: return artColor ?? Color(red: 1, green: 0.45, blue: 0.6)
        }
    }

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
                if let img = c.image {
                    // Image copies are image-forward: the preview is the hero.
                    PreviewThumb(image: img)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("COPIED")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .kerning(0.8)
                        if !c.text.isEmpty {
                            Text(c.text)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                } else {
                    IconBadge(symbol: c.kind == .file ? "doc" : "doc.on.clipboard",
                              color: Color(white: 0.85))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("COPIED")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .kerning(0.8)
                        if !c.text.isEmpty {
                            Text(c.text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        }
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
        .background(alignment: .leading) {
            Circle()
                .fill(glow.opacity(0.45))
                .frame(width: 110, height: 110)
                .blur(radius: 42)
                .offset(x: -14)
        }
        .background(alignment: .trailing) {
            Circle()
                .fill(glow.opacity(0.2))
                .frame(width: 90, height: 90)
                .blur(radius: 46)
                .offset(x: 18)
        }
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

/// Aspect-true preview for screenshots and arbitrary images — sized by the
/// same fit math that shapes the island, so the panel morphs to the snip.
private struct PreviewThumb: View {
    let image: NSImage

    var body: some View {
        let s = hudFitSize(image.size, in: CGSize(width: 210, height: 130))
        Image(nsImage: image)
            .resizable()
            .frame(width: s.width, height: s.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Open panel (console)

/// Soft gradient surface for cards — flat fills read cheap, gradients read DI.
private let hudCard = LinearGradient(
    colors: [Color.white.opacity(0.085), Color.white.opacity(0.04)],
    startPoint: .top, endPoint: .bottom
)

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
            BurnStrip(state: state)
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
            if state.muted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(EventKind.attention.color)
                    .help("Notifications muted — click the sparkle menu to unmute")
            }
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
            Text(state.awakeActive ? "awake · \(state.awakeReason)" : "sleep ok")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(state.awakeActive ? Color(red: 1, green: 0.76, blue: 0.35) : .white.opacity(0.4))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(state.awakeActive ? 0.1 : 0.05)))
        .contentShape(Capsule())
        .onTapGesture { state.keepAwake.toggle() }
        .help(state.keepAwake
              ? "Screen stays on and unlocked (grant Accessibility for the no-lock part) — click to release. Lid closed on battery still sleeps: that's macOS, not us."
              : (state.awakeActive ? "Auto-awake: \(state.awakeReason) — click to hold the screen on indefinitely"
                                   : "Click to keep the screen on and unlocked indefinitely"))
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
            // Art + titles are a button: click brings the player forward —
            // the native app, or the exact browser tab that's playing.
            Button { state.musicFocus() } label: {
                HStack(spacing: 10) {
                    if let art = state.nowPlayingArt {
                        Thumb(image: art, side: 34)
                    } else {
                        IconBadge(symbol: "music.note", color: Color(red: 1, green: 0.45, blue: 0.6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        HStack(spacing: 4) {
                            sourceMark(np, size: 9)
                            Text(np.artist.isEmpty ? np.app : "\(np.artist) · \(np.app)")
                                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the player")
            Spacer(minLength: 8)
            musicButton("backward.fill", size: 10) { state.musicControl("previous") }
            musicButton(np.playing ? "pause.fill" : "play.fill", size: 14) { state.musicControl("playpause") }
            musicButton("forward.fill", size: 10) { state.musicControl("next") }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hudCard))
    }

    /// Where the sound is coming from, as a glyph — YouTube's play badge,
    /// Spotify's rings, or a plain note for Apple Music.
    @ViewBuilder
    private func sourceMark(_ np: NowPlaying, size: CGFloat) -> some View {
        switch np.app {
        case "YouTube":
            SVGShape(data: BrandPaths.youtube)
                .fill(Color(red: 1.0, green: 0.23, blue: 0.19))
                .frame(width: size + 1, height: size)
        case "Spotify":
            SVGShape(data: BrandPaths.spotify)
                .fill(Color(red: 0.12, green: 0.84, blue: 0.38))
                .frame(width: size, height: size)
        case "Music":
            Image(systemName: "music.note")
                .font(.system(size: size - 1, weight: .semibold))
                .foregroundStyle(Color(red: 0.98, green: 0.34, blue: 0.42))
        default:
            Image(systemName: "globe")
                .font(.system(size: size - 1))
                .foregroundStyle(.white.opacity(0.5))
        }
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

/// Real account limits when we have them (Anthropic's own utilisation
/// numbers, including per-model weekly caps like Fable), falling back to our
/// token estimates when no live reading is available.
private struct MetersRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        if !state.accountLimits.isEmpty {
            VStack(spacing: 6) {
                ForEach(state.accountLimits) { limits in
                    realLimits(limits, compact: state.accountLimits.count > 1)
                }
            }
        } else if state.estD7 > 0 {
            estimated
        }
    }

    private func realLimits(_ limits: AccountLimits, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            HStack(spacing: 8) {
                BrandMark(provider: .claude, size: compact ? 13 : 15)
                Text(limits.plan.isEmpty ? "Claude" : limits.plan)
                    .font(.system(size: compact ? 10.5 : 11, weight: .semibold)).foregroundStyle(.white)
                if !limits.accountName.isEmpty {
                    Text("· \(limits.accountName)")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if compact, !limits.hosts.isEmpty {
                    // With several accounts, say which machines use this one.
                    Text(limits.hosts.map(Self.hostLabel).sorted().joined(separator: " "))
                        .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
                Text(limits.isLive ? "live" : "stale")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(limits.isLive ? .white.opacity(0.35) : EventKind.attention.color.opacity(0.8))
                    .kerning(0.6)
            }
            ForEach(limits.items) { limitRow($0, compact: compact) }
        }
        .padding(compact ? 8 : 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hudCard))
        .help("Live rate-limit utilisation for \(limits.accountName.isEmpty ? "this account" : limits.accountName)")
    }

    static func hostLabel(_ host: String) -> String {
        AppState.Host.isLocal(host) ? "mac" : HostAliases.display(host)
    }

    private func limitRow(_ item: LimitItem, compact: Bool = false) -> some View {
        let color: Color = item.isCritical ? EventKind.attention.color
            : (item.isWarning ? Color(red: 1, green: 0.78, blue: 0.35) : EventKind.running.color)
        return HStack(spacing: 7) {
            Text(item.label)
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                .frame(width: 38, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(color)
                        .frame(width: max(3, geo.size.width * min(1, item.percent / 100)))
                }
            }
            .frame(height: 5)
            Text("\(Int(item.percent.rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(item.isCritical ? color : .white.opacity(0.85))
                .frame(width: 34, alignment: .trailing)
            if !compact {
                Text(Self.resetLabel(item.resetsAt))
                    .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.35))
                    .frame(width: 74, alignment: .trailing).lineLimit(1)
            }
        }
    }

    static func resetLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "resetting…" }
        let f = DateFormatter()
        f.dateFormat = seconds < 20 * 3600 ? "HH:mm" : "EEE HH:mm"
        return "resets \(f.string(from: date))"
    }

    private var estimated: some View {
        HStack(spacing: 10) {
            BrandMark(provider: .claude, size: 15)
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hudCard))
        .help("Estimated tokens from transcripts — no live limit reading available")
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
                .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
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
                BrandMark(provider: session.provider, size: 14)
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
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(f > 0.8 ? EventKind.attention.color : .white.opacity(0.85))
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Group {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.12))
                } else if session.kind == .attention {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EventKind.attention.color.opacity(0.13))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hudCard)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var subtitle: String {
        let hostLabel = AppState.Host.isLocal(session.host) ? "Local" : HostAliases.display(session.host)
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
                    Text(AppState.Host.isLocal(s.host) ? "local" : HostAliases.display(s.host))
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
                                .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white)
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
                            Text(kFmt(s.lastIn))
                                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Output").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                            Text(kFmt(s.lastOut))
                                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
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
                // The change receipt — what the session actually produced.
                // Session scope, not per-turn: the counts cover the whole
                // transcript, and the label must not pretend otherwise.
                if s.filesChanged > 0 {
                    Divider().overlay(.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHAT CHANGED · THIS SESSION")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35)).kerning(0.8)
                        HStack(spacing: 6) {
                            Text("\(s.filesChanged) file\(s.filesChanged == 1 ? "" : "s")")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("+\(s.linesAdded)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(EventKind.done.color)
                            Text("−\(s.linesRemoved)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.45))
                        }
                        if !s.topFile.isEmpty {
                            Text("mostly \(s.topFile)")
                                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                }
            } else {
                Text("No session selected.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hudCard))
    }
}

private extension Circle {
    func fill(session s: SessionInfo) -> some View {
        fill(s.kind.color).frame(width: 5, height: 5)
    }
}

/// Token burn per hour, last 48h, all machines summed — a heat strip fed by
/// the same real usage data as the meters. Replaces the old decorative pulse.
private struct BurnStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        let cells = state.burnCells
        let maxV = max(cells.map(\.tokens).max() ?? 0, 1)
        if cells.contains(where: { $0.tokens > 0 }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("BURN · LAST 48H")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35)).kerning(0.8)
                    Spacer()
                    Text("peak \(kFmt(maxV))/h")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                HStack(spacing: 2) {
                    ForEach(cells, id: \.hour) { c in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(EventKind.running.color.opacity(
                                        c.tokens == 0 ? 0 : 0.25 + 0.75 * Double(c.tokens) / Double(maxV)))
                            )
                            .frame(height: 10)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct ClipChip: View {
    let item: ClipboardItem
    @State private var copied = false

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
        .overlay {
            if copied {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.6))
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .bold))
                        Text("Copied").font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(EventKind.done.color)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
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
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }
}

