import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Whether we're in a real .app at all — the one fact that can't change
    /// while running. Authorization itself is asked fresh at post time.
    private var bundled = false

    /// Last known authorization, cached purely so /debug and the settings
    /// window can tell you why no banner appeared. A dropped banner used to
    /// be completely silent from the outside — while the sound still played,
    /// which reads as "random chimes and no notifications".
    private let statusLock = NSLock()
    private var _status = "not checked"
    private(set) var deliveredCount = 0
    private(set) var suppressedCount = 0

    var status: String {
        statusLock.lock(); defer { statusLock.unlock() }
        return _status
    }

    var canPost: Bool { status == "authorized" || status == "provisional" }

    private func record(_ s: String, delivered: Bool) {
        statusLock.lock()
        _status = s
        if delivered { deliveredCount += 1 } else { suppressedCount += 1 }
        statusLock.unlock()
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// Refresh the cached status without posting anything.
    func refreshStatus() {
        guard bundled else {
            statusLock.lock(); _status = "not an .app bundle"; statusLock.unlock()
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            self.statusLock.lock()
            self._status = Self.describe(settings.authorizationStatus)
            self.statusLock.unlock()
        }
    }

    func setup() {
        // UNUserNotificationCenter crashes outside a real .app bundle (bare swift run).
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else {
            NSLog("AgentHUD: not running from an .app bundle; system notifications disabled")
            return
        }
        bundled = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refreshStatus()
        }
    }

    func post(for event: AgentEvent, enabled: Bool) {
        guard enabled, bundled, event.kind == .attention || event.kind == .done else { return }
        // Built here, on the caller's thread: event.label reads the shared
        // HostAliases map, which the alias timer mutates on the main thread —
        // touching it from the settings callback's queue was a data race.
        let title = event.kind == .attention ? "\(event.label) needs you" : "\(event.label) — done"
        let body = event.message
        // Asked per post, not cached from the launch prompt: this app runs for
        // weeks, and a permission granted in System Settings afterwards used
        // to stay invisible until a relaunch — the menu toggle read as on
        // while every banner was silently dropped.
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            let name = Self.describe(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                self?.record(name, delivered: false)
                NSLog("AgentHUD: banner suppressed — notification permission is \(name)")
                return
            }
            self?.record(name, delivered: true)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(req)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

enum Sound {
    static func play(for kind: EventKind) {
        switch kind {
        case .attention: NSSound(named: "Sosumi")?.play()
        case .done: NSSound(named: "Glass")?.play()
        default: break
        }
    }
}
