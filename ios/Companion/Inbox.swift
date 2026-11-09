import Foundation

/// One section of the Inbox: Agents in the same state, in list order.
struct InboxSection: Identifiable, Equatable {
    enum Kind: CaseIterable, Equatable {
        /// Blocked on the user, or failed.
        case needsYou
        /// Finished a turn nobody has looked at.
        case done
        case working
        /// Everything else: resting, or finished and seen.
        case idle

        var title: String {
            switch self {
            case .needsYou: String(localized: "Needs You")
            case .done: String(localized: "Done")
            case .working: String(localized: "Working")
            case .idle: String(localized: "Idle")
            }
        }
    }

    let kind: Kind
    let rows: [HomeRow]

    var id: Kind { kind }
}

/// The Inbox: every Agent across all spaces and machines by state, and the
/// terminals that only search reaches.
struct Inbox: Equatable {
    /// Only the sections that hold an Agent, in the order of `Kind`.
    let sections: [InboxSection]
    /// Shells, dev servers and the like, in list order.
    let terminals: [HomeRow]

    /// The Agents in the Needs You section: the Inbox tab's badge.
    var badge: Int { sections.first { $0.kind == .needsYou }?.rows.count ?? 0 }

    var agents: [HomeRow] { sections.flatMap(\.rows) }

    var isEmpty: Bool { sections.isEmpty }

    /// What a search finds, Agents and terminals apart, each in list order.
    func search(_ query: String) -> (agents: [HomeRow], terminals: [HomeRow]) {
        // Agents keep the order of the list, not of the sections.
        (listOrder.filter { $0.session.isAgent && $0.matches(query) }, terminals.filter { $0.matches(query) })
    }

    /// The Agents in the order of the home list, before sorting by state.
    let listOrder: [HomeRow]

    init(home: Home) {
        let agents = home.groups.flatMap(\.agents)
        listOrder = agents
        terminals = home.groups.flatMap(\.terminals)
        sections = Kind.allCases.compactMap { kind in
            let rows = agents.filter { $0.inboxSection == kind }
            return rows.isEmpty ? nil : InboxSection(kind: kind, rows: rows)
        }
    }

    private typealias Kind = InboxSection.Kind
}

func makeInbox(sessions: [Session], spaces: [Space], seen: [String: UInt64] = [:]) -> Inbox {
    Inbox(home: makeHome(sessions: sessions, spaces: spaces, seen: seen))
}

extension HomeRow {
    /// Which Inbox section an Agent belongs to.
    var inboxSection: InboxSection.Kind {
        switch session.status?.state {
        case "blocked", "error": .needsYou
        case "working": .working
        default: unseen ? .done : .idle
        }
    }

    /// The Agent's state, for a row's trailing edge.
    enum Signal: Equatable {
        case needsYou, error, working, unseen
    }

    var signal: Signal? {
        switch session.status?.state {
        case "blocked": .needsYou
        case "error": .error
        case "working": .working
        default: unseen ? .unseen : nil
        }
    }

    /// The second line of an Inbox row, when it has something to say.
    enum Detail: Equatable {
        /// What a blocked Agent asks.
        case question(String)
        /// Why an Agent failed.
        case failure(String)
        /// What a working Agent is on, from its to-do list.
        case progress(String)
    }

    var detail: Detail? {
        switch session.status?.state {
        case "blocked":
            session.status?.shownMessage.flatMap(nonEmpty).map(Detail.question)
        case "error":
            session.status?.message.flatMap(nonEmpty).map(Detail.failure)
        case "working":
            session.todo.map { Detail.progress(TodoProgress($0).text) }
        default:
            nil
        }
    }

    private func nonEmpty(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The third line of an Inbox row; a child Agent says so first.
    func placeLine(awayFromSpace: Bool) -> String {
        [session.parent != nil ? String(localized: "Child Agent") : nil, place(awayFromSpace: awayFromSpace)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A terminal's line under its title: what runs in it and where.
    var terminalLine: String {
        [session.program, place(awayFromSpace: true)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Since when the status holds, for the trailing edge; nil when the
    /// Gateway doesn't say or the Agent has no state.
    func since(at now: Date) -> String? {
        guard session.status != nil, let ms = session.statusMs else { return nil }
        return ShortAgo.text(milliseconds: Int64(now.timeIntervalSince1970 * 1000) - ms)
    }
}

/// How long ago, as short as a trailing edge allows: 4m, 1h, 2d.
enum ShortAgo {
    static func text(milliseconds: Int64) -> String {
        let seconds = max(milliseconds, 0) / 1000
        switch seconds {
        case ..<60: return String(localized: "now")
        case ..<3600: return String(localized: "\(seconds / 60)m")
        case ..<86400: return String(localized: "\(seconds / 3600)h")
        default: return String(localized: "\(seconds / 86400)d")
        }
    }
}
