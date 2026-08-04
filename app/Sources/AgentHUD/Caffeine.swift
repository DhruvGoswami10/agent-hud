import Foundation
import IOKit.pwr_mgt

/// Prevents sleep via power assertions — Agent HUD's own Amphetamine.
/// Manual hold keeps the DISPLAY awake (visibly on, like Amphetamine).
/// Auto mode (agents working) prevents system sleep only: the screen may
/// dim, but the Mac keeps working underneath — battery-friendly overnight.
/// Note: closed lid on battery with no external display still forces sleep;
/// that's a macOS rule no assertion overrides.
@MainActor
final class Caffeine {
    static let shared = Caffeine()
    private var assertionID = IOPMAssertionID(0)
    private var currentType: String?

    func set(on: Bool, displayAwake: Bool) {
        let desired: String? = on
            ? (displayAwake ? kIOPMAssertionTypePreventUserIdleDisplaySleep as String
                            : kIOPMAssertionTypePreventUserIdleSystemSleep as String)
            : nil
        guard desired != currentType else { return }
        if currentType != nil {
            IOPMAssertionRelease(assertionID)
            currentType = nil
        }
        if let type = desired {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                (displayAwake ? "Agent HUD: keeping Mac awake" : "Agent HUD: agents are working") as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                currentType = type
            }
        }
    }
}
