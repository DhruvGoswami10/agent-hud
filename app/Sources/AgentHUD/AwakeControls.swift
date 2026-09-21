import SwiftUI

private extension AwakeStatus {
    var tint: Color {
        if failed { return Color(red: 1, green: 0.55, blue: 0.6) }
        switch mode {
        case .manual: return Color(red: 1, green: 0.77, blue: 0.42)
        case .auto: return Color(red: 0.52, green: 0.73, blue: 1)
        case .off: return Color(white: 0.66)
        }
    }
}

struct AwakeBadge: View {
    @ObservedObject var state: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = state.awakeStatus(at: context.date)
            Button { state.awakeControlsPresented.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: status.badgeSymbol).font(.system(size: 12)).frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status.badgeTitle).font(.system(size: 11, weight: .medium))
                        Text(status.badgeDetail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.66))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: state.awakeControlsPresented ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .frame(width: 8)
                }
                .frame(width: 150, height: 26, alignment: .leading)
                .foregroundStyle(status.tint)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 10).fill(status.tint.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(status.tint.opacity(0.22)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep Awake controls")
            .accessibilityValue(status.badgeDetail + ". " + status.title)
            .help("Choose Off, Auto, or Manual; set a timer and display behavior")
            .popover(isPresented: $state.awakeControlsPresented, arrowEdge: .bottom) {
                AwakeControls(state: state)
                    .frame(width: 350)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

/// The same compact controls appear in the notch popover and Settings.
struct AwakeControls: View {
    @ObservedObject var state: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = state.awakeStatus(at: context.date)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Keep Awake").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(status.failed ? status.tint : status.active ? .green : .secondary)
                            .frame(width: 6, height: 6)
                        Text(status.status).font(.system(size: 11))
                    }
                    .foregroundStyle(status.failed ? status.tint : status.active ? .green : .secondary)
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 4) {
                    ForEach(AwakeMode.allCases, id: \.self) { mode in
                        Button { state.selectAwakeMode(mode) } label: {
                            Label(mode.label, systemImage: mode.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .foregroundStyle(state.awakeMode == mode ? status.tint : .white.opacity(0.66))
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(state.awakeMode == mode ? Color.white.opacity(0.09) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(mode.label) mode")
                        .accessibilityValue(state.awakeMode == mode ? "Selected" : "Not selected")
                    }
                }
                .padding(4).background(RoundedRectangle(cornerRadius: 11).fill(.black.opacity(0.45)))

                HStack(spacing: 11) {
                    Image(systemName: status.symbol).font(.system(size: 16))
                        .foregroundStyle(status.tint).frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 11).fill(status.tint.opacity(0.10)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.title).font(.system(size: 16, weight: .semibold))
                        Text(status.detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .frame(height: 42, alignment: .leading)
                VStack(spacing: 8) {
                    effect("This Mac", symbol: "laptopcomputer", value: status.active ? "Stays awake" : "Sleep allowed")
                    effect("Display", symbol: "display", value: status.displayOn ? "Stays on" : "Can sleep")
                }
                Divider()
                // Reserve the manual controls' space in every mode. Moving
                // the popover's anchor or resizing its window under a click
                // makes the mode selector feel as though it is running away.
                VStack(alignment: .leading, spacing: 0) {
                    if state.awakeMode == .manual {
                        manualControls(status)
                    } else {
                        Text(state.awakeMode == .auto
                             ? "Keeps this Mac awake while agents work or need you, and for 10 minutes afterward. The display can sleep."
                             : "Your normal macOS sleep settings apply. Choose Auto to follow agent activity, or Manual for a timed hold.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 150, alignment: .topLeading)
                Divider()
                Label(status.lockDescription, systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(Color(white: 0.065))
        }
    }

    private func effect(_ title: String, symbol: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private func manualControls(_ status: AwakeStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep awake for").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach([15, 30, 60, 0], id: \.self) { minutes in
                    let selected = state.keepAwakeMinutes == minutes
                    Button { state.holdAwake(minutes: minutes) } label: {
                        Text(minutes == 0 ? "Until stopped" : minutes == 60 ? "1 hour" : "\(minutes) min")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.horizontal, 5).padding(.vertical, 8)
                            .foregroundStyle(selected ? status.tint : .white.opacity(0.66))
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(selected ? status.tint.opacity(0.12) : .white.opacity(0.045)))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selected ? status.tint.opacity(0.45) : .white.opacity(0.12)))
                            .fixedSize(horizontal: minutes == 0, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(minutes == 0 ? "Keep awake until stopped" : "Keep awake for \(minutes) minutes")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
            Toggle(isOn: $state.keepScreenOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep display on").font(.system(size: 12))
                    Text("Mac stays awake with this off, too.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small).tint(status.tint)
            .accessibilityLabel("Keep display on")
            HStack {
                Text("After this hold: \(state.autoAwake ? "Auto" : "Off")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("End hold") { state.releaseAwakeHold() }
                    .controlSize(.small)
                    .help(state.autoAwake ? "Return to Auto mode" : "Allow normal sleep")
            }
        }
    }
}
