import SwiftUI

/// The session's terminal (`/v0/observe`), read-only: normally a watcher, so
/// the desktop's grid is untouched. A full-screen program can be taken over
/// instead, which resizes the terminal to the phone for as long as the page
/// stays open; it still never types.
struct TerminalPane: View {
    let session: String
    let config: GatewayConfig
    let client: GatewayClient
    /// The phone-sized grid on screen, for the title; nil until reflowed.
    @Binding var grid: TerminalGrid?

    @State private var observer = TerminalObserver()
    @State private var feed = TerminalFeed()
    /// Core's desktop grid, which the first paint is taken at.
    @State private var desktop: TerminalGrid?
    /// The grid the still-running terminal was resized to, when taken over.
    @State private var takeover: TerminalGrid?
    /// Whether the program is on the alternate screen (a full-screen TUI).
    @State private var fullScreen = false
    @State private var confirmingTakeover = false
    /// The desktop took the size back while this page had it.
    @State private var sizeDrift = false
    @State private var attempt = 0
    @State private var resizeRestart: Task<Void, Never>?
    @State private var selection: TerminalTextSelection?
    @State private var copiedNotice = false
    @State private var showingHistory = false
    /// A drag still under way when the history closes must not reopen it.
    @State private var historyClosedAt = Date.distantPast
    @AppStorage(TerminalTextSize.key) private var fontSize = TerminalTextSize.standard
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let takeover {
                ObservedTerminal(feed: feed, fontSize: Float(fontSize), desktopGrid: takeover,
                                 grid: $grid, selection: $selection, onScrollBack: showHistoryAfterDrag,
                                 reflow: false)
                    .id(attempt)
            } else if let desktop {
                ObservedTerminal(feed: feed, fontSize: Float(fontSize), desktopGrid: desktop,
                                 grid: $grid, selection: $selection, onScrollBack: showHistoryAfterDrag)
                    .id(attempt)
            }
            switch observer.phase {
            case .connecting where desktop == nil && takeover == nil:
                ProgressView("正在连接…")
            case .failed(let reason) where desktop == nil && takeover == nil:
                ContentUnavailableView {
                    Label("无法查看终端", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("重试") { start() }
                        .buttonStyle(.borderedProminent)
                }
            case .closed(let reason) where desktop == nil && takeover == nil:
                ContentUnavailableView("会话已结束", systemImage: "stop.circle", description: Text(reason))
            default:
                EmptyView()
            }
        }
        .safeAreaInset(edge: .bottom) { banner }
        .sheet(item: $selection) { selection in
            TerminalTextSheet(selection: selection, onCopied: showCopied)
        }
        .sheet(isPresented: $showingHistory, onDismiss: { historyClosedAt = .now }) {
            TerminalHistorySheet(session: session, client: client)
        }
        .overlay(alignment: .top) {
            if copiedNotice {
                Label("已复制", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier("terminalCopied")
            }
        }
        .animation(.easeOut(duration: 0.2), value: copiedNotice)
        .confirmationDialog("适配手机宽度？", isPresented: $confirmingTakeover, titleVisibility: .visible) {
            Button("开始适配") {
                if let grid { start(takeover: grid) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这个终端会被重排成手机宽度。Mac 上打开它的窗口在你查看期间会跟着变窄，离开这一页后恢复；不会向终端输入。")
        }
        .onChange(of: observer.phase) { _, phase in
            guard case .observing(let cols, let rows) = phase else { return }
            let size = TerminalGrid(cols: cols, rows: rows)
            if let takeover {
                // Someone on the desktop resized the terminal after the takeover:
                // the stream no longer matches the phone's grid.
                sizeDrift = size != takeover
                return
            }
            if desktop == nil {
                desktop = size
            } else if desktop != size {
                // The program now draws for a new desktop width; take a fresh
                // paint rather than mix grids.
                restartAfterResize()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .failed = observer.phase { start() }
        }
        // The surface's font is fixed when it is built, and bytes already
        // drawn would reflow; attach again for core's exact screen.
        .onChange(of: fontSize) { _, _ in start() }
        .task { start() }
        .onDisappear {
            resizeRestart?.cancel()
            observer.stop()
        }
    }

    /// When a terminal is already on screen, problems show below it instead of replacing it.
    @ViewBuilder
    private var banner: some View {
        if let takeover {
            Group {
                switch observer.phase {
                case .failed(let reason):
                    HStack(spacing: 10) {
                        BannerLabel(text: "连接中断：\(reason)", systemImage: "wifi.exclamationmark")
                        Button("重试") { start(takeover: takeover) }.buttonStyle(.bordered)
                    }
                case .closed(let reason):
                    BannerLabel(text: reason, systemImage: "stop.circle")
                default:
                    HStack(spacing: 10) {
                        BannerLabel(
                            text: sizeDrift
                                ? "桌面已改变终端尺寸，画面可能错位"
                                : "已适配手机宽度 · 桌面终端变窄",
                            systemImage: "arrow.up.left.and.arrow.down.right")
                        if sizeDrift {
                            Button("重新适配") { start(takeover: takeover) }.buttonStyle(.bordered)
                        }
                        Button("恢复桌面") { start() }.buttonStyle(.bordered)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else if desktop != nil {
            Group {
                switch observer.phase {
                case .closed(let reason):
                    BannerLabel(text: reason, systemImage: "stop.circle")
                case .failed(let reason):
                    HStack {
                        BannerLabel(text: "连接中断：\(reason)", systemImage: "wifi.exclamationmark")
                        Button("重试") { start() }.buttonStyle(.bordered)
                    }
                default:
                    // A full-screen program draws with absolute positions, so
                    // reflowing it to the phone's width scrambles the screen.
                    if fullScreen {
                        HStack(spacing: 10) {
                            BannerLabel(text: "全屏界面 · 按手机宽度显示会错位",
                                        systemImage: "exclamationmark.triangle")
                            historyButton
                            Button("适配手机") { confirmingTakeover = true }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("takeoverButton")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// A full-screen program's history never reaches this terminal; dragging
    /// toward it, or this button, reads it from core instead.
    private var historyButton: some View {
        Button("历史") { showingHistory = true }
            .buttonStyle(.bordered)
            .accessibilityLabel("查看历史")
            .accessibilityIdentifier("terminalHistoryButton")
    }

    private func showHistoryAfterDrag() {
        guard !showingHistory, selection == nil,
              Date().timeIntervalSince(historyClosedAt) > 1 else { return }
        showingHistory = true
    }

    /// The sheet closed after copying: confirm it somewhere the user is
    /// looking, since the sheet slides away immediately.
    private func showCopied() {
        AccessibilityNotification.Announcement("已复制").post()
        copiedNotice = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copiedNotice = false
        }
    }

    private func start(takeover grid: TerminalGrid? = nil) {
        let feed = TerminalFeed()
        feed.onFullScreenChange = { fullScreen = $0 }
        self.feed = feed
        takeover = grid
        fullScreen = false
        sizeDrift = false
        desktop = nil
        self.grid = nil
        selection = nil
        attempt += 1
        observer.onBytes = { feed.receive($0) }
        observer.start(config, session: session, takeover: grid)
    }

    /// Core now draws for another desktop width; the screen held here was laid
    /// out for the old one. A fresh attach starts from core's exact screen and
    /// reflows it to the phone again.
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
