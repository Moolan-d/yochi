import SwiftUI

struct SessionListView: View {
    let client: GatewayClient
    let seen: SeenTurns
    var retry: () -> Void
    var reenter: () -> Void
    var newSession: () -> Void

    var body: some View {
        let _ = Perf.count("SessionListView")
        HomeList(
            home: makeHome(sessions: client.sessions, spaces: client.spaces, seen: seen.turns),
            queued: { client.queuedMessage(session: $0) != nil },
            newSession: client.phase == .connected ? newSession : nil
        ) {
            // Sessions shown while disconnected are stale; say so above them.
            if client.phase != .connected && !client.sessions.isEmpty {
                Section {
                    Label(client.statusText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .overlay {
            if client.sessions.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch client.phase {
        case .disconnected, .connecting:
            ProgressView("正在连接…")
        case .failed(let reason):
            ContentUnavailableView {
                Label("无法连接 Gateway", systemImage: "wifi.exclamationmark")
            } description: {
                Text(reason)
            } actions: {
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        case .unauthorized:
            ContentUnavailableView {
                Label("配对已失效", systemImage: "key.slash")
            } description: {
                Text("Gateway 不再接受此 iPhone，可能已在主 Mac 上移除了它的配对。")
            } actions: {
                Button("重新配对", action: reenter)
                    .buttonStyle(.borderedProminent)
            }
        case .connected where !client.coreConnected:
            ContentUnavailableView(
                "无法访问 herdr-core",
                systemImage: "bolt.horizontal.circle",
                description: Text("Gateway 已连接，但主 Mac 上的 herdr-core 没有响应。"))
        case .connected:
            ContentUnavailableView {
                Label("没有运行中的 Agent", systemImage: "terminal")
            } description: {
                Text("新建一个，或在 Herdr 中让 Agent 开始运行。")
            } actions: {
                Button("新建", action: newSession)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

extension GatewayClient {
    var statusText: String {
        switch phase {
        case .disconnected: "未连接"
        case .connecting: "正在连接…"
        case .connected: coreConnected ? "已连接" : "herdr-core 不可用"
        case .failed(let reason): "连接失败：\(reason)"
        case .unauthorized: "配对已失效"
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

/// The home page's list: 需要你, then each space with its Agents and its
/// terminals folded, or a flat list of matches while searching.
struct HomeList<Banner: View>: View {
    let home: Home
    /// A message waits on this iPhone for the session's turn to end.
    let queued: (String) -> Bool
    /// Offered when nothing matches a search; nil while it can't be used.
    let newSession: (() -> Void)?
    @ViewBuilder var banner: Banner

    @State private var query = ""
    /// Spaces the user folded, by id, kept on this iPhone.
    @AppStorage("collapsedSpaces") private var collapsedIDs = ""
    /// Groups whose terminals are shown; folded again on the next launch.
    @State private var openTerminals: Set<String> = []

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var matches: [HomeRow] {
        home.groups.flatMap { $0.agents + $0.terminals }.filter { $0.matches(query) }
    }

    var body: some View {
        let _ = Perf.count("HomeList")
        List {
            banner
            if searching {
                Section {
                    ForEach(matches) { row in
                        link(row, awayFromSpace: true)
                    }
                }
            } else {
                if !home.needsYou.isEmpty {
                    Section {
                        ForEach(home.needsYou) { row in
                            link(row, awayFromSpace: true)
                        }
                    } header: {
                        Label("需要你", systemImage: "hand.raised.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                            .textCase(nil)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                ForEach(home.groups) { group in
                    section(group)
                }
            }
        }
        .searchable(text: $query, prompt: "搜索 Agent、仓库、Space")
        .overlay {
            if searching && matches.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配「\(query)」的 Agent", systemImage: "magnifyingglass")
                } description: {
                    Text("换个词试试，或新建一个。")
                } actions: {
                    if let newSession {
                        Button("新建", action: newSession)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ group: HomeGroup) -> some View {
        let collapsed = isCollapsed(group)
        Section {
            if !collapsed {
                ForEach(group.agents) { row in
                    link(row, awayFromSpace: false)
                }
                if !group.terminals.isEmpty {
                    terminalsToggle(group)
                    if openTerminals.contains(group.id) {
                        ForEach(group.terminals) { row in
                            link(row, awayFromSpace: false)
                        }
                    }
                }
            }
        } header: {
            GroupHeader(group: group, collapsed: collapsed) { toggleCollapsed(group) }
        }
    }

    private func link(_ row: HomeRow, awayFromSpace: Bool) -> some View {
        NavigationLink(value: row.session) {
            if row.session.isAgent {
                AgentRow(row: row, awayFromSpace: awayFromSpace, queued: queued(row.id))
            } else {
                TerminalRow(row: row, awayFromSpace: awayFromSpace)
            }
        }
        .accessibilityIdentifier("session-\(row.id)")
    }

    private func terminalsToggle(_ group: HomeGroup) -> some View {
        let open = openTerminals.contains(group.id)
        return Button {
            withAnimation {
                if open { openTerminals.remove(group.id) } else { openTerminals.insert(group.id) }
            }
        } label: {
            HStack {
                Label(group.agents.isEmpty ? "\(group.terminals.count) 个终端" : "另有 \(group.terminals.count) 个终端",
                      systemImage: "terminal")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityValue(open ? "已展开" : "已收起")
        .accessibilityIdentifier("terminalsToggle")
    }

    private var collapsed: Set<String> {
        Set(collapsedIDs.split(separator: "\n").map(String.init))
    }

    private func isCollapsed(_ group: HomeGroup) -> Bool { collapsed.contains(group.id) }

    private func toggleCollapsed(_ group: HomeGroup) {
        var ids = collapsed
        if ids.contains(group.id) { ids.remove(group.id) } else { ids.insert(group.id) }
        withAnimation { collapsedIDs = ids.sorted().joined(separator: "\n") }
    }
}

/// A space's name, its machine when remote, and the chevron that folds it;
/// folded, it says how many Agents it holds and the most pressing state.
private struct GroupHeader: View {
    let group: HomeGroup
    let collapsed: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let machine = group.machine {
                    Label(machine, systemImage: "server.rack")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if collapsed {
                    if let summary = group.summary {
                        Image(systemName: summary.symbol)
                            .foregroundStyle(summary.color)
                            .accessibilityHidden(true)
                    }
                    Text("\(group.agents.count) 个 Agent")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([group.title, group.machine].compactMap { $0 }.joined(separator: "，"))
        .accessibilityValue(collapsed
            ? (["已收起", "\(group.agents.count) 个 Agent", group.summary?.word].compactMap { $0 }.joined(separator: "，"))
            : "已展开")
        .accessibilityHint(collapsed ? "展开这个 Space" : "收起这个 Space")
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityIdentifier("groupHeader")
    }
}

extension HomeSummary {
    var symbol: String {
        switch self {
        case .blocked: "hand.raised.fill"
        case .working: "circle.dotted"
        case .unseen: "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .blocked: .orange
        case .working, .unseen: .blue
        }
    }
}

private struct AgentRow: View {
    let row: HomeRow
    /// In 需要你 and search results, away from its space: the third line
    /// starts with the machine and the space, and children aren't indented.
    let awayFromSpace: Bool
    let queued: Bool

    @ScaledMetric(relativeTo: .headline) private var indent: CGFloat = 22
    /// Large text wraps instead of cutting the title and the place short.
    @Environment(\.dynamicTypeSize) private var typeSize

    private var session: Session { row.session }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentMark(session: session, unseen: row.unseen)
            VStack(alignment: .leading, spacing: 3) {
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
                activity
                if queued {
                    Label("排队中", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                let place = row.place(awayFromSpace: awayFromSpace)
                if !place.isEmpty {
                    Text(place)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.leading, session.parent != nil && !awayFromSpace ? indent : 0)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.accessibilityLabel(awayFromSpace: awayFromSpace), queued ? "有排队中的消息" : nil].compactMap { $0 }.joined(separator: "，"))
    }

    @ViewBuilder
    private var activity: some View {
        let style: AnyShapeStyle = switch session.status?.state {
        case "blocked": AnyShapeStyle(.orange)
        case "error": AnyShapeStyle(.red)
        default: AnyShapeStyle(.secondary)
        }
        if session.status?.state == "working" || session.status?.state == "done" {
            // The time since moves on its own.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let text = row.activity(at: context.date) {
                    Text(text)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(style)
                        .lineLimit(1)
                }
            }
        } else if let text = row.activity(at: .now) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(style)
                .lineLimit(2)
        }
    }
}

/// The program's mark in a circle, ringed by its state: orange waiting on
/// the user, a turning blue arc working, blue finished and not seen, red on
/// error. The row's words carry the state too, so color is never alone.
private struct AgentMark: View {
    let session: Session
    let unseen: Bool

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            glyph
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.primary)
            ring
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch session.program?.lowercased() {
        case "claude": Image(systemName: "asterisk")
        case "pi": Text(verbatim: "π")
        default: Image(systemName: "cpu")
        }
    }

    @ViewBuilder
    private var ring: some View {
        let width = max(2, size / 14)
        switch session.status?.state {
        case "blocked":
            Circle().strokeBorder(.orange, lineWidth: width)
        case "error":
            Circle().strokeBorder(.red, lineWidth: width)
        case "working":
            let arc = Circle().inset(by: width / 2).trim(from: 0, to: 0.3)
                .stroke(.blue, style: StrokeStyle(lineWidth: width, lineCap: .round))
            if reduceMotion {
                arc.rotationEffect(.degrees(-90))
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                    arc.rotationEffect(.degrees(turn * 360))
                }
            }
        case "done" where unseen:
            Circle().strokeBorder(.blue, lineWidth: width)
        default:
            EmptyView()
        }
    }
}

/// A shell or dev server: its name, then the program and where it runs.
private struct TerminalRow: View {
    let row: HomeRow
    let awayFromSpace: Bool

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.42))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                Text([row.session.program, row.place(awayFromSpace: awayFromSpace)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
