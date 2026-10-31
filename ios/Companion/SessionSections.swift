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

    /// The most urgent Agent Status in the section.
    var status: String? { AgentStatus.mostUrgent(tabs.flatMap(\.entries).map(\.session)) }
}

struct SessionTabGroup: Identifiable, Equatable {
    let id: String
    /// Nil when the section has only this tab: its rows go straight under the header.
    let title: String?
    let entries: [SessionEntry]

    var status: String? { AgentStatus.mostUrgent(entries.map(\.session)) }
}

struct SessionEntry: Identifiable, Equatable {
    let session: Session
    /// Where the session lives, for rows shown outside their space.
    let place: String?

    var id: String { session.id }
}

enum AgentStatus {
    /// Blocked first: it is the one that needs the user.
    static func rank(_ state: String) -> Int {
        switch state {
        case "blocked": 0
        case "error": 1
        case "working": 2
        case "done": 3
        case "idle": 4
        default: 5
        }
    }

    static func mostUrgent(_ sessions: [Session]) -> String? {
        sessions.compactMap { $0.status?.state }.min { rank($0) < rank($1) }
    }
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
        let entries = group.map { SessionEntry(session: $0, place: nil) }
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
