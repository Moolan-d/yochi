import Foundation
import Observation

/// One conversation item as the Gateway sends it (`/v0/conversation`).
struct ConversationItem: Decodable, Identifiable, Equatable {
    enum Kind: String, Decodable {
        /// task: a subagent or background task reporting back; `summary`,
        /// `state` and its report in `text`.
        case user, agent, tool, command, notice, task, other
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

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, name, summary, state, output, questions, answers
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
    }
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

    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    /// The tool call a pending question is about, when the transcript shows it.
    var pendingTool: ConversationItem? {
        guard let id = pending?.tool else { return nil }
        return items.last { $0.id == id }
    }

    func start(_ config: GatewayConfig, session: String) {
        stop()
        guard let url = config.conversationURL(session: session) else {
            phase = .failed("地址无效：\(config.host)")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 32 << 20
        self.socket = socket
        if phase != .following { phase = .connecting }
        socket.resume()
        loop = Task { await follow(socket) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func follow(_ socket: URLSessionWebSocketTask) async {
        do {
            while true {
                guard case .string(let text) = try await socket.receive() else { continue }
                apply(try JSONDecoder().decode(ConversationMessage.self, from: Data(text.utf8)))
            }
        } catch {
            if Task.isCancelled { return }
            if case .closed = phase { return }
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            let reason = switch status {
            case 401: "配对已失效"
            case 404: "会话已不存在"
            default: error.localizedDescription
            }
            phase = .failed(reason)
        }
    }

    func apply(_ message: ConversationMessage) {
        switch message {
        case .conversation(let supported, let items):
            self.items = items.filter { $0.kind != .other }
            phase = supported ? .following : .unsupported
        case .items(let changed):
            for item in changed where item.kind != .other {
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                } else {
                    items.append(item)
                }
            }
        case .pending(let pending):
            self.pending = pending
        case .closed(let reason):
            pending = nil
            phase = .closed(reason: reason == "finished" ? "会话已结束" : reason)
        case .unknown:
            break
        }
    }
}

enum ConversationMessage: Decodable {
    case conversation(supported: Bool, items: [ConversationItem])
    case items([ConversationItem])
    case pending(PendingQuestion?)
    case closed(reason: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, supported, items, pending, reason
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
        case "closed":
            self = .closed(reason: (try? c.decode(String.self, forKey: .reason)) ?? "会话已结束")
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
