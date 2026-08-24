import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let state: AppState
    private var cancellable: AnyCancellable?

    private var notifItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var copyItem: NSMenuItem!
    private var sideBarsItem: NSMenuItem!
    private var musicItem: NSMenuItem!
    private var muteItem: NSMenuItem!
    private var awakeItem: NSMenuItem!
    private var autoAwakeItem: NSMenuItem!
    private var animItems: [NSMenuItem] = []
    private var updateItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var notifWarningItem: NSMenuItem!
    private var holdItems: [NSMenuItem] = []
    private var testResolver: Task<Void, Never>?
    private var updaterCancellable: AnyCancellable?

    init(state: AppState) {
        self.state = state
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.addItem(makeItem("Open Agent HUD", #selector(openHUD), "o"))
        menu.addItem(makeItem("Send Test Event", #selector(sendTest), ""))
        menu.addItem(.separator())
        notifItem = makeItem("System Notifications", #selector(toggleNotifs), "")
        soundItem = makeItem("Sounds", #selector(toggleSounds), "")
        copyItem = makeItem("Expand on Copy", #selector(toggleCopy), "")
        sideBarsItem = makeItem("Side Indicator Bars", #selector(toggleSideBars), "")
        musicItem = makeItem("Music Controls", #selector(toggleMusic), "")
        muteItem = makeItem("Mute Notifications", #selector(toggleMute), "m")
        awakeItem = makeItem("Keep Mac Awake", #selector(toggleAwake), "")
        autoAwakeItem = makeItem("Auto-Awake While Agents Work", #selector(toggleAutoAwake), "")
        menu.addItem(notifItem)
        menu.addItem(soundItem)
        menu.addItem(copyItem)
        menu.addItem(sideBarsItem)
        menu.addItem(musicItem)
        menu.addItem(.separator())
        menu.addItem(muteItem)
        menu.addItem(awakeItem)
        menu.addItem(autoAwakeItem)

        // Timed holds: "keep it up for the next half hour" is the thing you
        // actually want, and it ends itself if you forget.
        let holdMenu = NSMenu()
        for minutes in [15, 30, 60, 120, 300] {
            let title = minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes >= 120 ? "s" : "")"
            let m = NSMenuItem(title: title, action: #selector(holdFor(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = minutes
            holdMenu.addItem(m)
            holdItems.append(m)
        }
        holdMenu.addItem(.separator())
        holdMenu.addItem(makeItem("Indefinitely", #selector(holdIndefinitely), ""))
        holdMenu.addItem(makeItem("Release Hold", #selector(releaseHold), ""))
        let holdRoot = NSMenuItem(title: "Keep Awake For…", action: nil, keyEquivalent: "")
        holdRoot.submenu = holdMenu
        menu.addItem(holdRoot)

        let animMenu = NSMenu()
        for style in AnimStyle.allCases {
            let item = NSMenuItem(title: style.label, action: #selector(pickAnim(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            animMenu.addItem(item)
            animItems.append(item)
        }
        animMenu.addItem(.separator())
        animMenu.addItem(makeItem("Preview Animation", #selector(previewAnim), "p"))
        let animRoot = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        animRoot.submenu = animMenu
        menu.addItem(animRoot)
        menu.addItem(.separator())
        notifWarningItem = makeItem("⚠︎ Notifications Blocked — Fix…", #selector(fixNotifications), "")
        menu.addItem(notifWarningItem)
        loginItem = makeItem("Open at Login", #selector(toggleLoginItem), "")
        menu.addItem(loginItem)
        updateItem = makeItem("Check for Updates…", #selector(checkUpdates), "")
        menu.addItem(updateItem)
        menu.addItem(makeItem("Settings…", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Agent HUD", #selector(quit), "q"))
        item.menu = menu

        cancellable = state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        updaterCancellable = Updater.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }

    private func makeItem(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        m.target = self
        return m
    }

    private func refresh() {
        let agg = state.aggregate
        let base = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent HUD")
        if agg == .info {
            base?.isTemplate = true
            item.button?.image = base
        } else {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [agg.nsColor])
            let img = base?.withSymbolConfiguration(cfg)
            img?.isTemplate = false
            item.button?.image = img
        }
        notifItem?.state = state.systemNotifications ? .on : .off
        soundItem?.state = state.sounds ? .on : .off
        copyItem?.state = state.expandOnCopy ? .on : .off
        sideBarsItem?.state = state.sideBars ? .on : .off
        musicItem?.state = state.musicEnabled ? .on : .off
        muteItem?.state = state.muted ? .on : .off
        awakeItem?.state = state.keepAwake ? .on : .off
        autoAwakeItem?.state = state.autoAwake ? .on : .off
        // Show the countdown where the hold was started, so a forgotten
        // timer is visible rather than a mystery.
        if let left = state.awakeRemaining {
            let m = Int(left / 60) + (Int(left) % 60 > 0 ? 1 : 0)
            awakeItem?.title = "Keep Mac Awake — \(m)m left"
        } else {
            awakeItem?.title = "Keep Mac Awake"
        }
        for item in animItems {
            item.state = (item.representedObject as? String) == state.animStyle.rawValue ? .on : .off
        }
        loginItem?.state = state.openAtLogin ? .on : .off
        // Only present when there is something wrong to say.
        notifWarningItem?.isHidden = !state.notificationsBlocked
        let updater = Updater.shared
        if updater.checking {
            updateItem?.title = "Checking for Updates…"
        } else if updater.updateAvailable, let latest = updater.latest {
            updateItem?.title = "Update Available: \(latest)"
        } else {
            updateItem?.title = "Check for Updates…"
        }
    }

    @objc private func openHUD() { state.openPanel() }

    /// Walks the whole colour arc and then resolves itself. It used to stop
    /// at orange — and because "demo" is a host that by construction never
    /// reports a registry, nothing could demote it for an hour, so one click
    /// on a TEST button meant an hour of orange notch and an hour of held
    /// sleep. A test that doesn't clean up after itself isn't a test.
    @objc private func sendTest() {
        func event(_ kind: EventKind, _ message: String) -> AgentEvent {
            AgentEvent(kind: kind, host: "demo", project: "test", sessionId: "demo-1",
                       sessionName: "demo-session", message: message,
                       hook: "Notification", image: nil, ts: Date())
        }
        state.apply(event(.attention, "Claude needs your permission to use Bash"))
        testResolver?.cancel()
        testResolver = Task { [weak state] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let state else { return }
            state.apply(event(.done, "test event finished"))
        }
    }

    @objc private func toggleNotifs() { state.systemNotifications.toggle() }
    @objc private func toggleSounds() { state.sounds.toggle() }
    @objc private func toggleCopy() { state.expandOnCopy.toggle() }
    @objc private func toggleSideBars() { state.sideBars.toggle() }
    @objc private func toggleMusic() { state.musicEnabled.toggle() }
    @objc private func toggleMute() { state.muted.toggle() }
    @objc private func toggleAwake() { state.keepAwake.toggle() }
    @objc private func toggleAutoAwake() { state.autoAwake.toggle() }

    @objc private func pickAnim(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = AnimStyle(rawValue: raw) {
            state.animStyle = style
            state.previewAnimation()
        }
    }

    @objc private func previewAnim() { state.previewAnimation() }

    @objc private func holdFor(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        state.holdAwake(minutes: minutes)
    }

    @objc private func holdIndefinitely() { state.holdAwake(minutes: 0) }
    @objc private func releaseHold() { state.releaseAwakeHold() }

    @objc private func openSettings() { SettingsWindowController.shared?.show() }

    @objc private func toggleLoginItem() { state.setOpenAtLogin(!state.openAtLogin) }

    @objc private func fixNotifications() { state.openNotificationSettings() }

    @objc private func checkUpdates() {
        if Updater.shared.updateAvailable {
            Updater.shared.openReleasePage()
        } else {
            Updater.shared.check(force: true)
            SettingsWindowController.shared?.show()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
