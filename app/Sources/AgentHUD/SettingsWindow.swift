import AppKit
import SwiftUI

/// The settings surface. Everything that used to be a hard-coded number —
/// how long a slide-out lingers, how forgiving the hover is — lives here, so
/// a peek that lands mid-thought is a preference rather than an argument.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static var shared: SettingsWindowController?

    private let window: NSWindow

    init(state: AppState) {
        let view = SettingsView(state: state)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Agent HUD Settings"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        window.delegate = self
    }

    func show() {
        // A menu-bar app can't bring a real window forward while it's an
        // accessory; become a regular app for as long as settings are open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Back to menu-bar-only once settings close, so the HUD doesn't leave a
    /// Dock icon lying around.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        TabView {
            timingTab.tabItem { Label("Timing", systemImage: "timer") }
            appearanceTab.tabItem { Label("General", systemImage: "sparkles") }
            awakeTab.tabItem { Label("Keep Awake", systemImage: "cup.and.saucer") }
            updatesTab.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520, height: 620)
    }

    // MARK: - Timing

    private var timingTab: some View {
        Form {
            Section("How long slide-outs stay") {
                seconds("Needs you", value: $state.attentionPeekSeconds, range: 2...120)
                seconds("Agent finished", value: $state.donePeekSeconds, range: 1...60)
                seconds("Clipboard copy", value: $state.clipboardPeekSeconds, range: 1...30)
                seconds("Music track change", value: $state.musicPeekSeconds, range: 1...30)
            }
            Section("Getting rid of one fast") {
                Toggle("Click a slide-out to dismiss it", isOn: $state.clickPeekDismisses)
                    .help("Off: clicking expands the full panel instead, as it used to.")
                Toggle("Dismiss from anywhere with \(HotKey.displayName)", isOn: $state.dismissHotKeyEnabled)
                Toggle("Hovering a slide-out opens the full panel", isOn: $state.hoverExpandsPeek)
                Text(state.hoverExpandsPeek
                     ? "Reaching for a slide-out expands it — so a click lands on the panel, not on the slide-out."
                     : "A slide-out holds still while you point at it, so a click dismisses it. Hovering the notch itself still opens the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hover") {
                HStack {
                    Text("Stay open after the pointer leaves")
                    Spacer()
                    Text(String(format: "%.2gs", state.hoverCollapseDelay))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $state.hoverCollapseDelay, in: 0.1...2.0, step: 0.05)
                Text("Higher values stop the panel snapping shut while you move around inside it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func seconds(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Stepper(value: value, in: range, step: value.wrappedValue < 10 ? 0.5 : 1) {
                Text(String(format: value.wrappedValue < 10 ? "%.1fs" : "%.0fs", value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        Form {
            Section("Starting up") {
                Toggle("Open Agent HUD at login", isOn: Binding(
                    get: { state.openAtLogin },
                    set: { state.setOpenAtLogin($0) }
                ))
                if let problem = state.loginItemProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                Text("If you quit Agent HUD, start it again from Spotlight (\u{201C}AgentHUD\u{201D}), or run \u{201C}make run\u{201D} in ~/agent-hud. Turning this on brings it back after every restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("The notch at rest") {
                Toggle("Always show a resting indicator", isOn: $state.alwaysShowIndicator)
                Text("By default the HUD is completely invisible when nothing is happening — the notch is just the notch. Turn this on for a dim mark that tells you it is alive.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Side indicator bars", isOn: $state.sideBars)
                Text("Off: a thin glowing line under the notch instead of bars flanking it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Alerts") {
                if state.notificationsBlocked {
                    // The sound and the banner are separate channels, so a
                    // denied permission means chimes with nothing on screen.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("macOS is blocking Agent HUD's notifications",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Permission is \(state.notificationPermission), so banners never appear — but sounds still play, which is why you hear chimes with nothing on screen. Allow notifications for Agent HUD to get the banners back.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Notification Settings") { state.openNotificationSettings() }
                    }
                }
                Toggle("System notifications", isOn: $state.systemNotifications)
                Toggle("Sounds", isOn: $state.sounds)
                Toggle("Mute everything", isOn: $state.muted)
                Toggle("Expand on copy", isOn: $state.expandOnCopy)
                Toggle("Music controls", isOn: $state.musicEnabled)
            }
            Section("Animation") {
                Picker("Style", selection: $state.animStyle) {
                    ForEach(AnimStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Button("Preview") { state.previewAnimation() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Keep awake

    private var awakeTab: some View {
        Form {
            Section("Right now") {
                HStack {
                    Image(systemName: state.awakeActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(state.awakeActive ? .orange : .secondary)
                    Text(awakeStatus).foregroundStyle(state.awakeActive ? .primary : .secondary)
                    Spacer()
                    if state.keepAwake {
                        Button("Release") { state.releaseAwakeHold() }
                    }
                }
            }
            Section("Hold it awake") {
                HStack(spacing: 8) {
                    ForEach([15, 30, 60, 120], id: \.self) { m in
                        Button(m < 60 ? "\(m)m" : "\(m / 60)h") { state.holdAwake(minutes: m) }
                    }
                    Button("Indefinitely") { state.holdAwake(minutes: 0) }
                }
                Toggle("Keep the screen on during a manual hold", isOn: $state.keepScreenOn)
                Text(state.keepScreenOn
                     ? "The display stays lit and the idle lock is held off."
                     : "The Mac stays up but the screen is allowed to sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("While agents work") {
                Toggle("Stay awake automatically", isOn: $state.autoAwake)
                Text("Holds the Mac up while any agent is running or waiting on you, and for \(Int(AppState.autoLinger / 60)) minutes after the last one goes quiet — so a burst overnight doesn't lose its SSH tunnels. The screen is allowed to sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("A closed lid on battery with no external display sleeps anyway — that is below the layer any app can reach.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var awakeStatus: String {
        guard state.awakeActive else { return "Sleeping normally" }
        if let left = state.awakeRemaining {
            let m = Int(left / 60), s = Int(left) % 60
            return m > 0 ? "Held awake — \(m)m \(s)s left" : "Held awake — \(s)s left"
        }
        switch state.awakeReason {
        case "manual": return "Held awake — until you release it"
        case "agents": return "Held awake — agents are working"
        case "cooldown": return "Held awake — cooling down after a run"
        default: return "Held awake"
        }
    }

    // MARK: - Updates

    private var updatesTab: some View {
        Form {
            Section("Version") {
                LabeledContent("Running", value: Updater.current)
                if let latest = updater.latest {
                    LabeledContent("Latest release", value: latest)
                }
                if let checked = updater.lastChecked {
                    LabeledContent("Last checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                }
                if let err = updater.lastError {
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Check for new releases automatically", isOn: $state.autoUpdateCheck)
                Text("Asks GitHub for the newest tag, at most every six hours. Nothing is ever downloaded or installed on its own.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(updater.checking ? "Checking…" : "Check now") { updater.check(force: true) }
                        .disabled(updater.checking)
                    if updater.updateAvailable {
                        Button("Open release page") { updater.openReleasePage() }
                    }
                }
            }
            Section("Installing an update") {
                if updater.updateAvailable, let latest = updater.latest {
                    Text("\(latest) is available.").font(.callout)
                }
                Text("Agent HUD runs from the repo it was built in — the hooks, the reporter and the tunnel keeper all live beside it — so updating means updating the clone:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("cd ~/agent-hud && bin/agent-hud-update")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy that command") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString("cd ~/agent-hud && bin/agent-hud-update", forType: .string)
                }
            }
        }
        .formStyle(.grouped)
    }
}
