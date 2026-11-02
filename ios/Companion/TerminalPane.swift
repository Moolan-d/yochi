import SwiftUI

/// The session's terminal, read-only (`/v0/observe`): never the active
/// viewer, so the desktop's grid is untouched.
struct TerminalPane: View {
    let session: String
    let config: GatewayConfig
    /// The phone-sized grid on screen, for the title; nil until reflowed.
    @Binding var grid: TerminalGrid?

    @State private var observer = TerminalObserver()
    @State private var feed = TerminalFeed()
    /// Core's desktop grid, which the first paint is taken at.
    @State private var desktop: TerminalGrid?
    @State private var attempt = 0
    @State private var resizeRestart: Task<Void, Never>?
    @State private var selection: TerminalTextSelection?
    @State private var copiedNotice = false
    @AppStorage(TerminalTextSize.key) private var fontSize = TerminalTextSize.standard
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let desktop {
                ObservedTerminal(feed: feed, fontSize: Float(fontSize), desktopGrid: desktop,
                                 grid: $grid, selection: $selection)
                    .id(attempt)
            }
            switch observer.phase {
            case .connecting where desktop == nil:
                ProgressView("正在连接…")
            case .failed(let reason) where desktop == nil:
                ContentUnavailableView {
                    Label("无法查看终端", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("重试", action: start)
                        .buttonStyle(.borderedProminent)
                }
            case .closed(let reason) where desktop == nil:
                ContentUnavailableView("会话已结束", systemImage: "stop.circle", description: Text(reason))
            default:
                EmptyView()
            }
        }
        .safeAreaInset(edge: .bottom) { banner }
        .sheet(item: $selection) { selection in
            TerminalTextSheet(selection: selection, onCopied: showCopied)
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
        .onChange(of: observer.phase) { _, phase in
            guard case .observing(let cols, let rows) = phase else { return }
            let size = TerminalGrid(cols: cols, rows: rows)
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
        if desktop != nil {
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

    private func start() {
        let feed = TerminalFeed()
        self.feed = feed
        desktop = nil
        grid = nil
        selection = nil
        attempt += 1
        observer.onBytes = { feed.receive($0) }
        observer.start(config, session: session)
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
