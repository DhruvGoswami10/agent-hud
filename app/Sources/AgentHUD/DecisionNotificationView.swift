import SwiftUI

struct DecisionNotificationView: View {
    @ObservedObject var state: AppState
    let event: AgentEvent

    var body: some View {
        if let prompt = event.prompt {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: prompt.kind == "permission" ? "hand.raised.fill" : "questionmark.bubble.fill")
                            .foregroundStyle(EventKind.attention.color)
                        Text(event.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(prompt.kind == "permission" ? "PERMISSION" : "NEEDS YOUR INPUT")
                            .font(.system(size: 8, weight: .bold)).kerning(0.6)
                            .foregroundStyle(EventKind.attention.color)
                    }
                    Text(prompt.title).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).frame(height: 18, alignment: .leading)
                    ScrollView {
                        Text(prompt.detail.isEmpty ? event.message : prompt.detail)
                            .font(.system(size: 11.5, design: prompt.kind == "permission" ? .monospaced : .default))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(height: 104)
                }
                .contentShape(Rectangle())
                .onTapGesture { state.dismissNotification() }

                HStack(spacing: 8) {
                    if state.canAnswerApproval(prompt.id) {
                        Button("Approve once") { state.answerApproval(prompt.id, as: .allow) }
                            .buttonStyle(DecisionButtonStyle(color: Color(red: 0.22, green: 0.65, blue: 0.37)))
                            .help("Allow only this request. No future permission rule is saved.")
                        Button("Reject") { state.answerApproval(prompt.id, as: .deny) }
                            .buttonStyle(DecisionButtonStyle(color: .red.opacity(0.16), text: Color(red: 1, green: 0.4, blue: 0.37)))
                    } else {
                        Text(state.decisionResults[prompt.id] ?? "Answer in Claude")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                    Button("Go to session") { state.focusEvent(event) }
                        .buttonStyle(DecisionButtonStyle(color: .white.opacity(0.14)))
                        .disabled(state.navigationBusy)
                }
                .controlSize(.small)
                .frame(height: 26)

                HStack(spacing: 6) {
                    if !state.queuedAgentNotifications.isEmpty {
                        Text("\(state.queuedAgentNotifications.count) more queued")
                            .foregroundStyle(EventKind.attention.color)
                        Text("·")
                    }
                    Text("Click the card to dismiss")
                    Spacer()
                    if state.canAnswerApproval(prompt.id) { Text("This request only") }
                }
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .contentShape(Rectangle())
                .onTapGesture { state.dismissNotification() }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .accessibilityAction(named: Text("Dismiss notification")) { state.dismissNotification() }
        }
    }
}

private struct DecisionButtonStyle: ButtonStyle {
    let color: Color
    var text: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(configuration.isPressed ? 0.65 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
