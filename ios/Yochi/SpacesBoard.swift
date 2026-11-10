import Foundation

/// The colors a space's tile is filled with, picked by hashing its id so a
/// space keeps its color on every launch and every iPhone. White letters sit
/// on all of them at 3:1 or better, in light and dark.
enum SpacePalette {
    /// teal, blue, orange, purple, pink, green, indigo, brown.
    static let light: [UInt32] = [0x1E9A8D, 0x4A7FE6, 0xD9703F, 0x8E5BD0, 0xC9467E, 0x3E9A4A, 0x5561C9, 0x8B6A4F]
    /// A little deeper, so the tiles don't glare on a dark page.
    static let dark: [UInt32] = [0x1A8A7E, 0x4373D0, 0xC96536, 0x8050BF, 0xB93E72, 0x378A42, 0x4C57B8, 0x7C5F46]

    static var count: Int { light.count }

    /// FNV-1a over the id's UTF-8: unlike `hashValue`, the same on every run.
    static func index(for id: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}

/// How busy a pane is, for the little map of a tab.
enum PaneMark: Int, Comparable {
    case idle, working, blocked

    static func < (lhs: PaneMark, rhs: PaneMark) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A tab of a space: its terminals in pane order and how its panes lie.
struct SpaceTabEntry: Identifiable, Equatable {
    let id: String
    /// Herdr's name for it; a number when nobody named it.
    let name: String
    /// Where it stands among the space's tabs, from one.
    let position: Int
    let layout: PaneNode
    /// Every live terminal in it, child Agents after their parent.
    let rows: [HomeRow]
    /// By the session each pane shows.
    let marks: [String: PaneMark]

    /// The name, or "Tab 2" for the tabs nobody named.
    var title: String {
        namedTab(name) ?? String(localized: "Tab \(Int(name.trimmingCharacters(in: .whitespaces)) ?? position)")
    }
}

/// What a space's row says at its trailing edge.
enum SpaceStatus: Equatable {
    /// How many Agents wait on the user or failed.
    case needsYou(Int)
    case working
    case unseen
}

struct SpaceEntry: Identifiable, Equatable {
    let id: String
    let name: String
    /// A remote machine's name; nil for the Gateway's own Mac.
    let machine: String?
    let tabs: [SpaceTabEntry]

    var rows: [HomeRow] { tabs.flatMap(\.rows) }

    /// The most pressing state among its Agents: waiting > working > unseen.
    var status: SpaceStatus? {
        let agents = rows.filter(\.session.isAgent)
        let waiting = agents.filter { $0.inboxSection == .needsYou }.count
        if waiting > 0 { return .needsYou(waiting) }
        if agents.contains(where: { $0.inboxSection == .working }) { return .working }
        if agents.contains(where: \.unseen) { return .unseen }
        return nil
    }
}

/// The spaces of one machine, and the terminals it has in no space.
struct MachineSection: Identifiable, Equatable {
    /// nil for the Gateway's own Mac.
    let machine: String?
    let spaces: [SpaceEntry]
    /// Agents and terminals in no Herdr space.
    let others: [HomeRow]

    var id: String { machine ?? "" }

    var title: String { machine ?? String(localized: "This Mac") }
}

/// The Spaces tab: per machine (the Gateway's own Mac first), its spaces in
/// Herdr's order with their tabs, then what is in no space. A space or tab
/// with no live terminal is left out.
func makeSpacesBoard(sessions: [Session], spaces: [Space], seen: [String: UInt64] = [:]) -> [MachineSection] {
    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var placed = Set<String>()
    var entries: [SpaceEntry] = []

    for space in spaces {
        var tabs: [SpaceTabEntry] = []
        for (index, tab) in space.tabs.enumerated() {
            let rows = tab.sessions.compactMap { byID[$0] }
                .filter { placed.insert($0.id).inserted }
                .map { homeRow($0, space: space, tab: namedTab(tab.name), seen: seen) }
            guard !rows.isEmpty else { continue }
            let layout = tab.layout ?? .row(of: tab.sessions)
            tabs.append(SpaceTabEntry(
                id: tab.id, name: tab.name, position: index + 1, layout: layout, rows: rows,
                marks: paneMarks(layout: layout, rows: rows)))
        }
        if !tabs.isEmpty { entries.append(SpaceEntry(id: space.id, name: space.name, machine: space.machine, tabs: tabs)) }
    }

    let others = Dictionary(grouping: sessions.filter { !placed.contains($0.id) }, by: \.machine)
    let machines = Set(entries.map(\.machine)).union(others.keys)
    return machines.sorted { ($0 == nil ? "" : "\u{1}" + ($0 ?? "")) < ($1 == nil ? "" : "\u{1}" + ($1 ?? "")) }
        .map { machine in
            MachineSection(
                machine: machine,
                spaces: entries.filter { $0.machine == machine },
                others: childrenAfterParents(others[machine] ?? []).map { homeRow($0, space: nil, tab: nil, seen: seen) })
        }
}

func homeRow(_ session: Session, space: Space?, tab: String?, seen: [String: UInt64]) -> HomeRow {
    HomeRow(session: session, space: space?.name, tab: tab, unseen: isUnseen(session, seen: seen[session.id]), spaceID: space?.id)
}

/// Each pane's busiest state: its own Agent's, or a child Agent's started in
/// it (children are not in Herdr's layout).
func paneMarks(layout: PaneNode, rows: [HomeRow]) -> [String: PaneMark] {
    let drawn = Set(layout.sessions)
    let byID = Dictionary(rows.map { ($0.id, $0.session) }, uniquingKeysWith: { first, _ in first })
    var marks: [String: PaneMark] = [:]
    for row in rows {
        let mark: PaneMark = switch row.inboxSection {
        case .needsYou: .blocked
        case .working: .working
        default: .idle
        }
        var pane: String? = row.id
        var steps = 0
        while let candidate = pane, !drawn.contains(candidate), steps < 32 {
            pane = byID[candidate]?.parent
            steps += 1
        }
        guard let pane, drawn.contains(pane) else { continue }
        marks[pane] = max(marks[pane] ?? .idle, mark)
    }
    return marks
}
