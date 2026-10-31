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
    @State private var delivery: Delivery?
    @State private var confirmingBlocked = false
    @Environment(\.scenePhase) private var scenePhase

    init(session: Session, config: GatewayConfig, client: GatewayClient) {
        self.session = session
        self.config = config
        self.client = client
        _draft = State(initialValue: DraftStore.load(host: config.host, session: session.id))
    }

    private var currentSession: Session {
        client.sessions.first { $0.id == session.id } ?? session
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
            DraftStore.save(draft, host: config.host, session: session.id)
        }
        .onChange(of: currentSession.turn) { _, _ in updateResponse() }
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
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
        delivery = .sending(text: text)
        Task {
            let result = await client.sendMessage(session: session.id, text: text, force: force)
            switch result {
            case .accepted(let turn, let status, let started):
                delivery = .sent(text: text, turn: turn, status: status, started: started)
                draft = ""
                updateResponse()
            case .failed(let kind, _) where kind == "timeout" || kind == "unknown":
                delivery = .unknown(text: text)
            case .failed(let kind, let message):
                delivery = .failed(text: text, kind: kind, message: message)
                confirmingBlocked = kind == "blocked"
            case .unknown:
                delivery = .unknown(text: text)
            }
        }
    }

    private func updateResponse() {
        guard let delivery, case .sent(let text, let sentTurn, let status, _) = delivery,
              currentSession.turn > sentTurn else { return }
        self.delivery = .turnCompleted(text: text, status: status)
    }
}

private enum Delivery {
    case sending(text: String)
    case sent(text: String, turn: UInt64, status: String?, started: Bool?)
    case turnCompleted(text: String, status: String?)
    case failed(text: String, kind: String, message: String)
    case unknown(text: String)

    var text: String {
        switch self {
        case .sending(let text), .sent(let text, _, _, _), .turnCompleted(let text, _),
             .failed(let text, _, _), .unknown(let text):
            text
        }
    }

    var state: String {
        switch self {
        case .sending: "发送中…"
        case .sent(_, _, let status, let started): AgentMessagePresentation.accepted(status: status, started: started)
        case .turnCompleted(_, let status): AgentMessagePresentation.afterTurn(status: status)
        case .failed(_, let kind, let message): Self.failure(kind: kind, message: message)
        case .unknown: "结果未知，可能已发送"
        }
    }

    var symbol: String {
        switch self {
        case .sending: "ellipsis.circle"
        case .sent: "checkmark.circle"
        case .turnCompleted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .turnCompleted: .green
        case .failed: .red
        case .unknown: .orange
        default: .secondary
        }
    }

    private static func failure(kind: String, message: String) -> String {
        switch kind {
        case "blocked": "Agent 正在等待确认，尚未发送"
        case "not_found", "finished": "会话已结束"
        case "machine_unknown", "unavailable": "未连接或 herdr-core 不可用"
        case "status_mismatch": "Agent 状态已变化，请重试"
        case "too_long": "消息过长（最多 16 KiB）"
        case "invalid_params": "消息为空或参数无效"
        case "config": "herdr-core 配置不可用"
        default: message.isEmpty ? "发送失败" : "发送失败（\(message)）"
        }
    }
}

private struct DeliveryBanner: View {
    let delivery: Delivery

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

private enum DraftStore {
    static func load(host: String, session: String) -> String {
        UserDefaults.standard.string(forKey: key(host: host, session: session)) ?? ""
    }

    static func save(_ draft: String, host: String, session: String) {
        UserDefaults.standard.set(draft, forKey: key(host: host, session: session))
    }

    private static func key(host: String, session: String) -> String {
        "agent-message.draft.\(host).\(session)"
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
