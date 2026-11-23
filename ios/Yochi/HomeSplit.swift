import SwiftUI

// On a wide screen (an iPad, unless it is shared down to a narrow slice) each
// tab is two columns: its lists on the left, the open conversation or
// terminal on the right. The tab's path stays the one source of truth: its
// leading pages (a space, other terminals) are the left column's stack, and
// its last session is the right column.

extension Array where Element == Route {
    /// The pages before the first session: the left column's stack.
    var listRoutes: [Route] {
        Array(prefix { if case .session = $0 { false } else { true } })
    }

    /// The same path with `session` open on the right, keeping the left.
    func opening(_ session: Session) -> [Route] {
        listRoutes + [.session(session)]
    }
}

extension EnvironmentValues {
    /// Opens a session in the right column; nil where rows push instead.
    @Entry var openSessionInDetail: ((Session) -> Void)? = nil
    /// The session the right column shows, so its row stays marked.
    @Entry var sessionInDetail: String? = nil
}

/// A row that opens a session: a push on a narrow screen, and on a wide one
/// the right column, with the open row marked.
struct SessionRowLink<Label: View>: View {
    let session: Session
    @ViewBuilder var label: Label
    @Environment(\.openSessionInDetail) private var openInDetail
    @Environment(\.sessionInDetail) private var inDetail

    var body: some View {
        if let openInDetail {
            let open = inDetail == session.id
            Button { openInDetail(session) } label: {
                HStack(spacing: 0) {
                    label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(open ? .isSelected : [])
            .listRowBackground(open ? Color.accentColor.opacity(0.16) : Color.homeCard)
            .listRowSeparatorTint(Color.homeSeparator)
        } else {
            NavigationLink(value: Route.session(session)) { label }
                .homeRow()
        }
    }
}

/// The right column before anything is open.
struct NothingOpenView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Conversation Open", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Choose an Agent or terminal on the left.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.homePage)
    }
}

/// A tab's navigation: one stack on a narrow screen, two columns on a wide
/// one. `routePage` makes a pushed page, a session's included; `sessionPage`
/// makes the right column's.
struct HomeNavigation<Root: View, RoutePage: View, SessionPage: View, Buttons: ToolbarContent>: View {
    @Binding var path: [Route]
    let title: LocalizedStringKey
    @ViewBuilder var root: Root
    @ViewBuilder var routePage: (Route) -> RoutePage
    @ViewBuilder var sessionPage: (Session) -> SessionPage
    @ToolbarContentBuilder var buttons: Buttons
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            columns
        } else {
            NavigationStack(path: $path) { lists }
        }
    }

    private var lists: some View {
        root
            .navigationTitle(title)
            .navigationDestination(for: Route.self) { routePage($0) }
            .toolbar { buttons }
    }

    private var columns: some View {
        let listPath = Binding<[Route]>(
            get: { path.listRoutes },
            set: { routes in path = routes + (path.openSession.map { [.session($0)] } ?? []) })
        let open = path.openSession
        return NavigationSplitView {
            NavigationStack(path: listPath) { lists }
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
        } detail: {
            NavigationStack {
                if let open {
                    sessionPage(open)
                } else {
                    NothingOpenView()
                }
            }
            // A new session is a new page, Changes and all.
            .id(open?.id)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.openSessionInDetail) { session in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { path = path.opening(session) }
        }
        .environment(\.sessionInDetail, open?.id)
    }
}
