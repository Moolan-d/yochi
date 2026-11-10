import SwiftUI

/// The Spaces tab: per machine, one row for each space with a little map of
/// each of its tabs, and a last row for what is in no space.
struct SpacesList<Banner: View>: View {
    let board: [MachineSection]
    /// Offered when there is nothing to show; nil while it can't be used.
    let newSession: (() -> Void)?
    /// False while the screen says why it has nothing yet.
    var showsEmpty = true
    @ViewBuilder var banner: Banner

    /// An older Gateway sends no spaces: one row for each machine's terminals.
    private var flat: Bool { board.allSatisfy { $0.spaces.isEmpty } }

    var body: some View {
        let _ = Perf.count("SpacesList")
        List {
            banner
            if flat {
                Section {
                    ForEach(board) { section in
                        OthersRow(section: section, title: section.title, symbol: machineSymbol(section.machine))
                    }
                }
            } else {
                ForEach(board) { section in
                    Section {
                        ForEach(section.spaces) { space in
                            NavigationLink(value: Route.space(space.id)) {
                                SpaceRow(space: space)
                            }
                            .accessibilityIdentifier("space-\(space.id)")
                            .homeRow()
                        }
                        if !section.others.isEmpty {
                            OthersRow(section: section, title: String(localized: "Other Terminals"), symbol: "terminal")
                        }
                    } header: {
                        Label(section.title, systemImage: machineSymbol(section.machine))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .homeListStyle()
        .overlay {
            if board.isEmpty && showsEmpty {
                ContentUnavailableView {
                    Label("No Terminals Running", systemImage: "square.grid.2x2")
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

    private func machineSymbol(_ machine: String?) -> String { machine == nil ? "desktopcomputer" : "server.rack" }
}

/// A space: its tile, its name, a map of each tab, and what needs a look.
struct SpaceRow: View {
    let space: SpaceEntry

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            SpaceTile(letter: String(space.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased(),
                      spaceID: space.id)
            VStack(alignment: .leading, spacing: 6) {
                Text(space.name)
                    .font(.body)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                HStack(spacing: 6) {
                    ForEach(space.tabs.prefix(Self.mapsShown)) { tab in
                        MiniPaneMap(layout: tab.layout, marks: tab.marks)
                    }
                    if space.tabs.count > Self.mapsShown {
                        Text("+\(space.tabs.count - Self.mapsShown)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            SpaceStatusView(status: space.status)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([space.name, String(localized: "\(space.tabs.count) Tabs"), space.status?.word]
            .compactMap { $0 }.joined(separator: String(localized: "detail.separator", defaultValue: ", ")))
    }

    /// Maps that fit beside the chevron on a narrow phone.
    static let mapsShown = 5
}

/// The count of Agents waiting, else a turning arc, else a blue dot.
struct SpaceStatusView: View {
    let status: SpaceStatus?

    var body: some View {
        switch status {
        case .needsYou(let count): StatusPill(text: "\(count)")
        case .working: WorkingIndicator()
        case .unseen: UnseenDot()
        case nil: EmptyView()
        }
    }
}

extension SpaceStatus {
    /// For VoiceOver.
    var word: String {
        switch self {
        case .needsYou(let count): String(localized: "\(count) Agents need you")
        case .working: String(localized: "An Agent is working")
        case .unseen: String(localized: "Unseen results")
        }
    }
}

/// A machine's terminals in no space: its last row.
struct OthersRow: View {
    let section: MachineSection
    let title: String
    let symbol: String

    var body: some View {
        NavigationLink(value: Route.others(machine: section.machine)) {
            HStack(spacing: 12) {
                SymbolTile(symbol: symbol)
                Text(title)
                    .font(.body)
                Spacer(minLength: 0)
                Text("\(section.others.count)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, String(localized: "\(section.others.count) terminals")]
                .joined(separator: String(localized: "detail.separator", defaultValue: ", ")))
        }
        .accessibilityIdentifier("others-\(section.id)")
        .homeRow()
    }
}

/// A gray rounded square holding a symbol.
struct SymbolTile: View {
    let symbol: String

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(Color.spaceTile(nil))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - A space

/// A space's tabs, one section each: the tab's name, a map of its panes, and
/// every terminal in it in pane order.
struct SpaceDetailView: View {
    let entry: SpaceEntry?
    /// The machine's name, for the subtitle.
    let machine: String?
    let queued: (String) -> Bool

    var body: some View {
        List {
            if let entry {
                ForEach(entry.tabs) { tab in
                    Section {
                        ForEach(tab.rows) { row in
                            NavigationLink(value: Route.session(row.session)) {
                                SpaceTerminalRow(row: row, queued: queued(row.id))
                            }
                            .accessibilityIdentifier("session-\(row.id)")
                            .homeRow()
                        }
                    } header: {
                        HStack {
                            SectionTitle(verbatim: tab.title)
                            Spacer()
                            MiniPaneMap(layout: tab.layout, marks: tab.marks, size: CGSize(width: 52, height: 30))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .homeListStyle()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(entry?.name ?? "").font(.headline).lineLimit(1)
                    if let entry {
                        Text([machine, String(localized: "\(entry.tabs.count) Tabs")].compactMap { $0 }
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

/// A terminal in a space's tab: an Agent with its question or to-do and its
/// state, a shell with its folder.
struct SpaceTerminalRow: View {
    let row: HomeRow
    let queued: Bool

    @ScaledMetric(relativeTo: .headline) private var indent: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    private var session: Session { row.session }

    var body: some View {
        HStack(spacing: 12) {
            ProgramSquare(session: session)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(row.title)
                        .font(session.isAgent ? .headline : .body)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                if session.isAgent {
                    RowDetail(detail: row.detail, askSymbol: row.askSymbol)
                    if queued {
                        Label("Queued", systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                let place = session.isAgent ? row.withoutTab.placeLine(awayFromSpace: false) : row.folder
                if !place.isEmpty {
                    Text(place)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.middle)
                }
                if typeSize.isAccessibilitySize && session.isAgent {
                    RowStatus(row: row).padding(.top, 2)
                }
            }
            if session.isAgent && !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
                RowStatus(row: row)
            }
        }
        .padding(.leading, session.parent != nil ? indent : 0)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let separator = String(localized: "detail.separator", defaultValue: ", ")
        guard session.isAgent else {
            return [row.title, row.folder].filter { !$0.isEmpty }.joined(separator: separator)
        }
        return [row.withoutTab.accessibilityLabel(awayFromSpace: false), queued ? String(localized: "has a queued message") : nil]
            .compactMap { $0 }.joined(separator: separator)
    }
}

// MARK: - Terminals in no space

/// What one machine has in no space, as plain rows.
struct OtherTerminalsView: View {
    let title: String
    /// Without spaces at all the page is the whole machine, not "other" ones.
    let flat: Bool
    let rows: [HomeRow]
    let queued: (String) -> Bool

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    NavigationLink(value: Route.session(row.session)) {
                        if row.session.isAgent {
                            InboxRow(row: row, queued: queued(row.id))
                        } else {
                            TerminalSearchRow(row: row)
                        }
                    }
                    .accessibilityIdentifier("session-\(row.id)")
                    .homeRow()
                }
            }
        }
        .homeListStyle()
        .navigationTitle(flat ? title : String(localized: "Other Terminals"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
