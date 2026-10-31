import SwiftUI

/// One session's terminal in Observer mode. Agent Messages use terminal.send,
/// so offering them never makes the phone the active viewer or resizes the grid.
struct ObserveView: View {
    let session: Session
    let config: GatewayConfig
    let client: GatewayClient

    @State private var observer = TerminalObserver()
    @State private var feed = TerminalFeed()
    @State private var grid: TerminalGrid?
    @State private var attempt = 0
    @State private var draft: String
    @State private var confirmingBlocked = false
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

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            if let grid {
                ObservedTerminal(feed: feed, grid: grid)
                    .id(attempt)
            }
            switch observer.phase {
            case .connecting where grid == nil:
                ProgressView("正在连接…")
            case .failed(let reason) where grid == nil:
                ContentUnavailableView {
                    Label("无法查看终端", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("重试", action: start)
                        .buttonStyle(.borderedProminent)
                }
            case .closed(let reason) where grid == nil:
                ContentUnavailableView("会话已结束", systemImage: "stop.circle", description: Text(reason))
            default:
                EmptyView()
            }
        }
        .safeAreaInset(edge: .bottom) { bottomPanel }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(currentSession.title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("可查看终端并发送整段 Agent 消息，不会接管终端或逐键输入。")
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
        .onChange(of: observer.phase) { _, phase in
            if case .observing(let cols, let rows) = phase {
                grid = TerminalGrid(cols: cols, rows: rows)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .failed = observer.phase { start() }
        }
        .task { start() }
        .onDisappear { observer.stop() }
    }

    /// Terminal and message status stay above the composer; safeAreaInset also
    /// gives the software keyboard room instead of covering the terminal.
    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 0) {
            banner
            if let delivery { DeliveryBanner(delivery: delivery) }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("给 Agent 发消息", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSending)
                    .accessibilityIdentifier("agentMessageField")
                Button { send() } label: {
                    Group {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                    }
                    .frame(width: 32, height: 32)
                    // Keep the icon small but the HIG-minimum tap target.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(!canSend)
                .accessibilityLabel("发送消息")
                .accessibilityIdentifier("sendAgentMessage")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    /// When a terminal is already on screen, problems show below it instead of replacing it.
    @ViewBuilder
    private var banner: some View {
        if grid != nil {
            switch observer.phase {
            case .closed(let reason):
                BannerLabel(text: reason, systemImage: "stop.circle")
            case .failed(let reason):
                HStack {
                    BannerLabel(text: "连接中断：\(reason)", systemImage: "wifi.exclamationmark")
                    Button("重试", action: start).buttonStyle(.bordered)
                }
                .padding(.trailing)
                .background(.bar)
            default:
                EmptyView()
            }
        }
    }

    private var subtitle: String {
        let place = currentSession.machine ?? "本机"
        if let grid { return "查看 · \(place) · \(grid.cols)×\(grid.rows)" }
        return "查看 · \(place)"
    }

    private func start() {
        let feed = TerminalFeed()
        self.feed = feed
        grid = nil
        attempt += 1
        observer.onBytes = { feed.receive($0) }
        observer.start(config, session: session.id)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(delivery.text)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Label(delivery.state, systemImage: delivery.symbol)
                .foregroundStyle(delivery.color)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct BannerLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
    }
}
