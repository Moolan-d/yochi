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

    private enum CodingKeys: String, CodingKey {
        case id, machine, title, program, cwd, status, turn
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
    }
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
    case history(id: String, text: String, complete: Bool, why: String?)
    case historyFailed(id: String, kind: String, message: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, api, core, connected, sessions, spaces, id, turn, status, started, kind, message, session
        case text, complete, why
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
        case "history":
            self = .history(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                complete: try c.decode(Bool.self, forKey: .complete),
                why: try c.decodeIfPresent(String.self, forKey: .why))
        case "history_failed":
            self = .historyFailed(
                id: try c.decode(String.self, forKey: .id),
                kind: try c.decode(String.self, forKey: .kind),
                message: try c.decode(String.self, forKey: .message))
        default:
            self = .unknown
        }
    }
}
