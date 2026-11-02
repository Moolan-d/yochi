import SwiftUI

/// One session: its Agent's conversation, or its terminal in Observer mode.
/// Agent Messages, key presses and answers never attach, so the phone never
/// becomes the active viewer or resizes the desktop's grid.
struct ObserveView: View {
    enum Mode: Hashable {
        case conversation, terminal
    }

    let session: Session
    let config: GatewayConfig
    let client: GatewayClient

    @State private var conversation = ConversationFeed()
    @State private var mode: Mode
    @State private var grid: TerminalGrid?
    @State private var draft: String
    @State private var confirmingBlocked = false
    @State private var keys = KeyPresser()
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(session: Session, config: GatewayConfig, client: GatewayClient) {
        self.session = session
        self.config = config
        self.client = client
        _draft = State(initialValue: AgentMessageStore.draft(host: config.host, session: session.id))
        _mode = State(initialValue: QuickCommand.isClaudeCode(session) ? .conversation : .terminal)
    }

    private var currentSession: Session {
        client.sessions.first { $0.id == session.id } ?? session
    }

    /// Lives in the client so a result that arrives after this view leaves is
    /// still there on return, and never resurrects the sent draft.
    private var delivery: AgentDelivery? {
        client.delivery(host: config.host, session: session.id)
    }

    private var isSending: Bool {
        guard let delivery else { return false }
        if case .sending = delivery { return true }
        return false
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only Agents whose transcript the Gateway reads have a conversation.
    private var hasConversation: Bool {
        switch conversation.phase {
        case .unsupported: false
        case .connecting: mode == .conversation
        default: true
        }
    }

    var body: some View {
        Group {
            switch mode {
            case .conversation:
                ConversationPane(feed: conversation, status: currentSession.status,
                                 keyboardShown: composerFocused) {
                    conversation.start(config, session: session.id)
                }
            case .terminal:
                TerminalPane(session: session.id, config: config, grid: $grid)
            }
        }
        // Tapping the conversation or the terminal puts the keyboard away, as
        // do dragging and the keyboard's 收起 button above it.
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
        .safeAreaInset(edge: .top, spacing: 0) {
            if hasConversation {
                Picker("显示", selection: $mode) {
                    Text("对话").tag(Mode.conversation)
                    Text("终端").tag(Mode.terminal)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("sessionMode")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(currentSession.title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("可查看对话或终端、批准或回答 Agent 的请求、按常用按键、发送整段消息，都不会接管终端或改变桌面上的终端尺寸。")
            }
        }
        .confirmationDialog("仍然发送消息？", isPresented: $confirmingBlocked, titleVisibility: .visible) {
            Button("仍然发送") { send(force: true) }
            // iOS 26 can drop `.cancel` here; an explicit plain button remains.
            Button("不发送") {}
        } message: {
            Text("Agent 正在等待确认，消息可能被当作对话框的回答")
        }
        .onChange(of: draft) { _, draft in
            AgentMessageStore.saveDraft(draft, host: config.host, session: session.id)
        }
        .onChange(of: currentSession.turn, initial: true) { _, _ in updateResponse() }
        // Returning while a send was in flight restores the draft from before the
        // send; once it is accepted, this view clears it too.
        .onChange(of: delivery) { _, delivery in
            if case .sent(let text, _, _, _) = delivery, draft == text { draft = "" }
        }
        .onChange(of: conversation.phase) { _, phase in
            if phase == .unsupported { mode = .terminal }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .failed = conversation.phase {
                conversation.start(config, session: session.id)
            }
        }
        .task { conversation.start(config, session: session.id) }
        .onDisappear { conversation.stop() }
    }

    /// Status stays above the composer; safeAreaInset also gives the software
    /// keyboard room instead of covering the content.
    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 8) {
            if mode == .conversation, let pending = conversation.pending {
                PendingCard(pending: pending, tool: conversation.pendingTool,
                            answer: { choice in
                                await client.answer(session: session.id, choice: choice, expect: pending.message)
                            },
                            openTerminal: { mode = .terminal })
            }
            if mode == .terminal, let failure = keys.failure {
                BannerLabel(text: failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let delivery { DeliveryBanner(delivery: delivery) }
            if mode == .terminal {
                TerminalKeyBar(keyboardShown: composerFocused,
                               toggleKeyboard: { composerFocused.toggle() }) { key in
                    keys.press(key.id, session: session.id, client: client)
                }
            }
            composer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Section("填入输入框") {
                    ForEach(QuickCommand.phrases, id: \.self) { phrase in
                        Button(phrase) { draft = QuickCommand.insert(phrase, into: draft) }
                    }
                }
                let commands = QuickCommand.commands(for: currentSession)
                if !commands.isEmpty {
                    Section("Claude Code 命令") {
                        ForEach(commands, id: \.self) { command in
                            Button(command) { draft = QuickCommand.insert(command, into: draft) }
                        }
                    }
                }
            } label: {
                Image(systemName: "bolt.circle")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isSending)
            .accessibilityLabel("快捷指令")
            .accessibilityIdentifier("quickCommands")

            HStack(alignment: .bottom, spacing: 4) {
                TextField("给 Agent 发消息", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.body)
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
                    .disabled(isSending)
                    .focused($composerFocused)
                    .accessibilityIdentifier("agentMessageField")
                Button { send() } label: {
                    Group {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                        }
                    }
                    .frame(width: 34, height: 34)
                    // A 44-point target around the smaller visible button.
                    .contentShape(Rectangle().inset(by: -5))
                }
                .disabled(!canSend)
                .padding(.trailing, 5)
                .padding(.bottom, 5)
                .accessibilityLabel("发送消息")
                .accessibilityIdentifier("sendAgentMessage")
            }
            .background(Color(.systemBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(.separator))
            }
        }
    }

    private var subtitle: String {
        let place = currentSession.machine ?? "本机"
        switch mode {
        case .conversation:
            return "对话 · \(place)"
        case .terminal:
            if let grid { return "查看 · \(place) · \(grid.cols)×\(grid.rows)" }
            return "查看 · \(place)"
        }
    }

    private func send(force: Bool = false) {
        guard canSend else { return }
        let text = draft
        client.remember(.sending(text: text), host: config.host, session: session.id)
        Task {
            let result = await client.sendMessage(session: session.id, text: text, force: force)
            switch result {
            case .accepted(let turn, let status, let started):
                client.remember(.sent(text: text, turn: turn, status: status, started: started),
                                host: config.host, session: session.id)
                // Clear the persisted draft before any view teardown: leaving
                // while sending must not make the sent text reappear as a draft.
                AgentMessageStore.clearDraft(host: config.host, session: session.id)
                draft = ""
                updateResponse()
                // A selector command exists only in the terminal; go there so
                // the key bar can finish it instead of the flow dead-ending.
                if mode == .conversation, QuickCommand.opensSelector(text) {
                    withAnimation(.snappy) { mode = .terminal }
                }
            case .failed(let kind, _) where kind == "timeout" || kind == "unknown":
                client.remember(.unknown(text: text), host: config.host, session: session.id)
            case .failed(let kind, let message):
                client.remember(.failed(text: text, kind: kind, message: message),
                                host: config.host, session: session.id)
                confirmingBlocked = kind == "blocked"
            case .unknown:
                client.remember(.unknown(text: text), host: config.host, session: session.id)
            }
        }
    }

    private func updateResponse() {
        guard let delivery, case .sent(let text, let sentTurn, let status, _) = delivery,
              currentSession.turn > sentTurn else { return }
        client.remember(.turnCompleted(text: text, status: status), host: config.host, session: session.id)
    }
}

private struct DeliveryBanner: View {
    let delivery: AgentDelivery

    var body: some View {
        HStack(spacing: 6) {
            Label(delivery.state, systemImage: delivery.symbol)
                .foregroundStyle(delivery.color)
                .layoutPriority(1)
            Text(delivery.text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
