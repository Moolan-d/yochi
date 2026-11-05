import Foundation

/// One row of the home page: an Agent, or a plain terminal folded at the
/// bottom of its space.
struct HomeRow: Identifiable, Equatable {
    let session: Session
    /// The space it lives in; nil outside Herdr's spaces.
    let space: String?
    /// The tab's name when someone named it; numbered tabs have none.
    let tab: String?
    /// Finished a turn neither Herdr's desktop nor this iPhone has shown.
    let unseen: Bool

    var id: String { session.id }
}

/// A Herdr space, or the sessions of one machine in no space.
struct HomeGroup: Identifiable, Equatable {
    enum Kind: Equatable {
        case space
        /// Sessions in no Herdr space, for one machine.
        case others
    }

    let id: String
    let kind: Kind
    let title: String
    /// A remote machine's name; nil for the Gateway's own Mac.
    let machine: String?
    /// Pinned ones first, each followed by the child Agents it started.
    let agents: [HomeRow]
    /// Shells, dev servers and the like, folded under the Agents.
    let terminals: [HomeRow]
}

struct Home: Equatable {
    /// Waiting on the user first, then finished and not looked at yet; they
    /// stay in their own group too.
    let needsYou: [HomeRow]
    let groups: [HomeGroup]
}

/// The home page: Agents by Herdr space, then by machine for sessions in no
/// space. Without spaces (an older Gateway, or no Herdr layout) every
/// machine's sessions form one group. `seen` holds the turn this iPhone last
/// showed for each session.
func makeHome(sessions: [Session], spaces: [Space], seen: [String: UInt64] = [:]) -> Home {
    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let row = { (session: Session, space: String?, tab: String?) in
        HomeRow(session: session, space: space, tab: tab, unseen: isUnseen(session, seen: seen[session.id]))
    }
    var placed = Set<String>()
    var groups: [HomeGroup] = []

    for space in spaces {
        let rows = space.tabs.flatMap { tab in
            tab.sessions.compactMap { byID[$0] }
                .filter { placed.insert($0.id).inserted }
                .map { row($0, space.name, namedTab(tab.name)) }
        }
        guard !rows.isEmpty else { continue }
        groups.append(HomeGroup(
            id: space.id, kind: .space, title: space.name, machine: space.machine,
            agents: pinnedFirst(rows.filter(\.session.isAgent)), terminals: rows.filter { !$0.session.isAgent }))
    }

    let others = Dictionary(grouping: sessions.filter { !placed.contains($0.id) }, by: \.machine)
        .sorted { ($0.key ?? "") < ($1.key ?? "") }
    for (machine, group) in others {
        let rows = childrenAfterParents(group).map { row($0, nil, nil) }
        groups.append(HomeGroup(
            id: "others/\(machine ?? "")", kind: .others,
            title: spaces.isEmpty ? (machine ?? String(localized: "This Mac")) : String(localized: "Other Terminals"),
            machine: spaces.isEmpty ? nil : machine,
            agents: pinnedFirst(rows.filter(\.session.isAgent)), terminals: rows.filter { !$0.session.isAgent }))
    }

    // In list order, so it matches what the user sees below.
    let agents = groups.flatMap(\.agents)
    let needsYou = agents.filter { $0.session.status?.state == "blocked" } + agents.filter(\.unseen)
    return Home(needsYou: needsYou, groups: groups)
}

func isUnseen(_ session: Session, seen: UInt64?) -> Bool {
    session.status?.state == "done" && session.turn > max(session.seen ?? 0, seen ?? 0)
}

/// The other terminals in the session's Herdr tab, in pane order; none when
/// it is in no tab.
func tabMates(of id: String, sessions: [Session], spaces: [Space]) -> [Session] {
    guard let tab = spaces.lazy.flatMap(\.tabs).first(where: { $0.sessions.contains(id) }) else { return [] }
    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return tab.sessions.filter { $0 != id }.compactMap { byID[$0] }
}

/// Herdr numbers the tabs nobody named; those numbers say nothing on a row.
func namedTab(_ name: String) -> String? {
    let name = name.trimmingCharacters(in: .whitespaces)
    return name.isEmpty || name.allSatisfy(\.isNumber) ? nil : name
}

/// Pinned Agents move to the top, each with the child Agents it started;
/// otherwise the order stays.
private func pinnedFirst(_ rows: [HomeRow]) -> [HomeRow] {
    let byID = Dictionary(rows.map { ($0.id, $0.session) }, uniquingKeysWith: { first, _ in first })
    func root(_ session: Session) -> Session {
        var current = session
        var steps = 0
        while let parent = current.parent.flatMap({ byID[$0] }), steps < 32 {
            current = parent
            steps += 1
        }
        return current
    }
    let pinned = rows.filter { root($0.session).pinned }
    return pinned + rows.filter { !root($0.session).pinned }
}

/// Each child Agent right after the terminal that started it and that
/// terminal's earlier children, as the Gateway orders a tab.
func childrenAfterParents(_ sessions: [Session]) -> [Session] {
    let ids = Set(sessions.map(\.id))
    let children = Dictionary(grouping: sessions.filter { $0.parent.map(ids.contains) == true }, by: { $0.parent ?? "" })
    var ordered: [Session] = []
    var seen = Set<String>()
    func add(_ session: Session) {
        guard seen.insert(session.id).inserted else { return }
        ordered.append(session)
        children[session.id]?.forEach(add)
    }
    sessions.filter { $0.parent.map(ids.contains) != true }.forEach(add)
    // A loop of parents has no root; keep those where they were.
    sessions.forEach(add)
    return ordered
}

// MARK: - What a row says

extension HomeRow {
    var folder: String { session.folder }

    /// The Agent's own title (Claude Code's session title); a generic one
    /// gives way to the tab's name, then the folder's.
    var title: String {
        let title = session.title.trimmingCharacters(in: .whitespaces)
        guard session.isAgent else { return title.isEmpty ? (session.program ?? folder) : title }
        let generic = title.isEmpty || title == session.id || title == session.program
            || ["claude", "claude code"].contains(title.lowercased())
            || title.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil
        return generic ? (tab ?? folder) : title
    }

    /// The third line: repository · worktree · tab; the folder when it is no
    /// repository. In 需要你 the space comes first, since the row is away from it.
    func place(awayFromSpace: Bool) -> String {
        let machine = awayFromSpace ? session.machine : nil
        let space = awayFromSpace ? space : nil
        let parts: [String?] = [machine, space, session.repo?.name ?? folder, session.repo?.worktree, tab]
        // A space named after its repository says it once.
        let words = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return words.enumerated().filter { $0.offset == 0 || words[$0.offset - 1] != $0.element }
            .map(\.element).joined(separator: " · ")
    }

    /// The second line: what the Agent needs or does now; nil when it rests.
    func activity(at now: Date) -> String? {
        guard let status = session.status else { return nil }
        let since = session.statusMs.map { Int64(now.timeIntervalSince1970 * 1000) - $0 }
        let text: String? = switch status.state {
        case "blocked":
            status.message ?? String(localized: "Needs you")
        case "working":
            [session.todo.map { TodoProgress($0).text } ?? String(localized: "Working"), since.map { Elapsed.text(milliseconds: $0) }]
                .compactMap { $0 }.joined(separator: " · ")
        case "done":
            since.map { String(localized: "Done · \(Ago.text(milliseconds: $0))") } ?? String(localized: "Done")
        case "error":
            status.message.map { String(localized: "Error: \($0)") } ?? String(localized: "Error")
        default:
            nil
        }
        guard session.parent != nil else { return text }
        return [String(localized: "Child Agent"), text].compactMap { $0 }.joined(separator: " · ")
    }

    /// The status in a word, for VoiceOver and the collapsed space.
    var stateWord: String? {
        switch session.status?.state {
        case "blocked": String(localized: "Needs you")
        case "working": String(localized: "Working")
        case "done": unseen ? String(localized: "Done, not yet seen") : String(localized: "Completed")
        case "error": String(localized: "Error")
        case "idle": String(localized: "Idle")
        // A known Agent CLI that reports nothing (yet).
        default: session.status == nil && session.isAgent ? String(localized: "Running") : nil
        }
    }

    /// Read once, not every second.
    func accessibilityLabel(awayFromSpace: Bool = false) -> String {
        // The ticking time stays out; the state word says enough.
        let activity: String? = switch session.status?.state {
        case "working": session.todo.map { TodoProgress($0).accessibilityLabel }
        case "blocked", "error": session.status?.message
        default: nil
        }
        return [pinnedWord, title, session.parent != nil ? String(localized: "Child Agent") : nil, stateWord, activity, place(awayFromSpace: awayFromSpace)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: String(localized: "detail.separator", defaultValue: ", "))
    }

    private var pinnedWord: String? { session.pinned ? String(localized: "Pinned") : nil }

    /// Search by what the row shows and where it lives.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, session.title, session.repo?.name, session.repo?.worktree, tab, space, folder, session.machine]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension HomeGroup {
    /// The most pressing state among its Agents: waiting > working > unseen.
    var summary: HomeSummary? {
        if agents.contains(where: { $0.session.status?.state == "blocked" }) { return .blocked }
        if agents.contains(where: { $0.session.status?.state == "working" }) { return .working }
        if agents.contains(where: \.unseen) { return .unseen }
        return nil
    }
}

enum HomeSummary: Equatable {
    case blocked, working, unseen

    var word: String {
        switch self {
        case .blocked: String(localized: "An Agent needs you")
        case .working: String(localized: "An Agent is working")
        case .unseen: String(localized: "Unseen results")
        }
    }
}

/// How long ago, in the words of a list: 刚刚, 3 分钟前, 2 小时前, 4 天前.
enum Ago {
    static func text(milliseconds: Int64) -> String {
        let seconds = max(milliseconds, 0) / 1000
        switch seconds {
        case ..<60: return String(localized: "just now")
        case ..<3600: return String(localized: "\(seconds / 60)m ago")
        case ..<86400: return String(localized: "\(seconds / 3600)h ago")
        default: return String(localized: "\(seconds / 86400)d ago")
        }
    }
}
