import Foundation

/// A live core terminal as the Gateway presents it (Companion API v0).
struct Session: Decodable, Identifiable, Hashable {
    /// The core's address, opaque to the app.
    let id: String
    /// The machine it runs on; nil for the Gateway's own Mac.
    let machine: String?
    let title: String
    let program: String?
    let cwd: String
    let status: Status?
    /// The last completed Agent turn, or zero when none has been reported.
    let turn: UInt64
    /// When the status last changed, by the Mac's clock (ms since 1970).
    let statusMs: Int64?
    /// The terminal that started this one: it is a child Agent.
    let parent: String?
    /// Pinned to the top of the agent lists in Herdr.
    let pinned: Bool
    /// The turn Herdr's desktop last showed.
    let seen: UInt64?
    /// The git repository its folder is in.
    let repo: Repo?
    /// What a working Claude Code is on, from its to-do list.
    let todo: TodoNow?

    private enum CodingKeys: String, CodingKey {
        case id, machine, title, program, cwd, status, turn, statusMs = "status_ms", parent, pinned, seen, repo, todo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        title = try c.decode(String.self, forKey: .title)
        program = try c.decodeIfPresent(String.self, forKey: .program)
        cwd = try c.decode(String.self, forKey: .cwd)
        status = try c.decodeIfPresent(Status.self, forKey: .status)
        // A Gateway older than the Agent Message feature sends no turn.
        turn = try c.decodeIfPresent(UInt64.self, forKey: .turn) ?? 0
        statusMs = try c.decodeIfPresent(Int64.self, forKey: .statusMs)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        seen = try c.decodeIfPresent(UInt64.self, forKey: .seen)
        repo = try? c.decodeIfPresent(Repo.self, forKey: .repo)
        todo = try? c.decodeIfPresent(TodoNow.self, forKey: .todo)
    }

    /// The folder's own name, `~` and `/` as they are.
    var folder: String {
        let parts = cwd.split(separator: "/")
        return parts.last.map(String.init) ?? (cwd.isEmpty ? "" : "/")
    }

    /// An Agent reports a status; a plain terminal (zsh, a dev server) doesn't.
    var isAgent: Bool { status != nil }

    /// 「工作中 · 12s」 while the Agent works and the Gateway says since when.
    func working(at now: Date) -> String? {
        guard status?.state == "working", let statusMs else { return nil }
        return "工作中 · \(Elapsed.text(milliseconds: Int64(now.timeIntervalSince1970 * 1000) - statusMs))"
    }
}

struct Repo: Decodable, Hashable {
    /// The main checkout's folder name.
    let name: String
    /// The linked worktree's folder name, when in one.
    let worktree: String?
}

struct TodoNow: Decodable, Hashable {
    let text: String
    let done: Int
    let total: Int
}

struct Status: Decodable, Hashable {
    /// idle, working, done, blocked or error: the program's own word.
    let state: String
    let app: String?
    let message: String?
    /// permission, question or auth, when blocked.
    let kind: String?
}

/// A Herdr space holding live sessions, in Herdr's order.
struct Space: Decodable, Hashable, Identifiable {
    let id: String
    /// The machine it lives on; nil for the Gateway's own Mac.
    let machine: String?
    let name: String
    /// Where Herdr starts the space's terminals; older Gateways don't send it.
    let folder: String?
    let tabs: [SpaceTab]
}

struct SpaceTab: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    /// Session ids in pane order.
    let sessions: [String]
}

enum ServerMessage: Decodable {
    case hello(api: Int)
    case sessions(core: String?, connected: Bool, sessions: [Session], spaces: [Space])
    case sent(id: String, turn: UInt64, status: String?, started: Bool?)
    case sendFailed(id: String, kind: String, message: String)
    case keysSent(id: String)
    case keysFailed(id: String, kind: String, message: String)
    case runCreated(id: String, session: String)
    case runFailed(id: String, kind: String, message: String)
    case interrupted(id: String, outcome: String)
    case interruptFailed(id: String, kind: String, message: String)
    case putDone(id: String, path: String)
    case putFailed(id: String, kind: String, message: String)
    case commandList(id: String, commands: [SlashCommand])
    case commandsFailed(id: String, kind: String, message: String)
    case changes(id: String, list: ChangeList)
    case changesFailed(id: String, kind: String, message: String)
    case changeDiff(id: String, patch: String, truncated: Bool)
    case changeDiffFailed(id: String, kind: String, message: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, api, core, connected, sessions, spaces, id, turn, status, started, kind, message, session, outcome, path, commands, patch, truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(api: try c.decode(Int.self, forKey: .api))
        case "sessions":
            self = .sessions(
                core: try c.decodeIfPresent(String.self, forKey: .core),
                connected: try c.decode(Bool.self, forKey: .connected),
                sessions: try c.decode([Session].self, forKey: .sessions),
                // A Gateway older than space grouping sends none.
                spaces: try c.decodeIfPresent([Space].self, forKey: .spaces) ?? [])
        case "sent":
            self = .sent(
                id: try c.decode(String.self, forKey: .id),
                turn: try c.decode(UInt64.self, forKey: .turn),
                status: try c.decodeIfPresent(String.self, forKey: .status),
                started: try c.decodeIfPresent(Bool.self, forKey: .started))
        case "send_failed":
            self = .sendFailed(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                message: try c.decode(String.self, forKey: .message))
        case "keys_sent":
            self = .keysSent(id: try c.decode(String.self, forKey: .id))
        case "keys_failed":
            self = .keysFailed(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                message: try c.decode(String.self, forKey: .message))
        case "run_created":
            self = .runCreated(
                id: try c.decode(String.self, forKey: .id),
                session: try c.decode(String.self, forKey: .session))
        case "run_failed":
            self = .runFailed(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                message: try c.decode(String.self, forKey: .message))
        case "interrupted":
            self = .interrupted(
                id: try c.decode(String.self, forKey: .id),
                outcome: try c.decode(String.self, forKey: .outcome))
        case "interrupt_failed":
            self = .interruptFailed(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                message: try c.decode(String.self, forKey: .message))
        case "put_done":
            self = .putDone(id: try c.decode(String.self, forKey: .id), path: try c.decode(String.self, forKey: .path))
        case "put_failed":
            self = .putFailed(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                message: try c.decode(String.self, forKey: .message))
        case "command_list":
            self = .commandList(id: try c.decode(String.self, forKey: .id),
                                commands: try c.decode([SlashCommand].self, forKey: .commands))
        case "commands_failed":
            self = .commandsFailed(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                message: try c.decode(String.self, forKey: .message))
        case "changes":
            self = .changes(id: try c.decode(String.self, forKey: .id), list: try ChangeList(from: decoder))
        case "change_diff":
            self = .changeDiff(id: try c.decode(String.self, forKey: .id),
                               patch: try c.decode(String.self, forKey: .patch),
                               truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "changes_failed", "change_diff_failed":
            let id = try c.decode(String.self, forKey: .id)
            let kind = try c.decode(String.self, forKey: .kind)
            let message = try c.decode(String.self, forKey: .message)
            self = try c.decode(String.self, forKey: .type) == "changes_failed"
                ? .changesFailed(id: id, kind: kind, message: message)
                : .changeDiffFailed(id: id, kind: kind, message: message)
        default:
            self = .unknown
        }
    }
}
