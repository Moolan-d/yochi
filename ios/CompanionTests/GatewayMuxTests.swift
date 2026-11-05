@testable import Companion
import Foundation
import Synchronization
import XCTest

/// The Gateway's end of a mux, as a script: what it sends, what it got.
private final class FakeLink: GatewayLink {
    typealias Message = URLSessionWebSocketTask.Message

    let path: GatewayPath
    var status: Int? { nil }
    let sent = Mutex<[Data]>([])
    let cancelled = Mutex(false)
    private let incoming = Mutex<(queue: [Message], ended: (any Error)?, waiter: CheckedContinuation<Message, any Error>?)>(([], nil, nil))

    init(path: GatewayPath = .relay) {
        self.path = path
    }

    /// The Gateway's side: a message for the app, or the connection ending.
    func deliver(_ message: Message) {
        let waiter = incoming.withLock { state -> CheckedContinuation<Message, any Error>? in
            guard let waiter = state.waiter else {
                state.queue.append(message)
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: message)
    }

    func end(_ error: any Error) {
        let waiter = incoming.withLock { state -> CheckedContinuation<Message, any Error>? in
            guard state.ended == nil else { return nil }
            state.ended = error
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: error)
    }

    func say(_ id: UInt32, _ kind: GatewayMux.Kind, _ payload: Data = Data()) {
        deliver(.data(GatewayMux.frame(id, kind, payload)))
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if case .data(let data) = message { sent.withLock { $0.append(data) } }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let ready = incoming.withLock { state -> Result<Message, any Error>? in
                if !state.queue.isEmpty { return .success(state.queue.removeFirst()) }
                if let ended = state.ended { return .failure(ended) }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func ping() async -> Bool { true }

    func cancel() {
        cancelled.withLock { $0 = true }
        end(URLError(.cancelled))
    }

    /// Frames sent so far, decoded.
    var frames: [(id: UInt32, kind: GatewayMux.Kind, payload: Data)] {
        sent.withLock { $0 }.compactMap(GatewayMux.parse)
    }
}

private let hello = Data(#"{"type":"mux","v":1}"#.utf8)
private let endpoint = URL(string: "ws://100.1.2.3:7420/v0/observe?session=a&resumable=1")!

private func text(_ message: URLSessionWebSocketTask.Message) -> String? {
    if case .string(let text) = message { text } else { nil }
}

private func bytes(_ message: URLSessionWebSocketTask.Message) -> [UInt8]? {
    if case .data(let data) = message { [UInt8](data) } else { nil }
}

/// Waits for a condition that a background task makes true.
private func eventually(_ condition: () -> Bool) async {
    for _ in 0 ..< 200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

final class GatewayMuxTests: XCTestCase {
    private func started(_ link: FakeLink) async -> GatewayMux {
        let mux = GatewayMux(link: link, key: GatewayMux.Key(endpoint, token: "t0k")!)
        link.say(0, .text, hello)
        let ok = await mux.start()
        XCTAssertTrue(ok)
        return mux
    }

    func testFramesAreIdKindPayload() {
        let frame = GatewayMux.frame(7, .binary, Data([1, 2, 3]))
        XCTAssertEqual([UInt8](frame), [7, 0, 0, 0, 2, 1, 2, 3])
        let parsed = GatewayMux.parse(GatewayMux.frame(0x0102_0304, .close, Data([0x34, 0x11])))
        XCTAssertEqual(parsed?.id, 0x0102_0304)
        XCTAssertEqual(parsed?.kind, .close)
        XCTAssertEqual(parsed?.payload[0], 0x34, "the payload starts at 0")
        XCTAssertNil(GatewayMux.parse(Data([1, 0, 0, 0])))
        XCTAssertNil(GatewayMux.parse(Data([1, 0, 0, 0, 9])))
    }

    func testPagesShareOneConnectionAndKeepToThemselves() async throws {
        let link = FakeLink()
        let mux = await started(link)
        let opened = await mux.stream(to: endpoint)
        let terminal = try XCTUnwrap(opened)
        let other = await mux.stream(to: URL(string: "ws://100.1.2.3:7420/v0/screen?session=b")!)
        let screen = try XCTUnwrap(other)
        XCTAssertEqual(link.frames.map(\.kind), [.open, .open])
        XCTAssertEqual(link.frames.map(\.id), [terminal.id, screen.id])
        XCTAssertEqual(String(decoding: link.frames[0].payload, as: UTF8.self), "/v0/observe?session=a&resumable=1")
        XCTAssertEqual(terminal.path, .relay)

        link.say(screen.id, .text, Data("two".utf8))
        link.say(terminal.id, .binary, Data([5]))
        let first = try await terminal.receive()
        XCTAssertEqual(bytes(first), [5])
        let second = try await screen.receive()
        XCTAssertEqual(text(second), "two")
        try await terminal.send(.string(#"{"type":"detach"}"#))
        XCTAssertEqual(link.frames.last?.id, terminal.id)
        XCTAssertEqual(link.frames.last?.kind, .text)

        // The Gateway turns one away (4404): that page sees a refusal, the other goes on.
        link.say(terminal.id, .close, Data([0x34, 0x11]) + Data("Refused".utf8))
        do {
            _ = try await terminal.receive()
            XCTFail("the stream ended")
        } catch {}
        XCTAssertEqual(terminal.status, 404)
        link.say(screen.id, .text, Data("still".utf8))
        let still = try await screen.receive()
        XCTAssertEqual(text(still), "still")
        XCTAssertNil(screen.status)

        // Done with a page: the Gateway hears it closed, normally.
        screen.cancel()
        await eventually { link.frames.last?.kind == .close }
        XCTAssertEqual(link.frames.last?.id, screen.id)
        XCTAssertEqual([UInt8](link.frames.last?.payload ?? Data()), [0xE8, 0x03])
        XCTAssertTrue(mux.open)
        XCTAssertFalse(link.cancelled.withLock { $0 })
    }

    func testALostConnectionEndsEveryStream() async throws {
        let link = FakeLink()
        let mux = await started(link)
        let opened = await mux.stream(to: endpoint)
        let terminal = try XCTUnwrap(opened)
        link.end(URLError(.networkConnectionLost))
        do {
            _ = try await terminal.receive()
            XCTFail("the stream ended")
        } catch {}
        XCTAssertNil(terminal.status, "dropped, not refused: the terminal resumes")
        XCTAssertFalse(mux.open)
        let late = await mux.stream(to: endpoint)
        XCTAssertNil(late)
    }

    func testAnOlderGatewayIsNoMux() async {
        let link = FakeLink()
        let mux = GatewayMux(link: link, key: GatewayMux.Key(endpoint, token: "t0k")!)
        link.end(URLError(.badServerResponse))
        let ok = await mux.start()
        XCTAssertFalse(ok)
        XCTAssertTrue(link.cancelled.withLock { $0 })
        XCTAssertFalse(mux.open)
    }

    func testARetiredMuxClosesWhenItsLastStreamEnds() async throws {
        let link = FakeLink()
        let mux = await started(link)
        let opened = await mux.stream(to: endpoint)
        let terminal = try XCTUnwrap(opened)
        mux.retire()
        XCTAssertFalse(mux.open)
        let late = await mux.stream(to: endpoint)
        XCTAssertNil(late, "no new streams once replaced")
        XCTAssertFalse(link.cancelled.withLock { $0 }, "the open one goes on")
        terminal.cancel()
        await eventually { link.cancelled.withLock { $0 } }
        XCTAssertTrue(link.cancelled.withLock { $0 })
    }

    func testPagesUseTheAppsMuxOnlyForItsGatewayAndPath() async throws {
        let link = FakeLink(path: .tailnet)
        let mux = await started(link)
        GatewayMux.shared = mux
        defer { GatewayMux.shared = nil }
        let relayed = await GatewayMux.stream(to: endpoint, token: "t0k", on: .relay)
        XCTAssertNil(relayed, "not the path this page tries first")
        let stranger = await GatewayMux.stream(to: endpoint, token: "other", on: .tailnet)
        XCTAssertNil(stranger, "not this device")
        let elsewhere = await GatewayMux.stream(to: URL(string: "ws://100.9.9.9:7420/v0/screen")!, token: "t0k", on: .tailnet)
        XCTAssertNil(elsewhere, "not this Gateway")
        let stream = await GatewayMux.stream(to: endpoint, token: "t0k", on: .tailnet)
        XCTAssertNotNil(stream)

        GatewayMux.retireAll()
        XCTAssertNil(GatewayMux.shared)
        let after = await GatewayMux.stream(to: endpoint, token: "t0k", on: .tailnet)
        XCTAssertNil(after, "pages connect by themselves until the main connection is back")
    }
}
