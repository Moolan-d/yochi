import SwiftUI

/// The Inbox tab for the Gateway's sessions: what the Gateway says when it
/// has none to show, else the Agents by state.
struct InboxScreen: View {
    let client: GatewayClient
    let seen: SeenTurns
    var retry: () -> Void
    var reenter: () -> Void
    var newSession: () -> Void

    var body: some View {
        let _ = Perf.count("InboxScreen")
        InboxList(
            inbox: makeInbox(sessions: client.sessions, spaces: client.spaces, seen: seen.turns),
            queued: { client.queuedMessage(session: $0) != nil },
            newSession: client.phase == .connected ? newSession : nil,
            showsEmpty: client.listIsSettled
        ) {
            StaleBanner(client: client)
        }
        .overlay {
            if !client.listIsSettled {
                ConnectionState(client: client, retry: retry, reenter: reenter)
            }
        }
        .task {
            // Once the first frame is up, while the Gateway is still connecting.
            try? await Task.sleep(for: .milliseconds(200))
            TerminalWarmup.run()
        }
    }
}

/// The Spaces tab for the Gateway's sessions.
struct SpacesScreen: View {
    let client: GatewayClient
    let seen: SeenTurns
    var retry: () -> Void
    var reenter: () -> Void
    var newSession: () -> Void

    var body: some View {
        let _ = Perf.count("SpacesScreen")
        SpacesList(
            board: makeSpacesBoard(sessions: client.sessions, spaces: client.spaces, seen: seen.turns),
            newSession: client.phase == .connected ? newSession : nil,
            showsEmpty: client.listIsSettled
        ) {
            StaleBanner(client: client)
        }
        .overlay {
            if !client.listIsSettled {
                ConnectionState(client: client, retry: retry, reenter: reenter)
            }
        }
    }
}

/// Sessions shown while disconnected are stale; say so above them.
private struct StaleBanner: View {
    let client: GatewayClient

    var body: some View {
        if client.phase != .connected && !client.sessions.isEmpty {
            Section {
                Label(client.statusText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Why there is nothing to list yet, when the Gateway can't say otherwise.
private struct ConnectionState: View {
    let client: GatewayClient
    var retry: () -> Void
    var reenter: () -> Void

    var body: some View {
        switch client.phase {
        case .disconnected, .connecting:
            ProgressView("Connecting…")
        case .failed(let reason):
            ContentUnavailableView {
                Label("Can't Connect to the Gateway", systemImage: "wifi.exclamationmark")
            } description: {
                Text(reason)
            } actions: {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        case .unauthorized:
            ContentUnavailableView {
                Label("Pairing no longer valid", systemImage: "key.slash")
            } description: {
                Text("The Gateway no longer accepts this iPhone. Its pairing may have been removed on the main Mac.")
            } actions: {
                Button("Pair Again", action: reenter)
                    .buttonStyle(.borderedProminent)
            }
        case .connected where !client.coreConnected:
            ContentUnavailableView(
                "Can't Reach herdr-core",
                systemImage: "bolt.horizontal.circle",
                description: Text("Connected to the Gateway, but herdr-core on the main Mac isn't responding."))
        case .connected:
            // The list itself says there is nothing to show.
            Color.clear.allowsHitTesting(false)
        }
    }
}

extension GatewayClient {
    /// The lists speak for themselves: they have sessions, or the Gateway
    /// and herdr-core are both up and there are none. Otherwise the screen
    /// says why it has nothing yet.
    var listIsSettled: Bool {
        !sessions.isEmpty || (phase == .connected && coreConnected)
    }

    var statusText: String {
        switch phase {
        case .disconnected: String(localized: "Not connected")
        case .connecting: String(localized: "Connecting…")
        case .connected: coreConnected ? String(localized: "Connected") : String(localized: "herdr-core unavailable")
        case .failed(let reason): String(localized: "Couldn't connect: \(reason)")
        case .unauthorized: String(localized: "Pairing no longer valid")
        }
    }
}

/// The turn this iPhone last showed for each session, kept on the phone:
/// opening a finished Agent's conversation takes it out of 需要你.
@MainActor @Observable
final class SeenTurns {
    private static let key = "seenTurns"
    private(set) var turns: [String: UInt64]

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
        turns = stored.mapValues { UInt64(max($0, 0)) }
    }

    func record(_ session: Session) {
        guard session.turn > turns[session.id] ?? 0 else { return }
        turns[session.id] = session.turn
        save()
    }

    /// Ended terminals' ids go, so the store doesn't grow forever.
    func keep(only sessions: [Session]) {
        let ids = Set(sessions.map(\.id))
        guard turns.keys.contains(where: { !ids.contains($0) }) else { return }
        turns = turns.filter { ids.contains($0.key) }
        save()
    }

    private func save() {
        UserDefaults.standard.set(turns.mapValues { Int(clamping: $0) }, forKey: Self.key)
    }
}

/// Each conversation Agent's brand color, a shade darker in light mode so
/// the mark keeps 3:1 against the row.
enum AgentBrand {
    /// Only an Agent whose page is the conversation wears its maker's color;
    /// terminals and the other Agents keep the plain mark.
    static func color(for session: Session) -> Color? {
        guard session.showsConversation else { return nil }
        switch session.program?.lowercased() {
        case "claude": return claude
        default: return nil
        }
    }

    /// Anthropic's Claude orange.
    static let claude = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
            : UIColor(red: 0xC1 / 255, green: 0x5F / 255, blue: 0x3C / 255, alpha: 1)
    })
}

/// The working ring's turning arc. Core Animation turns it in the render
/// server, so no view is updated per frame: a list of working Agents costs
/// the main thread nothing while it waits for taps and keys.
struct SpinningArc: UIViewRepresentable {
    let lineWidth: CGFloat

    func makeUIView(context: Context) -> SpinningArcView { SpinningArcView() }

    func updateUIView(_ view: SpinningArcView, context: Context) {
        view.lineWidth = lineWidth
    }
}

final class SpinningArcView: UIView {
    private let arc = CAShapeLayer()
    var lineWidth: CGFloat = 2 {
        didSet { if lineWidth != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        arc.fillColor = nil
        arc.lineCap = .round
        layer.addSublayer(arc)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A loose layer animates every change; the arc should just be redrawn.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        arc.frame = bounds
        let radius = max(0, min(bounds.width, bounds.height) / 2 - lineWidth / 2)
        // Three tenths of a turn from three o'clock, as the still ring draws it.
        arc.path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                                startAngle: 0, endAngle: .pi * 2 * 0.3, clockwise: true).cgPath
        arc.lineWidth = lineWidth
        arc.strokeColor = UIColor.systemBlue.resolvedColor(with: traitCollection).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A reused row, or one back from the background, turns again.
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 1.2
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}
