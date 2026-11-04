import SwiftUI

/// The session's terminal (`/v0/observe`). Watching never attaches as an
/// active viewer, so the desktop's grid is untouched; commands and keys go
/// in beside it, through the page's composer and key bar. Line output is
/// reflowed to the phone's width; a full-screen program is shown as the
/// desktop drew it.
struct TerminalPane: View {
    let session: String
    let config: GatewayConfig
    /// Kept by the session cache, so the page shows its last screen again
    /// when it comes back soon after leaving.
    let model: TerminalModel
    /// The grid on screen, for the title; nil until the first paint is shown.
    @Binding var grid: TerminalGrid?

    @State private var selection: TerminalTextSelection?
    @State private var copiedNotice = false
    @State private var awayFromBottom = false
    @AppStorage(TerminalTextSize.key) private var fontSize = TerminalTextSize.standard
    @Environment(\.scenePhase) private var scenePhase

    private var observer: TerminalObserver { model.observer }

    var body: some View {
        let _ = Perf.count("TerminalPane")
        ZStack {
            if let desktop = model.desktop, let feed = model.feed {
                // A program entering or leaving full screen is shown the other
                // way; a fresh attach takes core's exact screen for it.
                ObservedTerminal(model: model, feed: feed, attempt: model.attempt, fontSize: Float(fontSize),
                                 desktopGrid: desktop, grid: $grid, selection: $selection,
                                 awayFromBottom: $awayFromBottom,
                                 onScreenModeChange: model.restartAfterResize)
                    .id(model.attempt)
            }
            switch observer.phase {
            case .connecting where model.desktop == nil:
                ProgressView("正在连接…")
            case .failed(let reason) where model.desktop == nil:
                ContentUnavailableView {
                    Label("无法查看终端", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("重试", action: start)
                        .buttonStyle(.borderedProminent)
                }
            case .closed(let reason) where model.desktop == nil:
                ContentUnavailableView("会话已结束", systemImage: "stop.circle", description: Text(reason))
            default:
                EmptyView()
            }
        }
        // Above the banner, which takes the bottom when the stream fails.
        .overlay(alignment: .bottomTrailing) {
            if awayFromBottom {
                latestButton
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: awayFromBottom)
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
        .onChange(of: observer.phase) { _, _ in model.phaseChanged() }
        // A fresh attach starts at the newest output.
        .onChange(of: model.attempt) { _, _ in awayFromBottom = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .failed = observer.phase { start() }
        }
        // The surface's font is fixed when it is built, and bytes already
        // drawn would reflow; attach again for core's exact screen.
        .onChange(of: fontSize) { _, _ in start() }
        .onAppear { model.resume(config, session: session, fontSize: fontSize) }
        // The stream stays open while the cache keeps the model.
        .onDisappear { model.pause() }
    }

    /// When a terminal is already on screen, problems show below it instead of replacing it.
    @ViewBuilder
    private var banner: some View {
        if model.desktop != nil {
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

    /// Back to the newest output, as on the conversation page.
    private var latestButton: some View {
        Button {
            model.surface?.view.scrollToBottom()
        } label: {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: .circle)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到最新")
        .accessibilityIdentifier("terminalScrollToLatest")
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
        selection = nil
        grid = nil
        awayFromBottom = false
        model.start(config, session: session, fontSize: fontSize)
    }
}

/// One session's terminal stream and the surface drawing it. The session
/// cache keeps it after the page leaves: the stream stays open and its bytes
/// wait, and the surface shows its screen again at once when the page
/// returns, then catches up.
@MainActor @Observable
final class TerminalModel {
    let observer = TerminalObserver()
    /// The current attach's bytes; nil before the first.
    private(set) var feed: TerminalFeed?
    /// Core's desktop grid, which the first paint is taken at.
    private(set) var desktop: TerminalGrid?
    /// Counts attaches; each draws on a surface of its own.
    private(set) var attempt = 0

    /// The surface for `attempt`, kept so a page coming back can show it.
    @ObservationIgnored var surface: (attempt: Int, view: ObservedTerminalView)?
    @ObservationIgnored private var target: (config: GatewayConfig, session: String, fontSize: Double)?
    @ObservationIgnored private var resizeRestart: Task<Void, Never>?

    /// A page opened: carry on from what is kept, or attach afresh when
    /// nothing is, the stream failed, the font changed, the desktop grid
    /// changed, or too much output piled up while away.
    func resume(_ config: GatewayConfig, session: String, fontSize: Double) {
        let failed = if case .failed = observer.phase { true } else { false }
        let resized = if case .observing(let cols, let rows) = observer.phase, let desktop {
            desktop != TerminalGrid(cols: cols, rows: rows)
        } else { false }
        guard let target, let feed, target.session == session, target.config == config,
              target.fontSize == fontSize, !failed, !resized, !feed.overflowed else {
            start(config, session: session, fontSize: fontSize)
            return
        }
        feed.resume()
    }

    /// The page left; output waits in the feed until one comes back.
    func pause() {
        resizeRestart?.cancel()
        guard surface?.view.hasShown == true else {
            // Left during the first paint, which needs its page: attach
            // afresh next time.
            observer.stop()
            feed = nil
            desktop = nil
            surface = nil
            return
        }
        feed?.pause()
    }

    func start(_ config: GatewayConfig, session: String, fontSize: Double) {
        resizeRestart?.cancel()
        target = (config, session, fontSize)
        let feed = TerminalFeed()
        self.feed = feed
        desktop = nil
        surface = nil
        attempt += 1
        observer.onBytes = { feed.receive($0) }
        observer.start(config, session: session)
    }

    func stop() {
        resizeRestart?.cancel()
        observer.stop()
        surface = nil
    }

    func phaseChanged() {
        guard case .observing(let cols, let rows) = observer.phase else { return }
        let size = TerminalGrid(cols: cols, rows: rows)
        if desktop == nil {
            desktop = size
        } else if desktop != size {
            // The program now draws for a new desktop width; take a fresh
            // paint rather than mix grids.
            restartAfterResize()
        }
    }

    /// Core now draws for another desktop width, or the program entered or
    /// left full screen; the screen held here was laid out for the old one. A
    /// fresh attach starts from core's exact screen and shows it the right way.
    func restartAfterResize() {
        resizeRestart?.cancel()
        resizeRestart = Task { [weak self] in
            // Dragging a desktop split resizes many times; attach once it settles.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let target else { return }
            start(target.config, session: target.session, fontSize: target.fontSize)
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
