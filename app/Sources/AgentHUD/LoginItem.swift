import AppKit
import ServiceManagement

/// Registers the app to start itself at login.
///
/// The system is the source of truth here, not a preference of ours: the user
/// can revoke this in System Settings › General › Login Items, and if we kept
/// our own Bool it would confidently disagree with reality. So every read
/// asks SMAppService.
@MainActor
enum LoginItem {
    /// SMAppService addresses the *running bundle*, which only means anything
    /// inside a real .app — under `swift run` or a test runner it would refer
    /// to something nonsensical.
    static var supported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        guard supported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a human-readable reason it didn't take.
    static func set(_ on: Bool) -> String? {
        guard supported else { return "only available in the built app" }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // The commonest cause is the user having denied it in System
            // Settings, which no amount of retrying fixes — say so plainly.
            return error.localizedDescription
        }
    }

    /// What the OS currently thinks, for the settings window.
    static var statusText: String {
        guard supported else { return "unavailable outside the built app" }
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .requiresApproval: return "waiting for approval in System Settings › General › Login Items"
        case .notRegistered: return "off"
        case .notFound: return "the app bundle moved — rebuild with make bundle"
        @unknown default: return "unknown"
        }
    }
}
