import WatchKit

/// watchOS has no Core Haptics — you get a fixed set of taps and nothing else.
/// The loophole is rhythm: short sequences of those taps are distinguishable
/// through a sleeve, so each event gets its own signature rather than
/// everything feeling like "a notification".
enum Haptics {
    private static func play(_ steps: [(WKHapticType, Double)]) {
        var delay = 0.0
        for (type, gap) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                WKInterfaceDevice.current().play(type)
            }
            delay += gap
        }
    }

    /// Finished — two rising taps, over quickly. Good news shouldn't nag.
    static func done() { play([(.success, 0.18), (.click, 0)]) }

    /// Needs you — three insistent taps you can't mistake for a message.
    /// This is the one you should feel across a room.
    static func needsYou() {
        play([(.notification, 0.22), (.directionUp, 0.22), (.notification, 0)])
    }

    /// Errored — the system's own failure pattern, then a full stop.
    static func failed() { play([(.failure, 0.3), (.stop, 0)]) }

    /// A run beginning; barely there, so it never becomes noise.
    static func started() { play([(.click, 0)]) }
}
