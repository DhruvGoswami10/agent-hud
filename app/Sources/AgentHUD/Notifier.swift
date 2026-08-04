import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var available = false

    func setup() {
        // UNUserNotificationCenter crashes outside a real .app bundle (bare swift run).
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else {
            NSLog("AgentHUD: not running from an .app bundle; system notifications disabled")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.available = granted
        }
    }

    func post(for event: AgentEvent, enabled: Bool) {
        guard enabled, available, event.kind == .attention || event.kind == .done else { return }
        let content = UNMutableNotificationContent()
        content.title = event.kind == .attention ? "\(event.label) needs you" : "\(event.label) — done"
        content.body = event.message
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
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
