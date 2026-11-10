import SwiftUI
import UIKit

/// A tab's panes laid out in a rectangle, as Herdr splits it.
struct PaneFrame: Equatable {
    let session: String?
    let rect: CGRect
}

extension PaneNode {
    /// A tab with no tree from the Gateway: its sessions side by side.
    static func row(of sessions: [String]) -> PaneNode {
        PaneNode(split: .row, children: sessions.map { PaneNode(session: $0) })
    }

    /// Each pane's rectangle within `rect`, `gap` apart.
    func frames(in rect: CGRect, gap: CGFloat = 0) -> [PaneFrame] {
        guard let split, !children.isEmpty else { return [PaneFrame(session: session, rect: rect)] }
        let shares = children.map { max($0.weight ?? 1 / Double(children.count), 0.0001) }
        let total = shares.reduce(0, +)
        let length = split == .row ? rect.width : rect.height
        let room = max(length - gap * CGFloat(children.count - 1), 0)
        var start = split == .row ? rect.minX : rect.minY
        var frames: [PaneFrame] = []
        for (child, share) in zip(children, shares) {
            let size = room * CGFloat(share / total)
            let part = split == .row
                ? CGRect(x: start, y: rect.minY, width: size, height: rect.height)
                : CGRect(x: rect.minX, y: start, width: rect.width, height: size)
            frames += child.frames(in: part, gap: gap)
            start += size + gap
        }
        return frames
    }

    var sessions: [String] {
        (session.map { [$0] } ?? []) + children.flatMap(\.sessions)
    }
}

/// The tab a session is in, with the pane to light up for it: its own, or
/// for a child Agent (not in Herdr's layout) the pane of the terminal that
/// started it.
struct PaneTab: Equatable {
    let layout: PaneNode
    /// Sessions in the order a swipe goes through them.
    let order: [String]
    let current: String
    let lit: String?

    init?(of id: String, sessions: [Session], spaces: [Space]) {
        guard let tab = spaces.lazy.flatMap(\.tabs).first(where: { $0.sessions.contains(id) }),
              tab.sessions.count > 1 else { return nil }
        layout = tab.layout ?? .row(of: tab.sessions)
        order = tab.sessions
        current = id
        let drawn = Set(layout.sessions)
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lit: String? = id
        var steps = 0
        while let candidate = lit, !drawn.contains(candidate), steps < 32 {
            lit = byID[candidate]?.parent
            steps += 1
        }
        self.lit = lit.flatMap { drawn.contains($0) ? $0 : nil }
    }

    /// The session `step` places along, or nil past either end.
    func neighbor(_ step: Int) -> String? {
        guard let index = order.firstIndex(of: current), order.indices.contains(index + step) else { return nil }
        return order[index + step]
    }
}

/// The small map of a tab's panes shown while switching between them, the
/// current one lit.
struct PaneMap: View {
    let tab: PaneTab

    var body: some View {
        Canvas { context, size in
            let frames = tab.layout.frames(in: CGRect(origin: .zero, size: size), gap: 3)
            for frame in frames {
                let shape = Path(roundedRect: frame.rect, cornerRadius: 3, style: .continuous)
                let lit = frame.session != nil && frame.session == tab.lit
                context.fill(shape, with: .color(lit ? .accentColor : Color(.tertiaryLabel).opacity(0.5)))
            }
        }
        .frame(width: 60, height: 40)
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityHidden(true)
    }
}

/// A one-finger sideways swipe across the page, away from the left edge
/// (which stays Back): `step` +1 for a swipe to the left (the next pane),
/// -1 to the right. Anything that scrolls sideways under the finger, and
/// up-and-down drags, keep the touch.
struct PaneSwipeGesture: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var began: () -> Void
    var ended: (_ step: Int?) -> Void

    /// Room along the left edge for the system's Back swipe.
    static let edge: CGFloat = 32
    static let distance: CGFloat = 60
    static let flick: CGFloat = 400

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = context.coordinator
        pan.isEnabled = enabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            began()
        case .ended:
            let moved = recognizer.translation(in: recognizer.view).x
            let speed = recognizer.velocity(in: recognizer.view).x
            ended(Self.step(moved: moved, speed: speed))
        case .cancelled, .failed:
            ended(nil)
        default:
            break
        }
    }

    /// Far or fast enough, and not flicked back the other way.
    static func step(moved: CGFloat, speed: CGFloat) -> Int? {
        guard moved != 0 else { return nil }
        let left = moved < 0
        let flickedBack = (speed < 0) != left && abs(speed) > 100
        guard !flickedBack, abs(moved) >= distance || abs(speed) >= flick else { return nil }
        return left ? 1 : -1
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let window = pan.view?.window else { return false }
            let velocity = pan.velocity(in: window)
            guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
            let now = pan.location(in: window)
            let start = CGPoint(x: now.x - pan.translation(in: window).x, y: now.y - pan.translation(in: window).y)
            guard start.x > PaneSwipeGesture.edge else { return false }
            var view = window.hitTest(start, with: nil)
            while let current = view, current !== window {
                if let scroll = current as? UIScrollView, Self.scrolls(scroll, left: velocity.x < 0) { return false }
                view = current.superview
            }
            return true
        }

        /// Whether `scroll` can still move its content the way the finger goes.
        private static func scrolls(_ scroll: UIScrollView, left: Bool) -> Bool {
            guard scroll.isScrollEnabled else { return false }
            let inset = scroll.adjustedContentInset
            let lowest = -inset.left
            let highest = scroll.contentSize.width + inset.right - scroll.bounds.width
            guard highest > lowest + 1 else { return false }
            return left ? scroll.contentOffset.x < highest - 0.5 : scroll.contentOffset.x > lowest + 0.5
        }

        /// The page's other drags (its scrolling, the terminal's own pans,
        /// the full-width Back swipe) wait until this is not a sideways
        /// swipe; the left edge's Back swipe does not.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && !(other is UIScreenEdgePanGestureRecognizer)
        }
    }
}
