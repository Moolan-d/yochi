import SwiftUI

/// What the Agent waits for, with native answers where Claude Code's dialog
/// is predictable: approve or deny a permission, pick one option of a single
/// question. Anything else is left to the desk. The Gateway refuses an
/// answer if the desk has answered meanwhile (ADR 0004).
struct PendingCard: View {
    let pending: PendingQuestion
    let tool: ConversationItem?
    let answer: (String) async -> GatewayClient.KeysResult

    @State private var answering: String?
    @State private var failure: String?
    @State private var confirmingDeny = false
    @State private var answered = 0

    private var question: AgentQuestion? { Self.question(pending, tool: tool) }

    /// A single single-select question, which numbered keys can answer.
    private static func question(_ pending: PendingQuestion, tool: ConversationItem?) -> AgentQuestion? {
        guard pending.kind == "question", let questions = tool?.questions, questions.count == 1,
              let question = questions.first, !question.multiSelect,
              (1...9).contains(question.options.count) else { return nil }
        return question
    }

    /// Whether the card offers answers of its own rather than only
    /// pointing at the desk.
    static func answers(_ pending: PendingQuestion, tool: ConversationItem?) -> Bool {
        (pending.kind == "permission" && tool != nil) || question(pending, tool: tool) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            detail
            actions
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.orange.opacity(0.5))
        }
        .disabled(answering != nil)
        .sensoryFeedback(.success, trigger: answered)
        .onChange(of: pending) { _, _ in
            answering = nil
            failure = nil
        }
        .confirmationDialog(denyTitle, isPresented: $confirmingDeny, titleVisibility: .visible) {
            Button("Deny", role: .destructive) { send("deny") }
            // iOS 26 can drop `.cancel` here; an explicit plain button remains.
            Button("Back") {}
        } message: {
            Text("The Agent will stop this turn and wait for your next message.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pendingCard")
    }

    private var title: String {
        switch pending.kind {
        case "permission": String(localized: "Agent Asks for Approval")
        case "question": String(localized: "Agent Has a Question")
        case "auth": String(localized: "Agent Needs a Sign-In")
        default: String(localized: "Agent Is Waiting")
        }
    }

    private var symbol: String {
        switch pending.kind {
        case "permission": "hand.raised.fill"
        case "question": "questionmark.bubble.fill"
        case "auth": "key.fill"
        default: "hourglass"
        }
    }

    private var denyTitle: String {
        pending.kind == "question" ? String(localized: "Cancel This Question?") : String(localized: "Deny This Request?")
    }

    @ViewBuilder
    private var detail: some View {
        if let question {
            Text(question.question).font(.body)
        } else if pending.kind == "permission", let tool {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name ?? String(localized: "Tool")).font(.footnote).foregroundStyle(.secondary)
                Text(tool.summary ?? "")
                    .font(.callout.monospaced())
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        } else if let message = pending.message {
            Text(message).font(.callout)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if pending.kind == "permission" && tool != nil {
            HStack(spacing: 10) {
                Button(role: .destructive) { confirmingDeny = true } label: {
                    choiceLabel("Deny", choice: "deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChoiceStyle(role: .destructive))
                .accessibilityIdentifier("denyPending")
                Button { send("allow") } label: {
                    choiceLabel(String(localized: "Approve"), choice: "allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChoiceStyle(role: .prominent))
                .accessibilityIdentifier("allowPending")
            }
            .font(.body.weight(.semibold))
            deskNote(String(localized: "For other options (such as Always Allow), choose on the computer"))
        } else if let question {
            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button { send("\(index + 1)") } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.body.weight(.medium))
                                if let description = option.description, !description.isEmpty {
                                    Text(description).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if answering == "\(index + 1)" { ProgressView() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(ChoiceStyle())
                    .accessibilityIdentifier("option-\(index + 1)")
                }
            }
            HStack {
                deskNote(String(localized: "For other answers, type them on the computer"))
                Spacer()
                Button("Cancel Question", role: .destructive) { confirmingDeny = true }
                    .font(.footnote)
            }
        } else {
            deskNote(String(localized: "Answer on the computer"))
        }
    }

    private func choiceLabel(_ title: String, choice: String) -> some View {
        HStack(spacing: 6) {
            if answering == choice { ProgressView() }
            Text(title)
        }
    }

    private func deskNote(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func send(_ choice: String) {
        answering = choice
        failure = nil
        Task {
            switch await answer(choice) {
            case .pressed:
                answered += 1
                // The card goes away once core stops reporting blocked; if it
                // doesn't, let the user try again or go to the terminal.
                try? await Task.sleep(for: .seconds(8))
                if answering == choice { answering = nil }
            case .failed(let kind, let message):
                answering = nil
                failure = switch kind {
                case "changed": String(localized: "The terminal has changed. Check its latest state")
                case "not_found", "finished": String(localized: "The session has ended")
                case "unavailable", "machine_unknown": String(localized: "Not connected, or herdr-core is unavailable")
                default: message
                }
            case .unknown:
                answering = nil
                failure = String(localized: "Result unknown. Check on the computer")
            }
        }
    }
}

/// A filled choice that reads as tappable on the card; the system bordered
/// style's fill is nearly invisible on a white card. One style for every
/// choice keeps 拒绝 and 批准 the same height.
struct ChoiceStyle: ButtonStyle {
    enum Role { case normal, destructive, prominent }
    var role = Role.normal
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(role == .prominent ? Color.white : role == .destructive ? Color.red : Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .tint(role == .prominent ? Color.white : Color.secondary)
            .background(role == .prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                        in: .rect(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.5)
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
    }
}
