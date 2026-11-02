import GhosttyTerminal
import SwiftUI
import UIKit

/// The terminal's grid as the core sees it, which an observer must render to.
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

    func receive(_ data: Data) {
        hasOutput = true
        if isOpen { session.receive(data) } else { held.append(data) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        held.forEach(session.receive)
        held = []
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

struct ObservedTerminal: UIViewRepresentable {
    let feed: TerminalFeed
    let grid: TerminalGrid
    let fontSize: Float
    /// The page's title says which zoom the terminal is at; a double tap or a
    /// pinch is otherwise invisible.
    @Binding var zoomNote: String
    /// Set by a long press; the page presents the selection sheet.
    @Binding var selection: TerminalTextSelection?

    func makeUIView(context: Context) -> ObservedTerminalScrollView {
        let view = ObservedTerminalScrollView(feed: feed, grid: grid, fontSize: fontSize)
        view.onZoomChange = { zoomNote = $0 }
        view.onTextSelection = { selection = $0 }
        return view
    }

    func updateUIView(_ view: ObservedTerminalScrollView, context: Context) {
        view.grid = grid
        view.onZoomChange = { zoomNote = $0 }
        view.onTextSelection = { selection = $0 }
    }
}

/// A Ghostty surface sized to the remote grid inside a scroll view. It opens
/// at a readable font size; a double tap alternates that with the whole grid.
final class ObservedTerminalScrollView: UIScrollView, UIScrollViewDelegate, TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceTextSelectionRequestDelegate {
    /// Readability is judged by a cell's width on screen, in points: Ghostty's
    /// cell at font size 9 is about 7.3 pt wide, not what 9 pt suggests.
    /// A grid whose cells are at least this wide when it fits the screen opens
    /// fitted, with no sideways panning (about 72 columns on an iPhone Pro).
    static let fittedCellWidth: CGFloat = 5.5
    /// Otherwise it opens zoomed to this cell width, about 60 columns across.
    static let readableCellWidth: CGFloat = 6.6
    /// Ghostty's default theme backgrounds (Alabaster, Afterglow), so the area
    /// around a grid shorter than the screen reads as part of the terminal.
    private static let terminalBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x21 / 255, green: 0x21 / 255, blue: 0x21 / 255, alpha: 1)
            : UIColor(red: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF7 / 255, alpha: 1)
    }

    var grid: TerminalGrid {
        didSet { if grid != oldValue { sizeTerminal() } }
    }

    /// Reports the zoom as the page's title should read it; only changes are sent.
    var onZoomChange: ((String) -> Void)?
    /// A long press selected text; the page presents it for copying.
    var onTextSelection: ((TerminalTextSelection) -> Void)?

    private let feed: TerminalFeed
    private let terminal = SelectionOnlyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
    private let controller: TerminalController
    private var lastZoomNote: String?
    /// One cell in points, once Ghostty has measured it.
    private var cell: CGSize?
    private enum ZoomMode {
        case `default`
        case overview
        case custom
    }

    /// Only `.default` may be overridden by layout or a new remote grid.
    private var zoomMode: ZoomMode = .default
    private var initialViewportPending = true
    private var initialViewportScheduled = false
    private var initialPaintReady = false
    private var initialViewportAttempts = 0

    init(feed: TerminalFeed, grid: TerminalGrid, fontSize: Float) {
        self.feed = feed
        self.grid = grid
        self.controller = TerminalController {
            $0.withFontSize(fontSize)
            $0.withWindowPaddingX(0)
            $0.withWindowPaddingY(0)
        }
        super.init(frame: .zero)
        delegate = self
        backgroundColor = Self.terminalBackground
        maximumZoomScale = 3
        showsHorizontalScrollIndicator = true
        // Dragging the terminal puts the keyboard away, as on the conversation page.
        keyboardDismissMode = .interactive

        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(feed.session))
        terminal.controller = controller
        terminal.delegate = self
        // The library pans its scrollback and pinches its font; this page's
        // scroll view owns both. Its long press still reports selections.
        for gesture in terminal.gestureRecognizers ?? []
        where gesture is UIPanGestureRecognizer || gesture is UIPinchGestureRecognizer {
            gesture.isEnabled = false
        }
        terminal.alpha = 0
        addSubview(terminal)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        isAccessibilityElement = true
        accessibilityLabel = "终端画面"
        accessibilityIdentifier = "terminalGrid"
        accessibilityHint = "终端画面只读；长按可选取文字复制，可用下方按键栏按键，或发送 Agent 消息。双击在全貌与可读字号之间切换，双指缩放，拖动平移。"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    // MARK: Grid

    func terminalDidResize(_ size: TerminalGridMetrics) {
        guard terminal.bounds.width > 0, size.widthPixels > 0, size.cellWidthPixels > 0 else { return }
        let scale = CGFloat(size.widthPixels) / terminal.bounds.width
        let measured = CGSize(width: CGFloat(size.cellWidthPixels) / scale,
                              height: CGFloat(size.cellHeightPixels) / scale)
        if measured != cell {
            cell = measured
            sizeTerminal()
            return
        }
        let missingCols = grid.cols - Int(size.columns)
        let missingRows = grid.rows - Int(size.rows)
        if missingCols > 0 || missingRows > 0 {
            // Rounding left the surface a cell short; grow it rather than wrap lines.
            resizeTerminal(to: CGSize(width: terminal.bounds.width + CGFloat(max(missingCols, 0)) * measured.width,
                                      height: terminal.bounds.height + CGFloat(max(missingRows, 0)) * measured.height))
            return
        }
        if !feed.isOpen {
            afterFrames(2) { [weak self] in self?.openOnce() }
        }
    }

    private var framesLeft = 0
    private var afterFramesBody: (() -> Void)?
    private var displayLink: CADisplayLink?

    /// Runs `body` once the surface has drawn `n` more frames. Ghostty applies
    /// a surface resize on its next draws, and bytes fed before that are laid
    /// out in the old grid: the snapshot's cursor lands mid-screen and the
    /// rows below it are lost.
    private func afterFrames(_ n: Int, _ body: @escaping () -> Void) {
        afterFramesBody = body
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
        let body = afterFramesBody
        afterFramesBody = nil
        body?()
    }

    private func openOnce() {
        guard !feed.isOpen else { return }
        feed.open()
        UIView.animate(withDuration: 0.2) { self.terminal.alpha = 1 }
        revealInitialViewport()
    }

    private func sizeTerminal() {
        guard let cell else { return }
        // One extra point so the grid's floor division lands on exactly cols × rows.
        resizeTerminal(to: CGSize(width: ceil(CGFloat(grid.cols) * cell.width) + 1,
                                  height: ceil(CGFloat(grid.rows) * cell.height) + 1))
    }

    private func resizeTerminal(to natural: CGSize) {
        guard natural != terminal.bounds.size else { return }
        let previousZoom = zoomScale
        zoomScale = 1
        terminal.frame = CGRect(origin: .zero, size: natural)
        contentSize = natural
        fitZoom()
        if zoomMode == .custom { zoomScale = max(previousZoom, minimumZoomScale) }
        alignToBottom()
    }

    // MARK: Zoom

    override func layoutSubviews() {
        super.layoutSubviews()
        fitZoom()
        alignToBottom()
    }

    private var defaultZoomScale: CGFloat {
        guard let cell else { return minimumZoomScale }
        return Self.defaultZoom(fit: minimumZoomScale, cellWidth: cell.width)
    }

    private var readableZoomScale: CGFloat {
        guard let cell else { return 1 }
        return Self.readableCellWidth / cell.width
    }

    /// The whole width when that stays readable, else a readable cell width.
    static func defaultZoom(fit: CGFloat, cellWidth: CGFloat) -> CGFloat {
        if fit * cellWidth >= fittedCellWidth { return fit }
        return max(fit, readableCellWidth / cellWidth)
    }

    /// The title's word for the current zoom: the whole grid, the readable
    /// default, or the percentage of the fitted width a pinch reached.
    nonisolated static func zoomLabel(scale: CGFloat, fit: CGFloat, defaultScale: CGFloat) -> String {
        guard fit > 0 else { return "" }
        if scale <= fit * 1.02 { return "全貌" }
        if defaultScale > fit * 1.02, abs(scale - defaultScale) < 0.02 { return "可读" }
        return "\(Int((scale / fit * 100).rounded()))%"
    }

    private func notifyZoom() {
        let note = Self.zoomLabel(scale: zoomScale, fit: minimumZoomScale, defaultScale: defaultZoomScale)
        guard note != lastZoomNote else { return }
        lastZoomNote = note
        // `fitZoom` also runs from `updateUIView`; writing the SwiftUI state
        // there would be a change during a view update.
        let report = onZoomChange
        DispatchQueue.main.async { report?(note) }
    }

    /// The height not covered by the navigation bar or the composer.
    private var visibleHeight: CGFloat {
        bounds.height - (adjustedContentInset.top - contentInset.top) - adjustedContentInset.bottom
    }

    /// A grid shorter than the screen sits at the bottom, next to the composer,
    /// where Agents keep their prompt.
    private func alignToBottom() {
        let top = max(0, visibleHeight - contentSize.height).rounded(.down)
        guard contentInset.top != top else { return }
        contentInset.top = top
        if contentSize.height <= visibleHeight {
            contentOffset.y = -adjustedContentInset.top
        }
    }

    private func fitZoom() {
        guard terminal.bounds.width > 0, bounds.width > 0 else { return }
        let fit = bounds.width / terminal.bounds.width
        if minimumZoomScale != fit { minimumZoomScale = fit }
        maximumZoomScale = max(3, fit)
        switch zoomMode {
        case .default:
            if zoomScale != defaultZoomScale { zoomScale = defaultZoomScale }
        case .overview:
            if zoomScale != fit { zoomScale = fit }
        case .custom:
            if zoomScale < fit { zoomScale = fit }
        }
        notifyZoom()
        revealInitialViewport()
    }

    private func revealInitialViewport() {
        guard initialViewportPending, feed.isOpen, bounds.width > 0, bounds.height > 0 else { return }
        guard initialPaintReady else {
            scheduleInitialViewport()
            return
        }
        // Wait out parser latency: the caret only moves after the first paint.
        let caret = terminal.caretRect(for: terminal.endOfDocument)
        guard caret.origin.x.isFinite, caret.origin.y.isFinite,
              caret.width.isFinite, caret.height.isFinite,
              caret.width > 0, caret.height > 0 else {
            initialViewportAttempts += 1
            if initialViewportAttempts < 10 {
                scheduleInitialViewport()
            } else {
                initialViewportPending = false
                // No caret: use the required bottom, leading-aligned fallback.
                setContentOffset(CGPoint(x: 0, y: max(0, contentSize.height - bounds.height)),
                                 animated: false)
                pinShortGrid()
            }
            return
        }
        initialViewportPending = false
        // caretRect is in the terminal's unscaled points; contentOffset and
        // contentSize are in the scroll view's zoomed coordinates.
        let scaledCaret = caret.applying(CGAffineTransform(scaleX: zoomScale, y: zoomScale))
        let offset = Self.initialOffset(caret: scaledCaret, content: contentSize, visible: bounds.size)
        setContentOffset(offset, animated: false)
        pinShortGrid()
    }

    private func pinShortGrid() {
        if contentSize.height <= visibleHeight {
            contentOffset.y = -adjustedContentInset.top
        }
    }

    private func scheduleInitialViewport() {
        guard !initialViewportScheduled else { return }
        initialViewportScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            initialViewportScheduled = false
            guard initialViewportPending else { return }
            guard feed.hasOutput || initialViewportAttempts >= 10 else {
                initialViewportAttempts += 1
                scheduleInitialViewport()
                return
            }
            // Safe on the main thread: it parses the queued first paint first.
            feed.session.waitForPendingOutput()
            initialPaintReady = true
            revealInitialViewport()
        }
    }

    /// Puts the caret low in the viewport, and scrolls left when it is near the
    /// leading edge. Pure so the placement can be tested without UIKit layout.
    static func initialOffset(caret: CGRect, content: CGSize, visible: CGSize) -> CGPoint {
        let maxX = max(0, content.width - visible.width)
        let maxY = max(0, content.height - visible.height)
        let x = caret.minX < visible.width / 3
            ? 0
            : min(max(0, caret.midX - visible.width / 2), maxX)
        let y = min(max(0, caret.midY - visible.height * 0.75), maxY)
        return CGPoint(x: x, y: y)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        initialViewportPending = false
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        initialViewportPending = false
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        terminal
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        alignToBottom()
        notifyZoom()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        initialViewportPending = false
        zoomMode = abs(scale - minimumZoomScale) < 0.001 ? .overview : .custom
        notifyZoom()
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        initialViewportPending = false
        if zoomScale > minimumZoomScale + 0.001 {
            zoomMode = .overview
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            // Zoom to a readable font around the tap.
            let point = gesture.location(in: terminal)
            let scale = max(minimumZoomScale * 1.5, readableZoomScale)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoomMode = .custom
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
        // A double tap has no visible control; confirm it landed, and say
        // where it landed for VoiceOver.
        UISelectionFeedbackGenerator().selectionChanged()
        notifyZoom()
        UIAccessibility.post(notification: .announcement, argument: lastZoomNote)
    }

    // MARK: Text selection

    /// Ghostty snapshots the visible rows and the word under the finger; the
    /// page turns that into a selectable sheet. Nothing is typed or resized.
    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        onTextSelection?(TerminalTextSelection(text: request.text, anchor: request.anchorRange))
    }
}

/// Lets a long press select text without making the terminal a text input:
/// a tap never becomes first responder, so no keyboard appears, and the
/// surrounding scroll view keeps its pan and zoom.
private final class SelectionOnlyTerminalView: UITerminalView {
    override var canBecomeFirstResponder: Bool { false }

    override func toggleSoftwareKeyboard() {}
}
