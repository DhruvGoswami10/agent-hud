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
    @ObservedObject private var watch = WatchBridge.shared

    var body: some View {
        TabView {
            timingTab.tabItem { Label("Timing", systemImage: "timer") }
            appearanceTab.tabItem { Label("General", systemImage: "sparkles") }
            awakeTab.tabItem { Label("Keep Awake", systemImage: "cup.and.saucer") }
            connectionsTab.tabItem { Label("Connections", systemImage: "link") }
            updatesTab.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520, height: 620)
    }

    private var connectionsTab: some View {
        Form {
            Section("Browser bridge") {
                Text("Copy your pairing key, then paste it into the Agent HUD Bridge extension’s popup. Each browser needs to be paired once.")
                    .font(.caption).foregroundStyle(.secondary)
                PairingKeyCopyButton { state.copyBrowserPairingKey() }
            }
            Section("Apple Watch") {
                Toggle("Allow Watch connections on this network", isOn: Binding(
                    get: { watch.enabled }, set: { watch.setEnabled($0) }))
                Text(watch.status).font(.caption).foregroundStyle(.secondary)
                if watch.enabled {
                    Button("Copy Watch pairing link") { watch.copyPairingLink() }
                        .disabled(watch.pairingLink.isEmpty)
                    Text("Paste this link in the Watch app’s Pair Mac screen. Connections are encrypted and read-only. The Watch refreshes while its app is open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Connection health") {
                LabeledContent("Listener", value: state.listenerStatus)
                LabeledContent("Local reporter", value: state.reporterStatus)
                LabeledContent("Notifications", value: state.notificationPermission)
                LabeledContent("Prevent idle lock", value: Caffeine.shared.jiggleAuthorized ? "Allowed" : "Accessibility permission required")
                if !state.reporterProblem.isEmpty {
                    Text(state.reporterProblem).font(.caption).textSelection(.enabled)
                }
            }
            Section("Remote reporters") {
                ForEach(state.reporterVersions.keys.sorted(), id: \.self) { host in
                    LabeledContent(HostAliases.display(host), value: state.reporterVersions[host] ?? "unknown")
                }
                Text("Update configured remote reporters with bin/agent-hud-bootstrap HOST. Older reporters are marked legacy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
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
                Text("If you quit Agent HUD, start it again from Spotlight (\u{201C}AgentHUD\u{201D}), or run \u{201C}make run\u{201D} from your source checkout. Turning this on brings it back after every restart.")
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
            Section("Without a notch (lid closed, external display)") {
                Toggle("Side notch instead of a top pill", isOn: $state.edgePlacement)
                Text("On a wide display the top-centre is where the browser keeps its tabs, so the HUD moves to a side edge: the notch turned on its side. A sliver at rest, a lit silhouette when there is news.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Edge", selection: $state.edgeSide) {
                    Text("Right").tag(EdgeSide.right)
                    Text("Left").tag(EdgeSide.left)
                }
                .pickerStyle(.segmented)
                Picker("Grip", selection: $state.edgeGripBar) {
                    Text("Notch").tag(false)
                    Text("Bar").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Bar is the side-indicator bars moved to the edge — one segment per running session.")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $state.edgeAnchor, in: AppState.edgeAnchorRange) {
                    Text("Height")
                } minimumValueLabel: {
                    Text("Higher").font(.caption)
                } maximumValueLabel: {
                    Text("Lower").font(.caption)
                }
                Text("Or just drag the side notch up and down. It stays where you leave it.")
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
                Toggle("Mute all alerts and slide-outs", isOn: $state.muted)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AwakeControls(state: state)
                    .preferredColorScheme(.dark)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                if !Caffeine.shared.jiggleAuthorized {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional idle-lock prevention").font(.headline)
                        Text("Keeping the display on works without Accessibility. Preventing automatic locking needs that permission.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Allow idle-lock prevention…") {
                            Caffeine.shared.requestIdleResetAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                Text("Keep Awake prevents idle sleep. Closing the lid, choosing Sleep, or a low battery can still put the Mac to sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
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
                Text("For a downloaded app, quit Agent HUD and replace it with the latest release. The reporter is included. Source installations can use the command below:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("bin/agent-hud-update")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy that command") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString("bin/agent-hud-update", forType: .string)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PairingKeyCopyButton: View {
    let copy: () -> Bool
    @State private var feedback = Feedback.ready
    @State private var copyAttempt = 0

    private enum Feedback: String, CaseIterable {
        case ready = "Copy pairing key"
        case copied = "Copied!"
        case failed = "Couldn’t copy"

        var symbol: String {
            switch self {
            case .ready: "doc.on.doc"
            case .copied: "checkmark.circle.fill"
            case .failed: "exclamationmark.circle"
            }
        }
    }

    var body: some View {
        Button {
            feedback = copy() ? .copied : .failed
            copyAttempt += 1
        } label: {
            // Reserve every label's size so confirmation never moves the button.
            ZStack {
                ForEach(Feedback.allCases, id: \.self) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .opacity(item == feedback ? 1 : 0)
                        .accessibilityHidden(item != feedback)
                }
            }
            .foregroundStyle(feedback == .copied ? Color.green : Color.primary)
        }
        .accessibilityLabel(feedback.rawValue)
        .help(feedback == .failed ? "Try copying the pairing key again." : "Copy your browser pairing key.")
        .task(id: copyAttempt) {
            guard feedback != .ready else { return }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            feedback = .ready
        }
        .onDisappear { feedback = .ready }
    }
}
