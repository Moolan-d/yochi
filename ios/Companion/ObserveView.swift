import SwiftUI

/// One session's terminal, read-only (Observer). Typing would make the phone
/// the active viewer and resize the desktop terminal, so it is not offered here.
struct ObserveView: View {
    let session: Session
    let config: GatewayConfig

    @State private var observer = TerminalObserver()
    @State private var feed = TerminalFeed()
    @State private var grid: TerminalGrid?
    @State private var attempt = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let grid {
                ObservedTerminal(feed: feed, grid: grid)
                    .id(attempt)
                    .ignoresSafeArea(edges: .bottom)
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
        .safeAreaInset(edge: .bottom) { banner }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(session.title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
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
        let place = session.machine ?? "本机"
        if let grid { return "仅查看 · \(place) · \(grid.cols)×\(grid.rows)" }
        return "仅查看 · \(place)"
    }

    private func start() {
        let feed = TerminalFeed()
        self.feed = feed
        grid = nil
        attempt += 1
        observer.onBytes = { feed.receive($0) }
        observer.start(config, session: session.id)
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
