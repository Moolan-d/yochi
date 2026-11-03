import Foundation

/// One section of the session list.
struct SessionSection: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Agents waiting for the user to approve, answer or log in, from every space.
        case needsMe
        case space
        /// Sessions in no Herdr space, for one machine.
        case others
    }

    let id: String
    let kind: Kind
    let title: String
    /// A remote machine's name; nil for the Gateway's own Mac.
    let machine: String?
    let tabs: [SessionTabGroup]
}

struct SessionTabGroup: Identifiable, Equatable {
    let id: String
    /// Nil when the section has only this tab: its rows go straight under the header.
    let title: String?
    let entries: [SessionEntry]
}

struct SessionEntry: Identifiable, Equatable {
    let session: Session
    /// Where the session lives, for rows shown outside their space.
    let place: String?

    var id: String { session.id }
}

/// Agents waiting on the user first, then Herdr's spaces and their tabs, then
/// sessions in no space by machine. Without spaces (an older Gateway, or no
/// Herdr layout) every machine's sessions form one section, as before.
func sessionSections(sessions: [Session], spaces: [Space]) -> [SessionSection] {
    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var placed: [String: String] = [:]
    var sections: [SessionSection] = []

    for space in spaces {
        let tabs = space.tabs.compactMap { tab -> SessionTabGroup? in
            let entries = tab.sessions.compactMap { byID[$0] }.map { SessionEntry(session: $0, place: nil) }
            guard !entries.isEmpty else { return nil }
            for entry in entries where placed[entry.id] == nil {
                placed[entry.id] = space.tabs.count > 1 ? "\(space.name) · \(tab.name)" : space.name
            }
            return SessionTabGroup(id: tab.id, title: space.tabs.count > 1 ? tab.name : nil, entries: entries)
        }
        guard !tabs.isEmpty else { continue }
        sections.append(SessionSection(id: space.id, kind: .space, title: space.name, machine: space.machine, tabs: tabs))
    }

    let others = Dictionary(grouping: sessions.filter { placed[$0.id] == nil }, by: \.machine)
        .sorted { ($0.key ?? "") < ($1.key ?? "") }
    for (machine, group) in others {
        let entries = childrenAfterParents(group).map { SessionEntry(session: $0, place: nil) }
        sections.append(SessionSection(
            id: "others/\(machine ?? "")", kind: .others,
            title: spaces.isEmpty ? (machine ?? "本机") : "其他终端",
            machine: spaces.isEmpty ? nil : machine,
            tabs: [SessionTabGroup(id: "others/\(machine ?? "")", title: nil, entries: entries)]))
    }

    // In list order, so it matches what the user sees below.
    var seen = Set<String>()
    let waiting = sections.flatMap { $0.tabs.flatMap(\.entries) }
        .filter { $0.session.status?.state == "blocked" && seen.insert($0.id).inserted }
        .map { entry in
            let machine = entry.session.machine.map { "\($0) · " } ?? ""
            return SessionEntry(session: entry.session, place: placed[entry.id].map { machine + $0 } ?? entry.session.machine)
        }
    if !waiting.isEmpty {
        sections.insert(SessionSection(
            id: "needs-me", kind: .needsMe, title: "需要处理", machine: nil,
            tabs: [SessionTabGroup(id: "needs-me", title: nil, entries: waiting)]), at: 0)
    }
    return sections
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
