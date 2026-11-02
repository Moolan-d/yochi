import GhosttyTerminal
import SwiftUI
import UIKit

/// The grid a terminal is drawn on.
struct TerminalGrid: Equatable {
    var cols: Int
    var rows: Int
}

/// The font size the phone draws a terminal at, remembered between visits.
/// Changing it rebuilds the surface, so the page re-attaches for core's exact
/// screen rather than reflowing bytes the old surface already drew.
enum TerminalTextSize {
    static let key = "terminalFontSize"
    static let standard: Double = 9
    static let range: ClosedRange<Double> = 7...16

    static func clamped(_ size: Double) -> Double {
        min(max(size, range.lowerBound), range.upperBound)
    }
}

/// The terminal text a long press handed to the sheet, with the word under
/// the finger pre-selected; nil anchor means select the whole viewport.
struct TerminalTextSelection: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let anchor: NSRange?

    /// What the sheet starts with selected, so Copy is one tap away.
    static func initialText(_ text: String, anchor: NSRange?) -> String {
        let text = text as NSString
        guard let anchor, anchor.length > 0,
              anchor.location >= 0, NSMaxRange(anchor) <= text.length else { return text as String }
        return text.substring(with: anchor)
    }
}

/// An in-memory Ghostty session that holds the terminal's bytes until the
/// surface's grid matches the size they were drawn for.
@MainActor
final class TerminalFeed {
    // Observing never types or resizes, so nothing flows back to the Gateway.
    let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    private var held: [Data] = []
    private(set) var isOpen = false
    /// Whether any remote output has arrived; until then the caret means nothing.
    private(set) var hasOutput = false
    /// When the last bytes arrived, so the first paint's chunks can be told
    /// apart from the live output that follows.
    private(set) var lastReceiveAt: Date?

    /// Whether the program is on the alternate screen, which is what a full
    /// screen TUI uses; such a screen cannot be reflowed without misplacing it.
    private(set) var isFullScreen = false
    var onFullScreenChange: ((Bool) -> Void)?
    /// The tail of the last bytes, so a mode switch split between chunks is
    /// still read whole.
    private var modeTail = Data()

    func receive(_ data: Data) {
        hasOutput = true
        lastReceiveAt = Date()
        noteScreenMode(data)
        if isOpen { session.receive(data) } else { held.append(data) }
    }

    /// Follows the alternate-screen switches programs emit. The core's first
    /// paint turns them all off, then on again when the screen it holds is
    /// the alternate one.
    private func noteScreenMode(_ data: Data) {
        var bytes = modeTail
        bytes.append(data)
        var mode: Bool?
        var index = bytes.startIndex
        while let escape = bytes[index...].firstIndex(of: 0x1b) {
            let rest = bytes[escape...]
            var matched = false
            for (sequence, fullScreen) in Self.screenModes where rest.starts(with: sequence) {
                mode = fullScreen
                index = rest.index(rest.startIndex, offsetBy: sequence.count)
                matched = true
                break
            }
            if !matched { index = rest.index(after: rest.startIndex) }
        }
        modeTail = bytes.suffix(8)
        guard let mode, mode != isFullScreen else { return }
        isFullScreen = mode
        let change = onFullScreenChange
        DispatchQueue.main.async { change?(mode) }
    }

    private static let screenModes: [([UInt8], Bool)] = [
        (Array("\u{1b}[?1049h".utf8), true),
        (Array("\u{1b}[?1047h".utf8), true),
        (Array("\u{1b}[?47h".utf8), true),
        (Array("\u{1b}[?1049l".utf8), false),
        (Array("\u{1b}[?1047l".utf8), false),
        (Array("\u{1b}[?47l".utf8), false),
    ]

    func open() {
        guard !isOpen else { return }
        isOpen = true
        held.forEach(session.receive)
        held = []
    }
}

struct ObservedTerminal: UIViewRepresentable {
    let feed: TerminalFeed
    let fontSize: Float
    /// Core paints at the desktop grid; the surface starts there so the first
    /// paint lands on the rows and columns it was drawn for.
    let desktopGrid: TerminalGrid
    /// The phone-sized grid on screen, for the title.
    @Binding var grid: TerminalGrid?
    /// Set by a long press; the page presents the selection sheet.
    @Binding var selection: TerminalTextSelection?
    /// False while the terminal itself is sized to the phone (a takeover
    /// viewer): core already draws for the phone grid, so nothing is reflowed.
    var reflow = true

    func makeUIView(context: Context) -> ObservedTerminalView {
        let view = ObservedTerminalView(feed: feed, fontSize: fontSize, desktopGrid: desktopGrid,
                                        reflow: reflow)
        view.onGridChange = { grid = $0 }
        view.onTextSelection = { selection = $0 }
        return view
    }

    func updateUIView(_ view: ObservedTerminalView, context: Context) {
        view.onGridChange = { grid = $0 }
        view.onTextSelection = { selection = $0 }
    }
}

/// The terminal at the phone's own size. Core's paint arrives at the desktop
/// grid; Ghostty takes it there, then reflows the screen into however many
/// columns the phone fits, so nothing is scaled or panned. Live output is
/// then read at the local grid: exact for line-oriented programs, while a
/// full-screen TUI drawn for the desktop may land on the wrong columns. In a
/// takeover the terminal itself is phone-sized and the bytes are used as-is.
final class ObservedTerminalView: UIView, TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceTextSelectionRequestDelegate {
    var onGridChange: ((TerminalGrid) -> Void)?
    var onTextSelection: ((TerminalTextSelection) -> Void)?

    private let feed: TerminalFeed
    private let desktop: TerminalGrid
    /// False when core already draws for the phone: no desktop-sized bootstrap.
    private let reflowing: Bool
    private let terminal = SelectionOnlyTerminalView(frame: .zero)
    private let controller: TerminalController
    /// One cell in points, once Ghostty has measured it.
    private var cell: CGSize?
    private var lastGrid: TerminalGrid?

    /// True until the first paint is taken and reflowed to the phone's grid.
    private var preparing = true
    private var paintStarted = false
    private var openScheduled = false
    private var pendingMetrics: TerminalGridMetrics?
    private var framesLeft = 0
    private var frameBody: (() -> Void)?
    private var displayLink: CADisplayLink?

    init(feed: TerminalFeed, fontSize: Float, desktopGrid: TerminalGrid, reflow: Bool = true) {
        self.feed = feed
        self.desktop = desktopGrid
        self.reflowing = reflow
        self.controller = TerminalController {
            $0.withFontSize(fontSize)
            $0.withWindowPaddingX(6)
            $0.withWindowPaddingY(4)
        }
        super.init(frame: .zero)
        backgroundColor = Self.terminalBackground
        clipsToBounds = true

        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(feed.session))
        terminal.controller = controller
        terminal.delegate = self
        // Pinch would change the font under the page's size menu; dragging
        // scrolls the terminal's own history, which this page keeps.
        for gesture in terminal.gestureRecognizers ?? [] where gesture is UIPinchGestureRecognizer {
            gesture.isEnabled = false
        }
        // A takeover surface has nothing to reflow, so it can show at once.
        preparing = reflow
        terminal.alpha = reflow ? 0 : 1
        addSubview(terminal)

        isAccessibilityElement = true
        accessibilityLabel = "终端画面"
        accessibilityIdentifier = "terminalGrid"
        accessibilityHint = "终端画面只读，按手机宽度排版；长按可选取文字复制，拖动查看历史，可用下方按键栏按键，或发送 Agent 消息。"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Ghostty's default theme backgrounds (Alabaster, Afterglow), so the area
    /// around the text reads as part of the terminal.
    private static let terminalBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x21 / 255, green: 0x21 / 255, blue: 0x21 / 255, alpha: 1)
            : UIColor(red: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF7 / 255, alpha: 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !reflowing {
            terminal.frame = bounds
            // Ghostty applies a size on its next draws; bytes fed before that
            // would be laid out at the old one.
            if !feed.isOpen && !openScheduled {
                openScheduled = true
                afterFrames(2) { [weak self] in self?.feed.open() }
            }
            return
        }
        if preparing {
            if !paintStarted {
                // A first size lets Ghostty measure a cell.
                terminal.frame = bounds
                if cell != nil { paintAtDesktopSize() }
            }
            return
        }
        terminal.frame = bounds
    }

    // MARK: Grid

    func terminalDidResize(_ size: TerminalGridMetrics) {
        guard terminal.bounds.width > 0, size.widthPixels > 0,
              size.cellWidthPixels > 0, size.cellHeightPixels > 0 else { return }
        let scale = CGFloat(size.widthPixels) / terminal.bounds.width
        let measured = CGSize(width: CGFloat(size.cellWidthPixels) / scale,
                              height: CGFloat(size.cellHeightPixels) / scale)
        if measured != cell {
            cell = measured
            if preparing, !paintStarted { paintAtDesktopSize() }
        }
        guard !preparing else {
            pendingMetrics = size
            return
        }
        report(size)
    }

    private func report(_ size: TerminalGridMetrics) {
        let grid = TerminalGrid(cols: Int(size.columns), rows: Int(size.rows))
        guard grid != lastGrid else { return }
        lastGrid = grid
        let report = onGridChange
        // A resize can run inside a SwiftUI update; the title reads it next turn.
        DispatchQueue.main.async { report?(grid) }
    }

    /// The first paint is a desktop-sized screen: take it at that grid, where
    /// every row and column means what core meant, before reflowing.
    private func paintAtDesktopSize() {
        guard !paintStarted, let cell, bounds.width > 0 else { return }
        paintStarted = true
        terminal.frame = CGRect(origin: .zero, size: CGSize(
            width: ceil(CGFloat(desktop.cols) * cell.width) + 1,
            height: ceil(CGFloat(desktop.rows) * cell.height) + 1
        ))
        // Ghostty applies a surface resize on its next draws; bytes fed before
        // that are laid out in the old grid.
        afterFrames(2) { [weak self] in
            guard let self else { return }
            feed.open()
            reflowWhenPainted(0)
        }
    }

    /// Waits for the first bytes (up to two seconds), parses them, then lets
    /// the surface take the phone's size so Ghostty reflows the screen.
    private func reflowWhenPainted(_ attempt: Int) {
        guard preparing else { return }
        // The first paint can arrive in several chunks; wait for a short quiet
        // after the first bytes, or reflow anyway when none come.
        let quiet = feed.lastReceiveAt.map { Date().timeIntervalSince($0) >= 0.12 } ?? false
        guard (feed.hasOutput && quiet) || attempt >= 40 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.reflowWhenPainted(attempt + 1)
            }
            return
        }
        // Safe on the main thread: it parses the queued first paint first.
        feed.session.waitForPendingOutput()
        reflowToPhone()
    }

    private func reflowToPhone() {
        guard preparing else { return }
        // Only the metrics the phone's size produces should reach the title.
        pendingMetrics = nil
        terminal.frame = bounds
        afterFrames(2) { [weak self] in
            guard let self else { return }
            preparing = false
            UIView.animate(withDuration: 0.15) { self.terminal.alpha = 1 }
            if let pendingMetrics { report(pendingMetrics) }
        }
    }

    // MARK: Frames

    /// Runs `body` once the surface has drawn `n` more frames.
    private func afterFrames(_ n: Int, _ body: @escaping () -> Void) {
        frameBody = body
        framesLeft = n
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func frameTick() {
        framesLeft -= 1
        guard framesLeft <= 0 else { return }
        displayLink?.invalidate()
        displayLink = nil
        let body = frameBody
        frameBody = nil
        body?()
    }

    // MARK: Text selection

    /// Ghostty snapshots the visible rows and the word under the finger; the
    /// page turns that into a selectable sheet. Nothing is typed or resized.
    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        onTextSelection?(TerminalTextSelection(text: request.text, anchor: request.anchorRange))
    }
}

/// Lets a long press select text without making the terminal a text input:
/// a tap never becomes first responder, so no keyboard appears.
private final class SelectionOnlyTerminalView: UITerminalView {
    override var canBecomeFirstResponder: Bool { false }

    override func toggleSoftwareKeyboard() {}
}
