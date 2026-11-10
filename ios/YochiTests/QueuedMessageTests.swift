import Foundation
import Testing

@testable import Yochi

/// When a message queued on the phone goes out.
struct QueuedMessageTests {
    private let queued = QueuedMessage(text: "next", turn: 5)

    @Test("It waits while the turn runs and goes once it ends")
    func waitsForTheTurn() {
        #expect(queued.release(state: "working", turn: 5) == .wait)
        #expect(queued.release(state: "idle", turn: 6) == .send)
        #expect(queued.release(state: "done", turn: 6) == .send)
    }

    @Test("A turn that ends waiting on the user keeps it queued")
    func holdsWhileBlocked() {
        #expect(queued.release(state: "blocked", turn: 6) == .wait)
        #expect(queued.release(state: nil, turn: 6) == .wait)
    }

    @Test("Once more turns ended than the one it waited for, the user decides")
    func asksWhenStale() {
        #expect(queued.release(state: "idle", turn: 7) == .ask)
        #expect(queued.release(state: "working", turn: 7) == .ask)
    }

    @Test("A failed send waits for the user")
    func asksAfterFailure() {
        var failed = queued
        failed.failure = "会话已结束"
        #expect(failed.release(state: "idle", turn: 6) == .ask)
    }

    @Test("It is kept across launches, by host and session")
    func persists() {
        let key = AgentMessageStore.key(host: "test-\(UUID())", session: "s1")
        AgentMessageStore.saveQueued(queued, key: key)
        #expect(AgentMessageStore.allQueued()[key] == queued)
        AgentMessageStore.saveQueued(nil, key: key)
        #expect(AgentMessageStore.allQueued()[key] == nil)
    }

    @Test("Slash commands are told apart from text and paths")
    func recognizesCommands() {
        #expect(QueuedMessage.isCommand("/model"))
        #expect(QueuedMessage.isCommand("  /effort high\n"))
        #expect(QueuedMessage.isCommand("/plugin:skill-name args"))
        #expect(!QueuedMessage.isCommand("你只负责帮我记录即可"))
        #expect(!QueuedMessage.isCommand("/Users/ryan/a.txt 看看这个"))
        #expect(!QueuedMessage.isCommand("/tmp/notes.md"))
        #expect(!QueuedMessage.isCommand("/model\n然后继续"))
        #expect(!QueuedMessage.isCommand("/"))
        #expect(!QueuedMessage.isCommand("see /model"))
    }
}
