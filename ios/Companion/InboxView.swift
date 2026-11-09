import SwiftUI

/// The Inbox: Agents across all spaces and machines by state, or, while
/// searching, every Agent and terminal that matches.
struct InboxList<Banner: View>: View {
    let inbox: Inbox
    /// A message waits on this iPhone for the session's turn to end.
    let queued: (String) -> Bool
    /// Offered when the Inbox or a search is empty; nil while it can't be used.
    let newSession: (() -> Void)?
    /// False while the screen says why it has nothing yet (connecting and
    /// the like), so the two never draw over each other.
    var showsEmpty = true
    @ViewBuilder var banner: Banner

    /// The search field's text, as typed.
    @State private var searchText = ""
    /// What the list is filtered by: the field's text once typing pauses
    /// for `searchDelay`, so each key press only edits the field.
    @State private var query = ""

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    static var searchDelay: Duration { .milliseconds(300) }

    var body: some View {
        let _ = Perf.count("InboxList")
        let found = searching ? inbox.search(query) : nil
        List {
            banner
            if let found {
                if !found.agents.isEmpty {
                    Section {
                        ForEach(found.agents) { row in
                            agentLink(row)
                        }
                    } header: {
                        SectionTitle("Agents")
                    }
                }
                if !found.terminals.isEmpty {
                    Section {
                        ForEach(found.terminals) { row in
                            terminalLink(row)
                        }
                    } header: {
                        SectionTitle("Terminals")
                    }
                }
            } else {
                ForEach(inbox.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            agentLink(row)
                        }
                    } header: {
                        SectionTitle(verbatim: section.kind.title)
                    }
                }
            }
        }
        .homeListStyle()
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Jump to an Agent or terminal")
        .task(id: searchText) {
            let text = searchText
            // Clearing the field shows the whole list again at once.
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                try? await Task.sleep(for: Self.searchDelay)
                guard !Task.isCancelled else { return }
            }
            if query != text { query = text }
        }
        .overlay {
            if let found, found.agents.isEmpty && found.terminals.isEmpty {
                ContentUnavailableView {
                    Label("No Agents Match “\(query)”", systemImage: "magnifyingglass")
                } description: {
                    Text("Try another word, or start a new one.")
                } actions: {
                    if let newSession {
                        Button("New", action: newSession)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if inbox.isEmpty && !searching && showsEmpty {
                ContentUnavailableView {
                    Label("No Agents Running", systemImage: "tray")
                } description: {
                    Text("Start one here, or start an Agent in Herdr.")
                } actions: {
                    if let newSession {
                        Button("New", action: newSession)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func agentLink(_ row: HomeRow) -> some View {
        NavigationLink(value: Route.session(row.session)) {
            InboxRow(row: row, queued: queued(row.id))
        }
        .accessibilityIdentifier("session-\(row.id)")
        .homeRow()
    }

    private func terminalLink(_ row: HomeRow) -> some View {
        NavigationLink(value: Route.session(row.session)) {
            TerminalSearchRow(row: row)
        }
        .accessibilityIdentifier("session-\(row.id)")
        .homeRow()
    }
}

/// A section's name above its card: plain sentence case, not shouting.
struct SectionTitle: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }

    /// A name that is data, such as a tab's, not a string to translate.
    init(verbatim: String) { text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Cards on the warm gray page.
    func homeListStyle() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.homePage)
    }

    /// A row's card color and the hairline under it.
    func homeRow() -> some View {
        listRowBackground(Color.homeCard).listRowSeparatorTint(Color.homeSeparator)
    }
}

/// A form in the home's colors, so Settings, pairing and the rest match the
/// pages they open from.
struct HomeForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            // A Group hands the row colors to each section it holds.
            Group { content }.homeRow()
        }
        .scrollContentBackground(.hidden)
        .background(Color.homePage)
    }
}

/// An Agent: its space's tile with the program's badge, its title, what it
/// asks or does, where it is, and its state at the trailing edge.
struct InboxRow: View {
    let row: HomeRow
    let queued: Bool

    /// Large text wraps instead of cutting the title and the place short, and
    /// the state moves under them.
    @Environment(\.dynamicTypeSize) private var typeSize

    private var session: Session { row.session }

    var body: some View {
        HStack(spacing: 12) {
            SpaceTile(letter: row.tileLetter, spaceID: row.spaceID, badge: ProgramGlyph(session))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(row.title)
                        .font(.headline)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                RowDetail(detail: row.detail)
                if queued {
                    Label("Queued", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                let place = row.placeLine(awayFromSpace: true)
                if !place.isEmpty {
                    Text(place)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.middle)
                }
                if typeSize.isAccessibilitySize {
                    RowStatus(row: row).padding(.top, 2)
                }
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
                RowStatus(row: row)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.accessibilityLabel(awayFromSpace: true), queued ? String(localized: "has a queued message") : nil]
            .compactMap { $0 }.joined(separator: String(localized: "detail.separator", defaultValue: ", ")))
    }
}

/// The second line: the question in dark orange, the to-do in gray.
struct RowDetail: View {
    let detail: HomeRow.Detail?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch detail {
        case .question(let text):
            Text(text).font(.subheadline).foregroundStyle(Color.warnText).lineLimit(lines)
        case .failure(let text):
            Text(text).font(.subheadline).foregroundStyle(Color.errorText).lineLimit(lines)
        case .progress(let text):
            Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
        case nil:
            EmptyView()
        }
    }

    private var lines: Int { typeSize.isAccessibilitySize ? 4 : 2 }
}

/// A shell or dev server found by search: its space's tile with a terminal
/// badge, its title, and the program and place.
struct TerminalSearchRow: View {
    let row: HomeRow

    var body: some View {
        HStack(spacing: 12) {
            SpaceTile(letter: row.tileLetter, spaceID: row.spaceID, badge: .terminal)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(row.terminalLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.title, row.terminalLine].filter { !$0.isEmpty }
            .joined(separator: String(localized: "detail.separator", defaultValue: ", ")))
    }
}
