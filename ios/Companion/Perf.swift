import os
import QuartzCore
import UIKit

/// Performance marks: signposts for Instruments (Points of Interest) and, in
/// debug builds, a log line per measured window that the perf UI tests read
/// with `log stream --predicate 'subsystem == "dev.companion.perf"'`.
enum Perf {
    static let log = Logger(subsystem: "dev.companion.perf", category: "perf")
    static let signposter = OSSignposter(subsystem: "dev.companion.perf", category: .pointsOfInterest)

    /// Counts a body evaluation (or any event) for the window the frame meter
    /// is measuring. Debug only; `let _ = Perf.count("…")` inside a body.
    @MainActor
    static func count(_ name: String) {
        #if DEBUG
        guard FrameMeter.shared.isRunning else { return }
        FrameMeter.shared.counts[name, default: 0] += 1
        #endif
    }

    /// How long a page took from opening to showing its content.
    static func shown(_ what: String, since start: ContinuousClock.Instant, cached: Bool) {
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        log.notice("shown \(what, privacy: .public) cached=\(cached, privacy: .public) ms=\(ms, format: .fixed(precision: 1), privacy: .public)")
    }
}

/// Frame pacing while a finger scrolls the terminal and its momentum runs
/// out: how many frames came late and by how much. Debug only.
@MainActor
final class FrameMeter {
    static let shared = FrameMeter()

    private(set) var isRunning = false
    var counts: [String: Int] = [:]
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var hitchTime: CFTimeInterval = 0
    private var longest: CFTimeInterval = 0
    private var deadline: CFTimeInterval = 0
    private var lastTouch: CFTimeInterval = 0
    /// After the last touch has settled: only the app draws then. Under UI
    /// tests, XCTest snapshots the app's accessibility tree on the main
    /// thread before each synthesized touch, which drops frames of its own.
    private var tailFrames = 0
    private var tailHitches = 0
    private var tailLongest: CFTimeInterval = 0

    /// A touch began: measure until two seconds after the last one.
    func touch() {
        #if DEBUG
        lastTouch = CACurrentMediaTime()
        deadline = lastTouch + 2
        guard !isRunning else { return }
        isRunning = true
        counts = [:]
        frames = 0
        hitches = 0
        hitchTime = 0
        longest = 0
        tailFrames = 0
        tailHitches = 0
        tailLongest = 0
        last = 0
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        #endif
    }

    @objc private func frame(_ link: CADisplayLink) {
        let expected = link.targetTimestamp - link.timestamp
        if last > 0 {
            let interval = link.timestamp - last
            frames += 1
            longest = max(longest, interval)
            // Late by more than half a frame: a hitch, as Instruments counts it.
            let hitch = expected > 0 && interval > expected * 1.5
            if hitch {
                hitches += 1
                hitchTime += interval - expected
            }
            // A synthesized flick lasts about a tenth of a second.
            if last > lastTouch + 0.3 {
                tailFrames += 1
                tailLongest = max(tailLongest, interval)
                if hitch { tailHitches += 1 }
            }
        }
        last = link.timestamp
        if link.timestamp >= deadline { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        isRunning = false
        let seconds = max(last - started, 0.001)
        let ratio = hitchTime * 1000 / seconds
        let counted = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        Perf.log.notice("frames scroll frames=\(self.frames, privacy: .public) hitches=\(self.hitches, privacy: .public) hitchRatio=\(ratio, format: .fixed(precision: 1), privacy: .public)ms/s longest=\(self.longest * 1000, format: .fixed(precision: 1), privacy: .public)ms tailFrames=\(self.tailFrames, privacy: .public) tailHitches=\(self.tailHitches, privacy: .public) tailLongest=\(self.tailLongest * 1000, format: .fixed(precision: 1), privacy: .public)ms \(counted, privacy: .public)")
    }
}

/// Watches touches on a view without taking part: it fails at once, so the
/// view's own gestures see every touch as before.
final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
