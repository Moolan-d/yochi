import SwiftUI

struct SessionListView: View {
    let client: GatewayClient
    var retry: () -> Void
    var reenter: () -> Void

    /// This Mac first, then each remote machine by name.
    private var groups: [(machine: String?, sessions: [Session])] {
        Dictionary(grouping: client.sessions, by: \.machine)
            .map { ($0.key, $0.value) }
            .sorted { ($0.machine ?? "") < ($1.machine ?? "") }
    }

    var body: some View {
        List {
            // Sessions shown while disconnected are stale; say so above them.
            if client.phase != .connected && !client.sessions.isEmpty {
                Section {
                    Label(client.statusText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            ForEach(groups, id: \.machine) { group in
                Section(group.machine ?? "本机") {
                    ForEach(group.sessions) { session in
                        NavigationLink(value: session) { SessionRow(session: session) }
                    }
                }
            }
        }
        .overlay {
            if client.sessions.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch client.phase {
        case .disconnected, .connecting:
            ProgressView("正在连接…")
        case .failed(let reason):
            ContentUnavailableView {
                Label("无法连接 Gateway", systemImage: "wifi.exclamationmark")
            } description: {
                Text(reason)
            } actions: {
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        case .unauthorized:
            ContentUnavailableView {
                Label("配对已失效", systemImage: "key.slash")
            } description: {
                Text("Gateway 不再接受此 iPhone，可能已在主 Mac 上移除了它的配对。")
            } actions: {
                Button("重新配对", action: reenter)
                    .buttonStyle(.borderedProminent)
            }
        case .connected where !client.coreConnected:
            ContentUnavailableView(
                "无法访问 herdr-core",
                systemImage: "bolt.horizontal.circle",
                description: Text("Gateway 已连接，但主 Mac 上的 herdr-core 没有响应。"))
        case .connected:
            ContentUnavailableView(
                "没有运行中的会话",
                systemImage: "terminal",
                description: Text("在主 Mac 或已连接的机器上启动会话后，会显示在这里。"))
        }
    }
}

extension GatewayClient {
    var statusText: String {
        switch phase {
        case .disconnected: "未连接"
        case .connecting: "正在连接…"
        case .connected: coreConnected ? "已连接" : "herdr-core 不可用"
        case .failed(let reason): "连接失败：\(reason)"
        case .unauthorized: "配对已失效"
        }
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let status = session.status { StatusBadge(status: status) }
            }
            Text([session.program, session.cwd].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let message = session.status?.message {
                Text(message)
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The program's own status word, localized, with a symbol so it never relies on color alone.
private struct StatusBadge: View {
    let status: Status

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private var title: String {
        switch status.state {
        case "working": "工作中"
        case "blocked": "等待处理"
        case "error": "出错"
        case "done": "已完成"
        case "idle": "空闲"
        default: status.state
        }
    }

    private var symbol: String {
        switch status.state {
        case "working": "arrow.triangle.2.circlepath"
        case "blocked": "hand.raised.fill"
        case "error": "exclamationmark.triangle.fill"
        case "done": "checkmark.circle.fill"
        case "idle": "moon.zzz"
        default: "circle"
        }
    }

    private var color: Color {
        switch status.state {
        case "working": .blue
        case "blocked": .orange
        case "error": .red
        case "done": .green
        default: .secondary
        }
    }
}
