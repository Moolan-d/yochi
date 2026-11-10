import SwiftUI

/// The home's two tabs.
enum HomeTab: Hashable {
    case inbox, spaces
}

/// Where a tab's navigation stack can go.
enum Route: Hashable {
    /// A terminal's page: the conversation, or the terminal itself.
    case session(Session)
    /// A space's tabs and terminals, by the space's id.
    case space(String)
    /// What one machine has in no space; nil for the Gateway's own Mac.
    case others(machine: String?)
}

extension Array where Element == Route {
    /// The session at the end of the stack, when the page open is one.
    var openSession: Session? {
        if case .session(let session)? = last { return session }
        return nil
    }

    /// Every session open anywhere in the stack.
    var sessions: [Session] {
        compactMap { if case .session(let session) = $0 { session } else { nil } }
    }
}

/// The page behind a route that isn't a terminal's: the home's own pages,
/// read from the same data as the tabs. `page` makes the page of a session.
struct HomeRouteView<Page: View>: View {
    let route: Route
    let sessions: [Session]
    let spaces: [Space]
    let seen: [String: UInt64]
    let queued: (String) -> Bool
    @ViewBuilder var page: (Session) -> Page

    var body: some View {
        switch route {
        case .session(let session):
            page(session)
        case .space(let id):
            let board = makeSpacesBoard(sessions: sessions, spaces: spaces, seen: seen)
            let entry = board.lazy.flatMap(\.spaces).first { $0.id == id }
            SpaceDetailView(entry: entry, machine: board.first { $0.spaces.contains { $0.id == id } }?.title, queued: queued)
        case .others(let machine):
            let section = makeSpacesBoard(sessions: sessions, spaces: spaces, seen: seen).first { $0.machine == machine }
            OtherTerminalsView(
                title: section?.title ?? machine ?? String(localized: "This Mac"),
                flat: spaces.isEmpty, rows: section?.others ?? [], queued: queued)
        }
    }
}
