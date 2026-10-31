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
}

struct Status: Decodable, Hashable {
    /// idle, working, done, blocked or error: the program's own word.
    let state: String
    let app: String?
    let message: String?
    /// permission, question or auth, when blocked.
    let kind: String?
}

enum ServerMessage: Decodable {
    case hello(api: Int)
    case sessions(core: String?, connected: Bool, sessions: [Session])
    case unknown

    private enum CodingKeys: String, CodingKey { case type, api, core, connected, sessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(api: try c.decode(Int.self, forKey: .api))
        case "sessions":
            self = .sessions(
                core: try c.decodeIfPresent(String.self, forKey: .core),
                connected: try c.decode(Bool.self, forKey: .connected),
                sessions: try c.decode([Session].self, forKey: .sessions))
        default:
            self = .unknown
        }
    }
}
