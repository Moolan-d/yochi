import Foundation
import Observation

/// One conversation item as the Gateway sends it (`/v0/conversation`).
struct ConversationItem: Decodable, Identifiable, Equatable {
    enum Kind: String, Decodable {
        /// task: a subagent or background task reporting back; `summary`,
        /// `state` and its report in `text`.
        /// todos: the Agent's to-do list at that point, in `todos`.
        /// peer: a message to or from another Agent; `direction`, `name`, `text`.
        case user, agent, tool, command, notice, task, todos, peer, other
    }

    enum ToolState: String, Decodable {
        case running, done, error
    }

    let id: String
    let kind: Kind
    /// user, agent and notice text; agent and task text is Markdown.
    let text: String?
    /// Tool or command name.
    let name: String?
    let summary: String?
    let state: ToolState?
    let output: String?
    let questions: [AgentQuestion]?
    /// Question text → the chosen label, once answered.
    let answers: [String: String]?
    /// Edit, MultiEdit and Write, once done: what changed.
    let edit: EditInfo?
    /// Agent: the subtask it runs.
    let agent: Subtask?
    let todos: [TodoEntry]?
    let direction: PeerDirection?

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, name, summary, state, output, questions, answers, edit, agent, todos = "items", direction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // A newer Gateway may send kinds this app doesn't know; they are skipped.
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .other
        text = try c.decodeIfPresent(String.self, forKey: .text)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        state = try? c.decodeIfPresent(ToolState.self, forKey: .state)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        questions = try? c.decodeIfPresent([AgentQuestion].self, forKey: .questions)
        answers = try? c.decodeIfPresent([String: String].self, forKey: .answers)
        edit = try? c.decodeIfPresent(EditInfo.self, forKey: .edit)
        agent = try? c.decodeIfPresent(Subtask.self, forKey: .agent)
        todos = try? c.decodeIfPresent([TodoEntry].self, forKey: .todos)
        direction = try? c.decodeIfPresent(PeerDirection.self, forKey: .direction)
    }
}

/// What an Edit or Write changed, as hunks of a unified diff.
struct EditInfo: Decodable, Equatable {
    let path: String
    let added: Int
    let deleted: Int
    let patch: String
    /// Write made a new file; the patch is its text.
    let created: Bool
    /// The Gateway kept only the start of the diff.
    let truncated: Bool

    var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    var directory: String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// 「编辑 A.swift」 or 「新建 A.swift，12 行」.
    var title: String { created ? String(localized: "新建 \(name)，\(added) 行") : String(localized: "编辑 \(name)") }

    var accessibilityLabel: String {
        if created { return String(localized: "新建 \(name)，\(added) 行，在 \(directory)") }
        return String(localized: "编辑 \(name)，增加 \(added) 行，删除 \(deleted) 行，在 \(directory)")
    }

    private enum CodingKeys: String, CodingKey { case path, added, deleted, patch, created, truncated }

    init(path: String, added: Int, deleted: Int, patch: String, created: Bool = false, truncated: Bool = false) {
        self.path = path
        self.added = added
        self.deleted = deleted
        self.patch = patch
        self.created = created
        self.truncated = truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        deleted = try c.decodeIfPresent(Int.self, forKey: .deleted) ?? 0
        patch = try c.decodeIfPresent(String.self, forKey: .patch) ?? ""
        created = try c.decodeIfPresent(Bool.self, forKey: .created) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// A subtask the Agent started with its Agent tool.
struct Subtask: Decodable, Equatable {
    let name: String
    /// The subagent type, such as Explore.
    let type: String?
    /// By the Mac's clock, from the transcript.
    let startedMs: Int64?
    let durationMs: Int64?
    /// Runs on after the call returns; a later report ends it.
    let background: Bool

    private enum CodingKeys: String, CodingKey {
        case name, type, startedMs = "started_ms", durationMs = "duration_ms", background
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        startedMs = try c.decodeIfPresent(Int64.self, forKey: .startedMs)
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs)
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? false
    }

    /// 「运行中 12s」, 「后台 · 12s」, 「用时 2m 30s」; nil when there is nothing to time.
    func timing(state: ConversationItem.ToolState?, now: Date) -> String? {
        switch state {
        case .running, nil:
            guard let startedMs else { return background ? String(localized: "后台") : String(localized: "运行中") }
            let elapsed = Elapsed.text(milliseconds: Int64(now.timeIntervalSince1970 * 1000) - startedMs)
            return background ? String(localized: "后台 · \(elapsed)") : String(localized: "运行中 \(elapsed)")
        case .done:
            return durationMs.map { String(localized: "用时 \(Elapsed.text(milliseconds: $0))") }
        case .error:
            return String(localized: "失败")
        }
    }
}

/// Elapsed time as the app writes it: 12s, 2m 30s, 1h 5m. Negative (a
/// clock ahead of the Mac's) counts as zero.
enum Elapsed {
    static func text(milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1000)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    /// The same, for VoiceOver: 12 秒, 2 分 30 秒.
    static func spoken(milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1000)
        if seconds < 60 { return String(localized: "\(seconds) 秒") }
        if seconds < 3600 { return String(localized: "\(seconds / 60) 分 \(seconds % 60) 秒") }
        return String(localized: "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分")
    }
}

struct TodoEntry: Decodable, Equatable {
    enum Status: String, Decodable {
        case pending, inProgress = "in_progress", completed
    }

    let text: String
    /// What the Agent is doing while it is in progress.
    let active: String?
    let status: Status

    private enum CodingKeys: String, CodingKey { case text, active, status }

    init(text: String, active: String? = nil, status: Status) {
        self.text = text
        self.active = active
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        active = try c.decodeIfPresent(String.self, forKey: .active)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .pending
    }
}

/// The latest to-do list's progress, for the line above the composer:
/// 「正在：修复水印（3/7）」. Nil when nothing is in progress.
struct TodoProgress: Equatable {
    let doing: String
    let done: Int
    let total: Int

    init?(items: [ConversationItem]) {
        guard let list = items.last(where: { $0.kind == .todos })?.todos,
              let current = list.first(where: { $0.status == .inProgress }) else { return nil }
        doing = current.active.flatMap { $0.isEmpty ? nil : $0 } ?? current.text
        done = list.count { $0.status == .completed }
        total = list.count
    }

    /// What the Gateway read for the home page.
    init(_ todo: TodoNow) {
        doing = todo.text
        done = todo.done
        total = todo.total
    }

    /// An `activeForm` that already says 正在 isn't said twice.
    private var line: String { doing.hasPrefix("正在") ? doing : String(localized: "正在：\(doing)") }
    var text: String { String(localized: "\(line)（\(done)/\(total)）") }
    var accessibilityLabel: String { String(localized: "\(line)，已完成 \(done) 项，共 \(total) 项") }
}

enum PeerDirection: String, Decodable {
    case sent, received
}

/// One question of Claude Code's AskUserQuestion.
struct AgentQuestion: Decodable, Equatable {
    struct Option: Decodable, Equatable {
        let label: String
        let description: String?
    }

    let question: String
    let header: String?
    let multiSelect: Bool
    let options: [Option]

    private enum CodingKeys: String, CodingKey {
        case question, header, multiSelect = "multi_select", options
    }
}

/// What the Agent waits for: core's status plus the tool call it is about.
struct PendingQuestion: Decodable, Equatable {
    /// permission, question or auth.
    let kind: String
    /// core's summary; an answer quotes it back so a stale one is refused.
    let message: String?
    let tool: String?
}

/// Follows one session's conversation from its Agent Transcript. Items stay
/// in memory only (GLOSSARY: Conversation History is not cached on the device).
@MainActor @Observable
final class ConversationFeed {
    enum Phase: Equatable {
        case connecting
        case following
        /// The terminal's program has no readable transcript; terminal view only.
        case unsupported
        case closed(reason: String)
        case failed(String)
    }

    private(set) var phase: Phase = .connecting
    private(set) var items: [ConversationItem] = []
    private(set) var pending: PendingQuestion?
    /// The permission mode as of the Agent's latest message; nil when the
    /// transcript has none or names one the app doesn't know.
    private(set) var mode: PermissionMode?

    /// Agent replies that arrived while following, by item id. Claude Code
    /// writes a reply to its transcript only once it is whole, so the page
    /// reveals it from what was there before, as a stream would have.
    private(set) var arrivals: [String: Arrival] = [:]

    private var socket: GatewaySocket?
    private var loop: Task<Void, Never>?

    var todoProgress: TodoProgress? { TodoProgress(items: items) }

    /// Nothing streams now: never started, stopped, failed or closed. A
    /// page coming back starts it again, keeping the items it has.
    var needsStart: Bool {
        switch phase {
        case .failed, .closed: true
        case .connecting, .following, .unsupported: socket == nil
        }
    }

    /// The tool call a pending question is about, when the transcript shows it.
    var pendingTool: ConversationItem? {
        guard let id = pending?.tool else { return nil }
        return items.last { $0.id == id }
    }

    func start(_ config: GatewayConfig, session: String) {
        stop()
        guard let url = config.conversationURL(session: session) else {
            phase = .failed(String(localized: "地址无效：\(config.host)"))
            return
        }
        let socket = GatewaySocket(url: url, token: config.token, maximumMessageSize: 32 << 20)
        self.socket = socket
        if phase != .following { phase = .connecting }
        loop = Task { await follow(socket) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel()
        socket = nil
    }

    private func follow(_ socket: GatewaySocket) async {
        do {
            while true {
                guard case .string(let text) = try await socket.receive() else { continue }
                apply(try await Self.decode(text))
            }
        } catch {
            if Task.isCancelled { return }
            if case .closed = phase { return }
            let status = socket.status
            let reason = switch status {
            case 401: String(localized: "配对已失效")
            case 404: String(localized: "会话已不存在")
            default: error.localizedDescription
            }
            phase = .failed(reason)
        }
    }

    /// Off the main thread: a whole conversation can run to megabytes.
    nonisolated private static func decode(_ text: String) async throws -> ConversationMessage {
        let start = ContinuousClock.now
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(text.utf8))
        if case .conversation = message {
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            Perf.log.notice("decode conversation bytes=\(text.utf8.count, privacy: .public) ms=\(ms, format: .fixed(precision: 1), privacy: .public)")
        }
        return message
    }

    func apply(_ message: ConversationMessage) {
        switch message {
        case .conversation(let supported, let items):
            // Coming back to a kept conversation, the Gateway sends it whole
            // again; unchanged, the page has nothing to redraw.
            let fresh = items.filter { $0.kind != .other }
            if fresh != self.items {
                self.items = fresh
                if !arrivals.isEmpty { arrivals = [:] }
            }
            // The Gateway says the mode again after a fresh conversation.
            if mode != nil { mode = nil }
            let phase: Phase = supported ? .following : .unsupported
            if self.phase != phase { self.phase = phase }
        case .items(let changed):
            // One change for the whole batch, so the page redraws once.
            var updated = items
            var index = Dictionary(updated.indices.map { (updated[$0].id, $0) }, uniquingKeysWith: { _, last in last })
            var arrived: [String: Arrival] = [:]
            let now = Date.now
            for item in changed where item.kind != .other {
                if let at = index[item.id] {
                    let before = updated[at].text
                    if item.kind == .agent, item.text != before, let text = item.text, !text.isEmpty {
                        arrived[item.id] = Arrival(previous: before, at: now)
                    }
                    updated[at] = item
                } else {
                    index[item.id] = updated.count
                    updated.append(item)
                    if item.kind == .agent, let text = item.text, !text.isEmpty {
                        arrived[item.id] = Arrival(previous: nil, at: now)
                    }
                }
            }
            if !arrived.isEmpty { arrivals.merge(arrived) { _, new in new } }
            if updated != items { items = updated }
        case .pending(let pending):
            if self.pending != pending { self.pending = pending }
        case .mode(let mode):
            let mode = PermissionMode(rawValue: mode)
            if self.mode != mode { self.mode = mode }
        case .closed(let reason):
            pending = nil
            phase = .closed(reason: reason == "finished" ? String(localized: "会话已结束") : reason)
        case .unknown:
            break
        }
    }
}

/// An Agent reply that came in while the page followed the conversation.
struct Arrival: Equatable {
    /// The reply's text before, when this replaced it; nil for a new reply.
    let previous: String?
    let at: Date
}

enum ConversationMessage: Decodable {
    case conversation(supported: Bool, items: [ConversationItem])
    case items([ConversationItem])
    case pending(PendingQuestion?)
    case mode(String)
    case closed(reason: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, supported, items, pending, mode, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "conversation":
            self = .conversation(supported: try c.decode(Bool.self, forKey: .supported),
                                 items: try c.decode([ConversationItem].self, forKey: .items))
        case "items":
            self = .items(try c.decode([ConversationItem].self, forKey: .items))
        case "pending":
            self = .pending(try c.decodeIfPresent(PendingQuestion.self, forKey: .pending))
        case "mode":
            self = .mode(try c.decode(String.self, forKey: .mode))
        case "closed":
            self = .closed(reason: (try? c.decode(String.self, forKey: .reason)) ?? String(localized: "会话已结束"))
        default:
            self = .unknown
        }
    }
}

extension GatewayConfig {
    func conversationURL(session: String) -> URL? {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        components.path = "/v0/conversation"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        return components.url
    }
}
