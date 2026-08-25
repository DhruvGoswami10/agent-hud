import SwiftUI
import WatchKit

/// A tick dial rather than a solid ring. Marks read as an instrument — you
/// take the level from how far round the lit ones go, without reading a
/// number — and they leave the middle empty, which is where the one fact
/// that matters lives. Every fifth mark is longer so the eye finds quarters
/// without needing a scale.
///
/// The marks fill with the seconds of the elapsed time and wrap every
/// minute, so the dial is literally the clock in the middle drawn round the
/// edge. Colour carries the second fact — how full the context window is —
/// which means one instrument says two things without saying either twice.
struct TickDial<Center: View>: View {
    var fraction: Double            // 0…1, how far round to light up
    var color: Color
    var size: CGFloat
    var ticks: Int = 60
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            ForEach(0..<ticks, id: \.self) { i in
                let at = Double(i) / Double(ticks)
                let major = i % 5 == 0
                Capsule()
                    .fill(at < fraction ? color : Color.white.opacity(0.15))
                    // Floors matter: at list-row sizes the proportional width
                    // works out under half a point and the dial disappears.
                    .frame(width: max(1.3, size * 0.017),
                           height: max(major ? 4 : 2.6,
                                       major ? size * 0.085 : size * 0.055))
                    .offset(y: -size / 2 + max(2.6, size * 0.05))
                    .rotationEffect(.degrees(at * 360))
            }
            center()
        }
        .frame(width: size, height: size)
    }
}

/// The whole of screen one: what's running, and for how long.
struct SessionRing: View {
    let session: WatchSession
    var size: CGFloat = min(WKInterfaceDevice.current().screenBounds.width * 0.74, 150)
    var offset: Int = 0

    var body: some View {
        // Fill = where we are in the current minute; colour = context health.
        TickDial(fraction: session.kind == "running" ? session.minuteFraction(plus: offset) : 1,
                 color: ctxColor,
                 size: size) {
            VStack(spacing: 0) {
                Text(session.elapsed(plus: offset))
                    .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(session.kind == "running" ? "working" : session.kind)
                    .font(.system(size: size * 0.082, weight: .medium))
                    .foregroundStyle(session.color)
            }
        }
    }

    private var ctxColor: Color {
        if session.ctx >= 85 { return Color(red: 1, green: 0.45, blue: 0.38) }
        if session.ctx >= 65 { return Color(red: 1, green: 0.76, blue: 0.35) }
        return session.color
    }
}

/// Tapping a row: the same dial, plus the few facts a row can't hold.
struct SessionDetail: View {
    let session: WatchSession

    var body: some View {
        VStack(spacing: 7) {
            SessionRing(session: session,
                        size: min(WKInterfaceDevice.current().screenBounds.width * 0.60, 118))
            Text(session.name)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
            Text("\(session.ctx)% context · \(session.host)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if session.files > 0 {
                Text("\(session.files) files  +\(session.added)  −\(session.removed)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
