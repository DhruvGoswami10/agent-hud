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
    private var awakeItem: NSMenuItem!
    private var autoAwakeItem: NSMenuItem!
    private var animItems: [NSMenuItem] = []

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
        awakeItem = makeItem("Keep Mac Awake", #selector(toggleAwake), "")
        autoAwakeItem = makeItem("Auto-Awake While Agents Work", #selector(toggleAutoAwake), "")
        menu.addItem(notifItem)
        menu.addItem(soundItem)
        menu.addItem(copyItem)
        menu.addItem(sideBarsItem)
        menu.addItem(musicItem)
        menu.addItem(.separator())
        menu.addItem(awakeItem)
        menu.addItem(autoAwakeItem)

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
        menu.addItem(makeItem("Quit Agent HUD", #selector(quit), "q"))
        item.menu = menu

        cancellable = state.objectWillChange
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
        awakeItem?.state = state.keepAwake ? .on : .off
        autoAwakeItem?.state = state.autoAwake ? .on : .off
        for item in animItems {
            item.state = (item.representedObject as? String) == state.animStyle.rawValue ? .on : .off
        }
    }

    @objc private func openHUD() { state.openPanel() }

    @objc private func sendTest() {
        let e = AgentEvent(kind: .attention, host: "demo", project: "test", sessionId: "demo-1",
                           sessionName: "demo-session", message: "Claude needs your permission to use Bash",
                           hook: "Notification", image: nil, ts: Date())
        state.apply(e)
    }

    @objc private func toggleNotifs() { state.systemNotifications.toggle() }
    @objc private func toggleSounds() { state.sounds.toggle() }
    @objc private func toggleCopy() { state.expandOnCopy.toggle() }
    @objc private func toggleSideBars() { state.sideBars.toggle() }
    @objc private func toggleMusic() { state.musicEnabled.toggle() }
    @objc private func toggleAwake() { state.keepAwake.toggle() }
    @objc private func toggleAutoAwake() { state.autoAwake.toggle() }

    @objc private func pickAnim(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = AnimStyle(rawValue: raw) {
            state.animStyle = style
            state.previewAnimation()
        }
    }

    @objc private func previewAnim() { state.previewAnimation() }
    @objc private func quit() { NSApp.terminate(nil) }
}
