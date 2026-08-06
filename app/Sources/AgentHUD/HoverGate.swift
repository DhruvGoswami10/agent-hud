import Foundation

/// Decides when the pointer being over the notch counts as an intentional
/// hover.
///
/// On multi-display setups the cursor crosses the notch strip on its way to a
/// screen placed above or beside the built-in one. Without a gate, every
/// crossing pops the panel open. Requiring a short dwell *and* a slow pointer
/// keeps deliberate hovers feeling instant while ignoring transits.
struct HoverGate {
    var dwellSamples: Int
    var maxSpeed: CGFloat
    private var samples = 0
    private var last: CGPoint?
    private(set) var engaged = false

    init(dwellSamples: Int = 2, maxSpeed: CGFloat = 50) {
        self.dwellSamples = dwellSamples
        self.maxSpeed = maxSpeed
    }

    /// Feed one poll sample. Returns the new engaged value only when it
    /// changes, so callers can forward exactly one hover event per transition.
    mutating func update(point: CGPoint, inside: Bool) -> Bool? {
        let delta = last.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .greatestFiniteMagnitude
        last = point
        guard inside else {
            samples = 0
            guard engaged else { return nil }
            engaged = false
            return false
        }
        samples += 1
        guard !engaged, samples >= dwellSamples, delta <= maxSpeed else { return nil }
        engaged = true
        return true
    }
}
