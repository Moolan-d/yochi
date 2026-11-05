import CoreGraphics
import Foundation

/// Where a drag through the terminal's history stands, finer than a row.
/// Ghostty scrolls whole rows; the page shifts the surface by what is left of
/// one, so the text follows the finger point for point. The surface keeps a
/// row ahead on the edge new lines come in from, which is therefore always
/// drawn; the edge lines leave from may show up to a row of background.
struct HistoryScroll: Equatable {
    /// One row, in points.
    let cell: CGFloat
    /// The last row the viewport can start at: the newest screen.
    var lastRow: Int {
        didSet { position = min(position, maxPosition) }
    }
    /// The viewport's top, in points down from the top of the history.
    private(set) var position: CGFloat
    /// Whether the last move went toward older lines.
    private var towardOlder = true

    init(cell: CGFloat, row: Int, lastRow: Int) {
        self.cell = cell
        self.lastRow = max(lastRow, 0)
        position = CGFloat(min(max(row, 0), max(lastRow, 0))) * cell
    }

    var maxPosition: CGFloat { CGFloat(lastRow) * cell }

    /// Moves the viewport by `delta` points: negative toward older lines.
    mutating func move(by delta: CGFloat) {
        guard delta != 0 else { return }
        towardOlder = delta < 0
        position = min(max(position + delta, 0), maxPosition)
    }

    mutating func move(to position: CGFloat) {
        move(by: position - self.position)
    }

    /// The row Ghostty shows and how far the surface is shifted down from
    /// it, so that row's top sits at `position`.
    var frame: (row: Int, shift: CGFloat) {
        let exact = position / cell
        let nearest = exact.rounded()
        let row: CGFloat
        if abs(exact - nearest) < 0.001 {
            row = nearest
        } else {
            // Older lines come in at the top: show the row they start, its
            // top cut off; newer lines come in at the bottom.
            row = towardOlder ? exact.rounded(.down) : exact.rounded(.up)
        }
        let clamped = min(max(Int(row), 0), lastRow)
        return (clamped, CGFloat(clamped) * cell - position)
    }

    var atRest: Bool { frame.shift == 0 }
}

/// The coast after a flick, decelerating as a UIScrollView does and aimed to
/// come to rest on a whole row. Starts at the finger's speed.
struct HistoryGlide: Equatable {
    let start: CGFloat
    let target: CGFloat
    /// How fast the remaining distance shrinks, per second.
    let rate: Double

    /// UIScrollView's normal deceleration, 0.998 per millisecond.
    static let deceleration = -log(0.998) * 1000
    /// A slow release only settles onto the nearest row, quickly.
    static let settleRate = 12.0

    /// `velocity` in points per second along the history, positive toward
    /// newer lines.
    init(from scroll: HistoryScroll, velocity: CGFloat) {
        start = scroll.position
        let cell = scroll.cell
        let coast = abs(velocity) < 50 ? 0 : velocity / Self.deceleration
        let landing = ((start + coast) / cell).rounded() * cell
        target = min(max(landing, 0), scroll.maxPosition)
        let distance = target - start
        if abs(velocity) >= 50, distance != 0, (distance > 0) == (velocity > 0) {
            // Keep the finger's speed: the curve's slope at the start.
            rate = min(max(Double(velocity / distance), 1.5), Self.settleRate)
        } else {
            rate = Self.settleRate
        }
    }

    func position(at elapsed: Double) -> CGFloat {
        start + (target - start) * CGFloat(1 - exp(-rate * elapsed))
    }

    func isDone(at elapsed: Double) -> Bool {
        abs(target - position(at: elapsed)) < 0.25
    }
}
