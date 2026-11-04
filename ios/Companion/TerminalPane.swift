import SwiftUI

/// The session's terminal (`/v0/observe`). Opening it takes the terminal
/// over at the phone's grid, as Rex does: the program draws for the phone
/// and the desktop's terminal shrinks while the page is shown; leaving the
/// page or the app lets go, and core gives the desktop its size back. When
/// the desktop takes the size back meanwhile, the page only watches again,
/// reflowing line output and showing a full-screen program as the desktop
/// drew it, until the user takes it over again. Commands and keys go in
/// beside it, through the page's composer and key bar.
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
    /// Between onAppear and onDisappear: the app coming back to the
    /// foreground takes the terminal over again only for a page on screen.
    @State private var visible = false
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
                                 desktopGrid: desktop, takeover: model.takeover != nil,
                                 grid: $grid, selection: $selection,
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
        // The grid to ask core for: the space the surface gets. The stack
        // takes the whole page even while it holds only the spinner.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.pageSize($0) }
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
        // The surface's grid follows the page (keyboard, rotation); core follows it.
        .onChange(of: grid) { _, grid in
            if let grid { model.surfaceGrid(grid) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard visible else { return }
            switch phase {
            // Let go, so the desktop has its size back while the phone is away.
            case .background: model.pause()
            case .active: model.resume(config, session: session, fontSize: fontSize)
            default: break
            }
        }
        // The surface's font is fixed when it is built, and bytes already
        // drawn would reflow; attach again for core's exact screen.
        .onChange(of: fontSize) { _, _ in start() }
        .onAppear {
            visible = true
            model.resume(config, session: session, fontSize: fontSize)
        }
        // A watching stream stays open while the cache keeps the model; a
        // takeover lets go.
        .onDisappear {
            visible = false
            model.pause()
        }
    }

    /// When a terminal is already on screen, problems show below it instead of replacing it.
    @ViewBuilder
    private var banner: some View {
        if model.desktop != nil {
            Group {
                switch observer.phase {
                case .observing where model.yielded:
                    HStack {
                        BannerLabel(text: "桌面正在使用这个终端，按桌面尺寸显示", systemImage: "desktopcomputer")
                        Button("按手机尺寸") { model.takeOverAgain() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("terminalTakeOver")
                    }
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

/// One session's terminal stream and the surface drawing it. A takeover
/// stream asks core for the phone's grid, follows the surface as it
/// changes, and closes when the page leaves. A watching stream (the desktop
/// took the size back, or no cell is measured yet for this font) is kept by
/// the session cache after the page leaves: its bytes wait, and the surface
/// shows its screen again at once when the page returns, then catches up.
@MainActor @Observable
final class TerminalModel {
    let observer = TerminalObserver()
    /// The current attach's bytes; nil before the first.
    private(set) var feed: TerminalFeed?
    /// Core's grid at attaching, which the first paint is taken at.
    private(set) var desktop: TerminalGrid?
    /// Counts attaches; each draws on a surface of its own.
    private(set) var attempt = 0
    /// The grid this stream holds the terminal at; nil while only watching.
    private(set) var takeover: TerminalGrid?
    /// The desktop took the size back; the page watches until the user
    /// takes it over again, or opens the page afresh.
    private(set) var yielded = false

    /// The surface for `attempt`, kept so a page coming back can show it.
    @ObservationIgnored var surface: (attempt: Int, view: ObservedTerminalView)?
    @ObservationIgnored private var target: (config: GatewayConfig, session: String, fontSize: Double)?
    @ObservationIgnored private var page = CGSize.zero
    /// The grid the current surface shows, which can arrive before core
    /// answers the attach (a page coming back measures at once).
    @ObservationIgnored private var shown: TerminalGrid?
    /// A page asked to start before it had a size to take over at.
    @ObservationIgnored private var waitingForSize = false
    /// The page left while taking over; coming back takes over afresh.
    @ObservationIgnored private var released = false
    @ObservationIgnored private var resizeRestart: Task<Void, Never>?
    @ObservationIgnored private var resizeSend: Task<Void, Never>?
    @ObservationIgnored private var takebackCheck: Task<Void, Never>?

    /// The phone's grid for the page at `fontSize`, once a cell is measured.
    private func phoneGrid(fontSize: Double) -> TerminalGrid? {
        TerminalCell.grid(fitting: page, fontSize: fontSize)
    }

    /// A page opened (or the app came back): take the terminal over afresh,
    /// or carry on watching from what is kept unless the stream failed, the
    /// font or desktop grid changed, or too much output piled up meanwhile.
    func resume(_ config: GatewayConfig, session: String, fontSize: Double) {
        let failed = if case .failed = observer.phase { true } else { false }
        let resized = if case .observing(let cols, let rows) = observer.phase, let desktop {
            desktop != TerminalGrid(cols: cols, rows: rows)
        } else { false }
        let same = target.map { $0.session == session && $0.config == config && $0.fontSize == fontSize } ?? false
        // Still holding it, e.g. the app only went inactive.
        if takeover != nil, !released, !failed, same, !waitingForSize { return }
        let canTakeOver = phoneGrid(fontSize: fontSize) != nil
        guard let target, let feed, target.session == session, target.config == config,
              target.fontSize == fontSize, !failed, !resized, !feed.overflowed,
              !released, !yielded, !canTakeOver else {
            yielded = false
            start(config, session: session, fontSize: fontSize)
            return
        }
        feed.resume()
    }

    /// The page left; a takeover lets go, watching output waits in the feed
    /// until the page comes back.
    func pause() {
        resizeRestart?.cancel()
        resizeSend?.cancel()
        takebackCheck?.cancel()
        waitingForSize = false
        if takeover != nil {
            observer.stop()
            released = true
            return
        }
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
        resizeSend?.cancel()
        takebackCheck?.cancel()
        target = (config, session, fontSize)
        released = false
        // The first layout hasn't sized the page yet; it starts once it has.
        guard page != .zero else {
            waitingForSize = true
            return
        }
        waitingForSize = false
        let feed = TerminalFeed()
        self.feed = feed
        desktop = nil
        surface = nil
        shown = nil
        takeover = yielded ? nil : phoneGrid(fontSize: fontSize)
        attempt += 1
        observer.onBytes = { feed.receive($0) }
        observer.start(config, session: session, takeover: takeover)
    }

    func stop() {
        resizeRestart?.cancel()
        resizeSend?.cancel()
        takebackCheck?.cancel()
        observer.stop()
        surface = nil
    }

    /// The space the surface gets on the page.
    func pageSize(_ size: CGSize) {
        page = size
        if waitingForSize, let target {
            start(target.config, session: target.session, fontSize: target.fontSize)
        }
    }

    /// The surface shows this grid now. Taken over, core follows it once it
    /// settles (the keyboard animates); watching only because no cell was
    /// measured yet, the surface has just measured one, so take over.
    func surfaceGrid(_ grid: TerminalGrid) {
        shown = grid
        guard let target, case .observing = observer.phase else { return }
        if let takeover {
            resizeSend?.cancel()
            guard grid != takeover else { return }
            resizeSend = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.takeover != nil else { return }
                self.takeover = grid
                observer.resize(grid)
            }
        } else if !yielded, phoneGrid(fontSize: target.fontSize) != nil {
            start(target.config, session: target.session, fontSize: target.fontSize)
        }
    }

    /// The user wants the phone's grid again after the desktop took it.
    func takeOverAgain() {
        guard let target else { return }
        yielded = false
        start(target.config, session: target.session, fontSize: target.fontSize)
    }

    func phaseChanged() {
        guard case .observing(let cols, let rows) = observer.phase else { return }
        let size = TerminalGrid(cols: cols, rows: rows)
        if desktop == nil {
            desktop = size
            // Core's word on the grid it took; a surface that already shows
            // another (it measured before core answered) asks for its own, and
            // one watching only because no cell was measured may take over now.
            if takeover != nil { takeover = size }
            if let shown, shown != size { surfaceGrid(shown) }
        } else if takeover != nil {
            takebackCheck?.cancel()
            guard size != takeover else { return }
            // A size from before the phone's latest resize can still be on its
            // way; one that stays different is the desktop's.
            takebackCheck = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, let takeover = self.takeover,
                      case .observing(let cols, let rows) = observer.phase,
                      TerminalGrid(cols: cols, rows: rows) != takeover, let target else { return }
                yielded = true
                start(target.config, session: target.session, fontSize: target.fontSize)
            }
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
