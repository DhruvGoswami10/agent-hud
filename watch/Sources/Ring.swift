import SwiftUI
import WatchKit

/// The watch's own idea, not a shrunk panel: a round face deserves a round
/// readout. The ring is context used — bounded, honest, and the number that
/// decides whether a session is near the end of its rope. The timer in the
/// middle is elapsed time, which is unbounded and so must never be a ring.
struct SessionRing: View {
    let session: WatchSession
    /// Sized off the real screen rather than a guess: the 40mm SE and the
    /// 49mm Ultra differ by ~30pt of width, and a fixed number clips on one
    /// of them. Everything the ring draws stays inside this box.
    var size: CGFloat = min(WKInterfaceDevice.current().screenBounds.width * 0.66, 128)
    /// Seconds since the last poll, so the clock ticks every second.
    var offset: Int = 0

    @State private var sweep = false

    private var fraction: Double { min(1, Double(session.ctx) / 100) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: size * 0.075)

            // Context: fills clockwise, turns amber as the window closes.
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(ctxColor, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)

            // A working session gets a travelling arc just inside the track —
            // the only honest way to show elapsed time with no known end.
            // Inside, not outside, so nothing can spill past the bezel.
            if session.kind == "running" {
                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(session.color, style: StrokeStyle(lineWidth: size * 0.026, lineCap: .round))
                    .frame(width: size * 0.82, height: size * 0.82)
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: sweep)
                    .onAppear { sweep = true }
            }

            VStack(spacing: 1) {
                Text(session.elapsed(plus: offset))
                    .font(.system(size: size * 0.26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(session.kind == "running" ? "working" : session.kind)
                    .font(.system(size: size * 0.088, weight: .medium))
                    .foregroundStyle(session.color)
                if session.ctx > 0 {
                    Text("\(session.ctx)% context")
                        .font(.system(size: size * 0.078))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var ctxColor: Color {
        if session.ctx >= 85 { return Color(red: 1, green: 0.45, blue: 0.38) }
        if session.ctx >= 65 { return Color(red: 1, green: 0.76, blue: 0.35) }
        return session.color
    }
}

/// Tapping a session opens this: the ring, then what it actually did.
struct SessionDetail: View {
    let session: WatchSession

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SessionRing(session: session)
                    .padding(.top, 4)

                Text(session.name)
                    .font(.system(size: 15, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(session.host)
                    if !session.model.isEmpty {
                        Text("·")
                        Text(session.model).lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                if session.files > 0 {
                    HStack(spacing: 8) {
                        Text("\(session.files) file\(session.files == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .semibold))
                        Text("+\(session.added)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
                        Text("−\(session.removed)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.45))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(.white.opacity(0.09)))
                }

                if !session.message.isEmpty {
                    Text(session.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
