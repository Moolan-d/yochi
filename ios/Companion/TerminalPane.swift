import SwiftUI

/// The session's terminal, read-only (`/v0/observe`): never the active
/// viewer, so the desktop's grid is untouched.
struct TerminalPane: View {
    let session: String
    let config: GatewayConfig
    /// The grid on screen, for the title; nil until attached.
    @Binding var grid: TerminalGrid?

    @State private var observer = TerminalObserver()
    @State private var feed = TerminalFeed()
    @State private var attempt = 0
    @State private var resizeRestart: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

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
        .safeAreaInset(edge: .bottom) { banner }
        .onChange(of: observer.phase) { _, phase in
            guard case .observing(let cols, let rows) = phase else { return }
            let size = TerminalGrid(cols: cols, rows: rows)
            if grid == nil {
                grid = size
            } else if grid != size {
                restartAfterResize()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .failed = observer.phase { start() }
        }
        .task { start() }
        .onDisappear {
            resizeRestart?.cancel()
            observer.stop()
        }
    }

    /// When a terminal is already on screen, problems show below it instead of replacing it.
    @ViewBuilder
    private var banner: some View {
        if grid != nil {
            Group {
                switch observer.phase {
                case .closed(let reason):
                    BannerLabel(text: reason, systemImage: "stop.circle")
                case .failed(let reason):
                    HStack {
                        BannerLabel(text: "连接中断：\(reason)", systemImage: "wifi.exclamationmark")
                        Button("重试", action: start).buttonStyle(.bordered)
                    }
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func start() {
        let feed = TerminalFeed()
        self.feed = feed
        grid = nil
        attempt += 1
        observer.onBytes = { feed.receive($0) }
        observer.start(config, session: session)
    }

    /// Bytes drawn for the new size would land in a grid of the old one, and
    /// the local terminal would rewrap what it already holds; neither matches
    /// the desktop any more. A fresh attach starts from core's exact screen.
    private func restartAfterResize() {
        resizeRestart?.cancel()
        resizeRestart = Task {
            // Dragging a desktop split resizes many times; attach once it settles.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            start()
        }
    }
}

struct BannerLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}
