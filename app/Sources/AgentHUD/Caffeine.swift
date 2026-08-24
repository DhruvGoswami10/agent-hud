import Foundation
import AppKit
import IOKit.pwr_mgt
import ApplicationServices

/// Keep-awake engine, rebuilt to the pattern the best tools use:
///
/// - Assertions are created with a 60s timeout and re-created every 15s.
///   If the app crashes or an update is missed, the hold evaporates on its
///   own instead of pinning the Mac forever (and a failed create retries).
/// - `.display` (manual hold) additionally defeats the screen saver and idle
///   auto-lock: those run off the HID idle timer, which NO power assertion
///   resets — only real or synthetic input does. We post a zero-move
///   CGEvent at the current cursor position when HID idle approaches the
///   minimum lock threshold (requires the Accessibility permission).
/// - `.system` (agents working) deliberately lets the display sleep.
///
/// What remains impossible without root: lid closed on battery with no
/// external display is forced sleep below the assertion layer
/// (kIOPMAssertionAppliesOnLidClose is entitlement-locked since 10.13).
@MainActor
final class Caffeine {
    static let shared = Caffeine()

    enum Mode: Equatable { case off, system, display }

    private(set) var mode: Mode = .off
    private var assertionID = IOPMAssertionID(0)
    /// When the current assertion was created. Derived rather than latched:
    /// the assertion carries a 60s release timeout, so a missed renew (sleep,
    /// a stalled run loop) silently retires it — a stored Bool then reported
    /// a hold that powerd had already dropped, and the "re-arm after wake"
    /// path short-circuited on that lie and never re-created anything.
    private var assertionCreatedAt: Date?
    /// The user-activity assertion from relightDisplay(). Kept so it can be
    /// released: passing a throwaway local meant every manual hold leaked a
    /// one-hour UserIsActive assertion that outlived the toggle.
    private var userActivityID = IOPMAssertionID(0)
    private var timer: Timer?
    private var promptedForAccessibility = false

    var assertionAlive: Bool {
        guard let created = assertionCreatedAt else { return false }
        return Date().timeIntervalSince(created) < Self.assertionTimeout
    }

    nonisolated static let assertionTimeout: TimeInterval = 60
    nonisolated static let renewInterval: TimeInterval = 15
    nonisolated static let jiggleAfterIdle: TimeInterval = 40  // < macOS's 1-min minimum lock

    var jiggleAuthorized: Bool { AXIsProcessTrusted() }

    /// Idempotent; cheap to call on every state change. Returns whether a
    /// live assertion backs the requested (non-off) mode.
    func set(mode desired: Mode) -> Bool {
        if desired == mode {
            if mode == .off { return true }
            return assertionAlive || renewAssertion()  // retry earlier failure
        }
        releaseAssertion()
        mode = desired
        configureTimer()
        guard mode != .off else { return true }
        if mode == .display {
            relightDisplay()
            promptForAccessibilityIfNeeded()
        }
        return renewAssertion()
    }

    // MARK: - Assertion lifecycle

    private func renewAssertion() -> Bool {
        releaseAssertion()
        let type = mode == .display
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        let name = mode == .display ? "Agent HUD: keeping display awake" : "Agent HUD: agents are working"
        let props: [String: Any] = [
            kIOPMAssertionTypeKey as String: type,
            kIOPMAssertionNameKey as String: name,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey as String: Self.assertionTimeout,
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease,
        ]
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithProperties(props as CFDictionary, &id)
        if result == kIOReturnSuccess {
            assertionID = id
            assertionCreatedAt = Date()
        } else {
            NSLog("AgentHUD: power assertion creation FAILED (\(result)) for mode \(mode)")
            assertionCreatedAt = nil
        }
        return assertionAlive
    }

    private func releaseAssertion() {
        if assertionCreatedAt != nil {
            IOPMAssertionRelease(assertionID)
            assertionCreatedAt = nil
        }
        // The relight assertion belongs to the display hold; when that hold
        // ends it must go too, or it keeps the Mac up for an hour after the
        // toggle is off.
        if userActivityID != IOPMAssertionID(0) {
            IOPMAssertionRelease(userActivityID)
            userActivityID = IOPMAssertionID(0)
        }
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard mode != .off else { return }
        let t = Timer(timeInterval: Self.renewInterval, repeats: true) { _ in
            Task { @MainActor in Caffeine.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard mode != .off else { return }
        _ = renewAssertion()
        if mode == .display { jiggleIfIdle() }
    }

    // MARK: - Display mode extras

    /// Turn an already-dark display back on when the hold engages
    /// (equivalent to `caffeinate -u`).
    /// Apple's contract for this out-parameter is to pass back the id you got
    /// last time; a fresh local each call created a new hour-long assertion
    /// every time and left the old one holding.
    private func relightDisplay() {
        IOPMAssertionDeclareUserActivity("Agent HUD manual hold" as CFString,
                                         kIOPMUserActiveLocal, &userActivityID)
    }

    /// The screen saver and idle auto-lock trigger off HIDIdleTime, which
    /// only (real or synthetic) HID events reset. A zero-move mouse event at
    /// the current position is invisible to the user but resets the timer.
    /// CGWarpMouseCursorPosition would NOT work — it bypasses HID.
    private func jiggleIfIdle() {
        guard let idle = Self.hidIdleSeconds(), idle >= Self.jiggleAfterIdle else { return }
        guard let pos = CGEvent(source: nil)?.location,
              let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: pos, mouseButton: .left) else { return }
        ev.post(tap: .cghidEventTap)
    }

    static func hidIdleSeconds() -> Double? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let idleNs = dict["HIDIdleTime"] as? Int64 else { return nil }
        return Double(idleNs) / 1_000_000_000
    }

    private func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted(), !promptedForAccessibility else { return }
        promptedForAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
