import SwiftUI

/// One session on one page: an Agent's conversation, or for a shell its
/// terminal in Observer mode. Agent Messages, key presses and answers never
/// attach, so the phone never becomes the active viewer or resizes the
/// desktop's grid.
struct ObserveView: View {
    let session: Session
    let config: GatewayConfig
    let client: GatewayClient

    @State private var conversation = ConversationFeed()
    @State private var screen = ScreenFeed()
    @State private var grid: TerminalGrid?
    /// The page between the navigation bar and the bottom, keyboard excluded.
    @State private var pageHeight: CGFloat = 0
    @State private var draft: String
    @State private var confirmingBlocked = false
    @State private var keys = KeyPresser()
    @State private var stopping = false
    @State private var stopNotice: String?
    /// The mode a switch from the phone reached, shown until the transcript
    /// records a newer one with the next message.
    @State private var switchedMode: PermissionMode?
    @State private var seenModes: Set<PermissionMode> = []
    @State private var switchingMode = false
    @State private var modeFailure: String?
    @AppStorage(TerminalTextSize.key) private var terminalFontSize = TerminalTextSize.standard
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(session: Session, config: GatewayConfig, client: GatewayClient) {
        self.session = session
        self.config = config
        self.client = client
        _draft = State(initialValue: AgentMessageStore.draft(host: config.host, session: session.id))
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

    private var queued: QueuedMessage? {
        client.queuedMessage(session: session.id)
    }

    /// While the Agent works a message waits on the phone for the turn to end.
    private var queuesMessage: Bool {
        currentSession.status?.state == "working"
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The mode line when the screen shows it (the transcript has none
    /// before the first message); else the last switch, else the transcript.
    private var shownMode: PermissionMode? {
        screenMode ?? switchedMode ?? conversation.mode
    }

    /// What the mode line under Claude Code's prompt shows now.
    private var screenMode: PermissionMode? {
        screen.screen.flatMap(PermissionMode.read)
    }

    /// Each press is checked on the screen, which the Gateway doesn't send
    /// while the Agent works; a dialog hides the mode line too.
    private var canSwitchMode: Bool {
        currentSession.status?.state != "working" && !switchingMode && screenMode != nil
    }

    /// With nothing to send while the Agent works, the send button stops it.
    /// Not while it waits: Esc would cancel the dialog, which its card does.
    private var showsStop: Bool {
        currentSession.status?.state == "working" && !isSending
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Claude Code draws some dialogs only on screen; they show on the
    /// conversation page from the screen read, not while the Agent works
    /// (the Gateway sends no screen then, so the last one is stale).
    private var screenResult: DialogParseResult {
        guard isConversation, currentSession.status?.state != "working" else { return .none }
        return screen.result
    }

    /// Claude Code always has the conversation page, even before its first
    /// message: its dialogs show there from the screen. Other programs have
    /// it only once the Gateway follows a transcript for them; a shell shows
    /// its terminal.
    private var isConversation: Bool {
        QuickCommand.isClaudeCode(currentSession) || conversation.phase == .following
    }

    var body: some View {
        Group {
            if isConversation {
                ConversationPane(feed: conversation, status: currentSession.status,
                                 keyboardShown: composerFocused) {
                    conversation.start(config, session: session.id)
                }
            } else {
                TerminalPane(session: session.id, config: config, grid: $grid)
            }
        }
        // Tapping the conversation or the terminal puts the keyboard away, as
        // do dragging and the keyboard's 收起 button above it.
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(currentSession.title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(isConversation
                    ? "可查看对话、批准或回答 Agent 的请求、发送整段消息，都不会接管终端或改变桌面上的终端尺寸。"
                    : "可查看终端、按常用按键、发送整段消息，都不会接管终端或改变桌面上的终端尺寸。")
            }
            if !isConversation {
                ToolbarItem(placement: .topBarTrailing) { textSizeMenu }
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
        .onChange(of: currentSession.status?.state) { _, state in
            if state != "working" { stopNotice = nil }
        }
        .onChange(of: conversation.mode) { _, mode in
            switchedMode = nil
            if let mode { seenModes.insert(mode) }
        }
        .onChange(of: screenMode) { _, mode in
            if let mode { seenModes.insert(mode) }
        }
        // Returning while a send was in flight restores the draft from before the
        // send; once it is accepted, this view clears it too.
        .onChange(of: delivery) { _, delivery in
            if case .sent(let text, _, _, _) = delivery, draft == text { draft = "" }
        }
        // A session can turn out to be Claude Code after it opens: one just
        // started from the phone, or a shell that started it. The page then
        // turns to the conversation.
        .onChange(of: QuickCommand.isClaudeCode(currentSession)) { _, isClaudeCode in
            guard isClaudeCode else { return }
            screen.start(config, session: session.id)
        }
        // A dialog card needs the room the keyboard takes. The composer can
        // take the keyboard back once sending enables it again, which can
        // be after the card appeared, so both moments count.
        .onChange(of: screenResult.fingerprint) { _, _ in makeRoomForDialog() }
        .onChange(of: isSending) { _, _ in makeRoomForDialog() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .failed = conversation.phase {
                conversation.start(config, session: session.id)
            }
        }
        .task {
            conversation.start(config, session: session.id)
            if QuickCommand.isClaudeCode(session) { screen.start(config, session: session.id) }
        }
        .onDisappear {
            conversation.stop()
            screen.stop()
        }
    }

    /// Disabling the composer while it sends clears the focus state but
    /// keeps the keyboard up, so the first responder is resigned as well.
    private func makeRoomForDialog() {
        guard screenResult.fingerprint != nil, !isSending else { return }
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Status stays above the composer; safeAreaInset also gives the software
    /// keyboard room instead of covering the content.
    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 8) {
            if let dialog = screenResult.dialog {
                // Under half the page keeps the card under the navigation bar and
                // some of the conversation in view, whatever the text size.
                DialogCard(dialog: dialog, maxBodyHeight: pageHeight > 0 ? max(120, pageHeight * 0.45) : 300,
                           run: { plan, dialog in await dialogRunner.run(plan, on: dialog) })
                .id(dialog.fingerprint.value)
            } else if isConversation, let pending = conversation.pending,
                      screenResult.excerpt == nil || PendingCard.answers(pending, tool: conversation.pendingTool) {
                // What the screen shows beats a card that only says to
                // answer at the desk.
                PendingCard(pending: pending, tool: conversation.pendingTool,
                            answer: { choice in
                                await client.answer(session: session.id, choice: choice, expect: pending.message)
                            })
            } else if let excerpt = screenResult.excerpt {
                GenericDialogCard(excerpt: excerpt, press: { await press($0, on: excerpt) })
                    .id(excerpt.fingerprint.value)
            }
            if !isConversation, let failure = keys.failure {
                BannerLabel(text: failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let modeFailure {
                BannerLabel(text: modeFailure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("modeFailure")
            }
            if let stopNotice {
                BannerLabel(text: stopNotice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("stopNotice")
            }
            if let delivery { DeliveryBanner(delivery: delivery) }
            if let queued {
                QueuedBanner(message: queued,
                             release: queued.release(state: currentSession.status?.state, turn: currentSession.turn),
                             send: { client.sendQueued(session: session.id) },
                             withdraw: withdrawQueued)
            }
            if isConversation, let shownMode { modeChip(shownMode) }
            if !isConversation {
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
                Group {
                    if showsStop {
                        Button { stop() } label: {
                            Group {
                                if stopping {
                                    ProgressView()
                                } else {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 30))
                                }
                            }
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle().inset(by: -5))
                        }
                        .disabled(stopping)
                        .accessibilityLabel("停止 Agent")
                        .accessibilityIdentifier("stopAgent")
                    } else {
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
                        .accessibilityLabel(queuesMessage ? "排队发送" : "发送消息")
                        .accessibilityHint(queuesMessage ? "这一轮结束后发出" : "")
                        .accessibilityIdentifier("sendAgentMessage")
                    }
                }
                .padding(.trailing, 5)
                .padding(.bottom, 5)
            }
            .background(Color(.systemBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(.separator))
            }
        }
    }

    /// The terminal's text size is a per-install preference, not a takeover:
    /// only this phone's rendering changes, and core's grid is untouched.
    private var textSizeMenu: some View {
        Menu {
            Section("字号 \(Int(terminalFontSize))") {
                Button("增大字号", systemImage: "textformat.size.larger") {
                    terminalFontSize = TerminalTextSize.clamped(terminalFontSize + 1)
                }
                .disabled(terminalFontSize >= TerminalTextSize.range.upperBound)
                Button("减小字号", systemImage: "textformat.size.smaller") {
                    terminalFontSize = TerminalTextSize.clamped(terminalFontSize - 1)
                }
                .disabled(terminalFontSize <= TerminalTextSize.range.lowerBound)
                if terminalFontSize != TerminalTextSize.standard {
                    Button("恢复默认字号") { terminalFontSize = TerminalTextSize.standard }
                }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel("终端字号")
        .accessibilityIdentifier("terminalTextSize")
    }

    private var subtitle: String {
        let place = currentSession.machine ?? "本机"
        if isConversation { return "对话 · \(place)" }
        var parts = ["终端", place]
        if let grid { parts.append("\(grid.cols)×\(grid.rows)") }
        return parts.joined(separator: " · ")
    }

    private var dialogRunner: DialogRunner {
        DialogRunner(
            session: session.id, feed: screen,
            press: { keys in await client.pressKeys(session: session.id, keys: keys) },
            agentWorking: { currentSession.status?.state == "working" })
    }

    /// Esc for a dialog the phone can't read, if the screen still shows it.
    private func press(_ key: String, on excerpt: GenericDialogExcerpt) async -> String? {
        guard screen.result.fingerprint?.matches(excerpt.fingerprint) == true else {
            return "终端里的对话框已变化，请看最新内容"
        }
        switch await client.pressKeys(session: session.id, keys: [key]) {
        case .pressed: return nil
        case .failed(_, let message): return message
        case .unknown: return "按键结果未知"
        }
    }

    private func send(force: Bool = false) {
        guard canSend else { return }
        let text = draft
        if queuesMessage {
            client.enqueue(text, session: session.id, turn: currentSession.turn)
            AgentMessageStore.clearDraft(host: config.host, session: session.id)
            draft = ""
            return
        }
        // Marked before the task starts, so a second tap can't send it twice.
        client.remember(.sending(text: text), host: config.host, session: session.id)
        Task {
            switch await client.submit(text, host: config.host, session: session.id, force: force) {
            case .accepted:
                // Clear the persisted draft before any view teardown: leaving
                // while sending must not make the sent text reappear as a draft.
                AgentMessageStore.clearDraft(host: config.host, session: session.id)
                draft = ""
                updateResponse()
            case .failed(let kind, _):
                confirmingBlocked = kind == "blocked"
            case .unknown:
                break
            }
        }
    }

    /// The queued text goes back ahead of whatever the draft holds now.
    private func withdrawQueued() {
        guard let text = client.withdrawQueued(session: session.id) else { return }
        draft = draft.isEmpty ? text : text + "\n\n" + draft
    }

    /// A pop-up button: the system menu marks the current mode, and picking
    /// another one starts the switch; the chip changes once the screen agrees.
    private func modeChip(_ mode: PermissionMode) -> some View {
        Menu {
            Picker("权限模式", selection: Binding(get: { mode }, set: switchMode(to:))) {
                ForEach(PermissionMode.targets(including: seenModes), id: \.self) { target in
                    Label(target.title, systemImage: target.symbol).tag(target)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                if switchingMode {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: mode.symbol)
                }
                Text(mode.title)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(mode == .bypassPermissions ? .red : .secondary)
        .disabled(!canSwitchMode)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityLabel("权限模式")
        .accessibilityValue(mode.title)
        .accessibilityHint(canSwitchMode ? "按 Shift+Tab 切换，每按一次核对终端画面" : "Agent 工作中或终端里有对话框时不能切换")
        .accessibilityIdentifier("permissionMode")
    }

    private func switchMode(to target: PermissionMode) {
        guard canSwitchMode, target != screenMode else { return }
        switchingMode = true
        modeFailure = nil
        let switcher = PermissionModeSwitcher(
            feed: screen,
            press: { keys in await client.pressKeys(session: session.id, keys: keys) },
            agentWorking: { currentSession.status?.state == "working" })
        Task {
            if case .failed(let reason) = await switcher.run(to: target) { modeFailure = reason }
            // The screen says where it ended, even after a failure.
            if let reached = screenMode { switchedMode = reached }
            switchingMode = false
        }
    }

    /// No confirmation: Esc only ends this turn. A second press is the
    /// user's choice; core never escalates on its own.
    private func stop() {
        guard !stopping else { return }
        stopping = true
        stopNotice = nil
        Task {
            stopNotice = AgentMessagePresentation.stopped(await client.interrupt(session: session.id))
            stopping = false
        }
    }

    private func updateResponse() {
        guard let delivery, case .sent(let text, let sentTurn, let status, _) = delivery,
              currentSession.turn > sentTurn else { return }
        client.remember(.turnCompleted(text: text, status: status), host: config.host, session: session.id)
    }
}

private struct QueuedBanner: View {
    let message: QueuedMessage
    let release: QueuedMessage.Release
    let send: () -> Void
    let withdraw: () -> Void

    private var title: String {
        if let failure = message.failure { return "没有发出：\(failure)" }
        return release == .ask ? "这一轮早已结束，要现在发吗？" : "排队中 · 这一轮结束后发出"
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(message.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: message.failure == nil ? "clock" : "exclamationmark.triangle.fill")
                    .foregroundStyle(message.failure == nil ? Color.secondary : Color.red)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("queuedMessage")
            if release == .ask {
                Button("发送", action: send)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sendQueued")
            }
            Button("撤回", action: withdraw)
                .buttonStyle(.bordered)
                .accessibilityHint("放回输入框")
                .accessibilityIdentifier("withdrawQueued")
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
        .padding(.horizontal, 4)
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
