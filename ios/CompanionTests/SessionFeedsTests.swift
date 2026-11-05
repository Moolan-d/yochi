import Observation
import XCTest
@testable import Companion

/// The session pages' cache: a page coming back soon finds its streams, an
/// unused one goes after its time, and memory pressure empties it.
@MainActor
final class SessionFeedsTests: XCTestCase {
    private final class Entry {
        let name: String
        init(_ name: String) { self.name = name }
    }

    private var clock = ContinuousClock.now
    private var discarded: [String] = []

    private func cache(ttl: Duration = .seconds(60), limit: Int = 4) -> FeedCache<Entry> {
        FeedCache(ttl: ttl, limit: limit, now: { [unowned self] in clock }) { [unowned self] in
            discarded.append($0.name)
        }
    }

    // MARK: Hit

    func testComingBackWithinTheTimeFindsTheSameEntry() {
        let cache = cache()
        let first = Entry("a")
        XCTAssertFalse(cache.acquire("a", first), "a new entry is no hit")
        cache.release("a", first)
        clock += .seconds(59)
        cache.sweep()

        let kept = try? XCTUnwrap(cache.cached("a"))
        XCTAssertTrue(kept === first)
        XCTAssertTrue(cache.acquire("a", first), "the kept entry is a hit")
        XCTAssertTrue(discarded.isEmpty)
    }

    func testAnEntryInUseNeverExpires() {
        let cache = cache()
        let entry = Entry("a")
        cache.acquire("a", entry)
        clock += .seconds(600)
        cache.sweep()
        XCTAssertTrue(cache.cached("a") === entry)
    }

    // MARK: Expiry

    func testAnUnusedEntryGoesAfterItsTime() {
        let cache = cache()
        let entry = Entry("a")
        cache.acquire("a", entry)
        cache.release("a", entry)
        clock += .seconds(60)
        cache.sweep()
        XCTAssertNil(cache.cached("a"))
        XCTAssertEqual(discarded, ["a"], "its streams stop")
    }

    func testTheTimeStartsWhenTheLastPageLeaves() {
        let cache = cache()
        let entry = Entry("a")
        // The same session open twice, one page above the other.
        cache.acquire("a", entry)
        cache.acquire("a", entry)
        cache.release("a", entry)
        clock += .seconds(90)
        cache.sweep()
        XCTAssertTrue(cache.cached("a") === entry, "still shown by the other page")
        cache.release("a", entry)
        clock += .seconds(30)
        cache.sweep()
        XCTAssertNotNil(cache.cached("a"))
        clock += .seconds(30)
        cache.sweep()
        XCTAssertNil(cache.cached("a"))
    }

    func testPastTheLimitTheLongestUnusedGoFirst() {
        let cache = cache(limit: 2)
        for name in ["a", "b", "c"] {
            let entry = Entry(name)
            cache.acquire(name, entry)
            cache.release(name, entry)
            clock += .seconds(1)
        }
        XCTAssertEqual(discarded, ["a"])
        XCTAssertNil(cache.cached("a"))
        XCTAssertNotNil(cache.cached("b"))
        XCTAssertNotNil(cache.cached("c"))
    }

    func testMemoryPressureDropsEverythingUnused() {
        let cache = cache()
        let shown = Entry("shown"), left = Entry("left")
        cache.acquire("shown", shown)
        cache.acquire("left", left)
        cache.release("left", left)
        cache.dropUnused()
        XCTAssertEqual(discarded, ["left"])
        XCTAssertTrue(cache.cached("shown") === shown, "the page on screen keeps its streams")
    }

    // MARK: A page's own entry

    func testAPageThatOutlivedItsEntryBringsItBack() {
        let cache = cache()
        let page = Entry("old")
        cache.acquire("a", page)
        cache.release("a", page)
        clock += .seconds(61)
        cache.sweep()
        // The page under another one comes back after its entry went.
        XCTAssertFalse(cache.acquire("a", page))
        XCTAssertTrue(cache.cached("a") === page)
    }

    func testAnEntryShownElsewhereIsNotReplaced() {
        let cache = cache()
        let shown = Entry("shown"), own = Entry("own")
        cache.acquire("a", shown)
        XCTAssertFalse(cache.acquire("a", own))
        XCTAssertTrue(cache.cached("a") === shown)
        // The page's own entry, never kept, stops as the page leaves.
        cache.release("a", own)
        XCTAssertEqual(discarded, ["own"])
        XCTAssertTrue(cache.cached("a") === shown)
    }

    func testTheStoreKeysByGatewayAndSession() {
        let store = SessionFeedStore()
        let feeds = store.feeds(host: "mac", session: "t1")
        store.cache.acquire(SessionFeedStore.key(host: "mac", session: "t1"), feeds)
        XCTAssertTrue(store.feeds(host: "mac", session: "t1") === feeds)
        XCTAssertFalse(store.feeds(host: "other", session: "t1") === feeds)
        XCTAssertFalse(store.feeds(host: "mac", session: "t2") === feeds)
        store.cache.removeAll()
    }

    // MARK: Carrying on

    private func decode(_ json: String) throws -> ConversationMessage {
        try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
    }

    private let conversation = #"""
    {"type":"conversation","supported":true,"items":[
      {"kind":"user","id":"u1","text":"run it"},
      {"kind":"tool","id":"toolu_1","name":"Bash","summary":"ls","state":"running"}
    ]}
    """#

    /// Counts change notifications; they arrive on the mutating thread.
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    /// Whether reading `read` would be told of a change made by `change`.
    private func notifies(_ read: () -> Void, _ change: () -> Void) -> Bool {
        let fired = Counter()
        withObservationTracking(read) { fired.value += 1 }
        change()
        return fired.value > 0
    }

    func testAKeptConversationShowsWhileItReconnects() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(conversation))
        feed.stop()
        XCTAssertTrue(feed.needsStart)
        // A port nothing listens on: the connection fails later, if at all.
        feed.start(GatewayConfig(host: "127.0.0.1:9", token: "t"), session: "t1")
        XCTAssertFalse(feed.needsStart)
        XCTAssertEqual(feed.phase, .following, "no loading state over the kept items")
        XCTAssertEqual(feed.items.map(\.id), ["u1", "toolu_1"])
        feed.stop()
    }

    func testTheSameConversationAgainChangesNothing() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(conversation))
        let message = try decode(conversation)
        XCTAssertFalse(notifies({ _ = feed.items; _ = feed.phase; _ = feed.mode }, { feed.apply(message) }),
                       "an unchanged conversation redraws the page")
    }

    func testANewConnectionReplacesTheKeptConversationInPlace() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(conversation))
        // While the page was away the tool finished and the Agent answered.
        feed.apply(try decode(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"user","id":"u1","text":"run it"},
          {"kind":"tool","id":"toolu_1","name":"Bash","summary":"ls","state":"done"},
          {"kind":"agent","id":"a1","text":"Done."}
        ]}
        """#))
        XCTAssertEqual(feed.items.map(\.id), ["u1", "toolu_1", "a1"])
        XCTAssertEqual(feed.items[1].state, .done)
        XCTAssertEqual(feed.phase, .following)
    }

    func testChangedItemsArriveAsOneChange() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(conversation))
        let changes = Counter()
        func track() {
            withObservationTracking({ _ = feed.items }) { changes.value += 1 }
        }
        track()
        feed.apply(try decode(#"""
        {"type":"items","items":[
          {"kind":"tool","id":"toolu_1","name":"Bash","summary":"ls","state":"done"},
          {"kind":"agent","id":"a1","text":"Done."},
          {"kind":"agent","id":"a2","text":"More."}
        ]}
        """#))
        XCTAssertEqual(changes.value, 1)
        XCTAssertEqual(feed.items.map(\.id), ["u1", "toolu_1", "a1", "a2"])
        track()
        // The same items again: nothing to redraw.
        feed.apply(try decode(#"{"type":"items","items":[{"kind":"agent","id":"a2","text":"More."}]}"#))
        XCTAssertEqual(changes.value, 1)
    }

    func testOutputWaitsWhileThePageIsAway() {
        let feed = TerminalFeed()
        feed.open()
        feed.pause()
        feed.receive(Data("line\r\n".utf8))
        feed.receive(Data("more\r\n".utf8))
        XCTAssertEqual(feed.heldBytes, 12)
        feed.resume()
        XCTAssertEqual(feed.heldBytes, 0, "it reaches the surface once the page is back")
        XCTAssertFalse(feed.overflowed)
    }

    func testTooMuchOutputWhileAwayMeansAFreshAttach() {
        let feed = TerminalFeed()
        feed.open()
        feed.pause()
        feed.receive(Data(count: TerminalFeed.pausedLimit + 1))
        XCTAssertTrue(feed.overflowed)
        XCTAssertEqual(feed.heldBytes, 0, "nothing piles up past the limit")
    }

    func testLeavingDuringTheFirstPaintAttachesAfreshNextTime() {
        TerminalCell.forget()
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        model.pageSize(CGSize(width: 402, height: 600))
        model.resume(config, session: "t1", fontSize: 9)
        XCTAssertEqual(model.attempt, 1)
        // No surface has shown the first paint yet.
        model.pause()
        XCTAssertNil(model.feed)
        model.resume(config, session: "t1", fontSize: 9)
        XCTAssertEqual(model.attempt, 2)
        model.stop()
    }

    func testAnotherFontSizeAttachesAfresh() {
        TerminalCell.forget()
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        model.pageSize(CGSize(width: 402, height: 600))
        model.resume(config, session: "t1", fontSize: 9)
        model.resume(config, session: "t1", fontSize: 12)
        XCTAssertEqual(model.attempt, 2)
        model.stop()
    }

    func testAttachWaitsForThePagesSize() {
        TerminalCell.forget()
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        model.resume(config, session: "t1", fontSize: 9)
        XCTAssertEqual(model.attempt, 0, "no grid to ask for before the first layout")
        model.pageSize(CGSize(width: 402, height: 600))
        XCTAssertEqual(model.attempt, 1)
        XCTAssertNil(model.takeover, "no cell measured yet: watch first")
        model.stop()
    }

    func testTakeoverAsksForThePhonesGridAndLetsGoOnLeaving() {
        TerminalCell.forget()
        TerminalCell.remember(CGSize(width: 5.5, height: 11), fontSize: 9)
        defer { TerminalCell.forget() }
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        model.pageSize(CGSize(width: 402, height: 600))
        model.resume(config, session: "t1", fontSize: 9)
        XCTAssertEqual(model.takeover, TerminalGrid(cols: 70, rows: 53))
        XCTAssertEqual(model.attempt, 1)
        // Inactive and back (Control Center): still holding it.
        model.resume(config, session: "t1", fontSize: 9)
        XCTAssertEqual(model.attempt, 1)
        // Leaving lets go; coming back takes over afresh.
        model.pause()
        model.resume(config, session: "t1", fontSize: 9)
        XCTAssertEqual(model.attempt, 2)
        XCTAssertNotNil(model.takeover)
        model.stop()
    }

    /// The Gateway keeps a resumable stream a while after the connection
    /// drops; the observer comes back with the token and the bytes it has.
    func testAStreamCanBePickedUpWhereItWas() throws {
        let observer = TerminalObserver()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        observer.start(config, session: "t1", takeover: TerminalGrid(cols: 70, rows: 53))
        XCTAssertFalse(observer.canComeBack, "nothing to come back to before the Gateway says so")
        try observer.receive(control: #"{"type":"attached","cols":70,"rows":53,"resume":"tok1","keep_ms":30000}"#)
        XCTAssertTrue(observer.canComeBack)
        observer.suspend()
        XCTAssertTrue(observer.isSuspended)
        XCTAssertTrue(observer.comeBack())
        XCTAssertTrue(observer.reconnecting)
        XCTAssertFalse(observer.isSuspended)
        try observer.receive(control: #"{"type":"resumed","resume":"tok2","keep_ms":30000}"#)
        XCTAssertFalse(observer.reconnecting)
        // Leaving for good forgets the stream.
        observer.stop()
        XCTAssertFalse(observer.canComeBack)
        XCTAssertFalse(observer.comeBack())
    }

    /// An older Gateway sends no token: the background is as leaving, and
    /// coming back takes over afresh.
    func testWithoutAResumeTokenTheBackgroundLetsGo() {
        TerminalCell.forget()
        TerminalCell.remember(CGSize(width: 5.5, height: 11), fontSize: 9)
        defer { TerminalCell.forget() }
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        model.pageSize(CGSize(width: 402, height: 600))
        model.resume(config, session: "t1", fontSize: 9)
        model.observer.attached(cols: 70, rows: 53)
        model.suspend()
        XCTAssertFalse(model.observer.isSuspended)
        model.resume(config, session: "t1", fontSize: 9)
        XCTAssertEqual(model.attempt, 2)
        model.stop()
    }

    /// Claude Code and other full-screen programs keep their history
    /// themselves and scroll on the mouse wheel. Taken over, the wheel
    /// reports Ghostty writes for a drag reach the Gateway, and a tap's
    /// click doesn't; only watching, nothing does.
    func testTakeoverPassesTheWheelOnToTheProgram() async throws {
        TerminalCell.forget()
        TerminalCell.remember(CGSize(width: 5.5, height: 11), fontSize: 9)
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        model.pageSize(CGSize(width: 402, height: 600))
        model.resume(config, session: "t1", fontSize: 9)
        XCTAssertNotNil(model.takeover)
        let feed = try XCTUnwrap(model.feed)
        // What Ghostty's write would carry: a tap, then a drag up.
        feed.session.sendInput(Data("\u{1b}[<0;3;4M\u{1b}[<0;3;4m".utf8))
        feed.session.sendInput(Data("\u{1b}[<64;3;4M\u{1b}[<64;3;4M".utf8))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.observer.wheels, [Data("\u{1b}[<64;3;4M\u{1b}[<64;3;4M".utf8)])
        model.stop()

        TerminalCell.forget()
        let watching = TerminalModel()
        watching.pageSize(CGSize(width: 402, height: 600))
        watching.resume(config, session: "t1", fontSize: 9)
        XCTAssertNil(watching.takeover)
        try XCTUnwrap(watching.feed).session.sendInput(Data("\u{1b}[<64;3;4M".utf8))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(watching.observer.wheels, [], "a watching stream never writes to the terminal")
        watching.stop()
    }

    /// A page coming back measures its surface before core answers the
    /// attach; once it answers, core is asked for the grid on screen.
    func testSurfaceGridFromBeforeTheAttachIsAskedFor() async throws {
        TerminalCell.forget()
        TerminalCell.remember(CGSize(width: 5.5, height: 11), fontSize: 9)
        defer { TerminalCell.forget() }
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        model.pageSize(CGSize(width: 402, height: 760))
        model.resume(config, session: "t1", fontSize: 9)
        let asked = try XCTUnwrap(model.takeover)
        let onScreen = TerminalGrid(cols: asked.cols, rows: asked.rows - 9)
        model.surfaceGrid(onScreen)
        XCTAssertEqual(model.observer.resizes, [], "nothing to resize before core answers")
        model.observer.attached(cols: asked.cols, rows: asked.rows)
        model.phaseChanged()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.observer.resizes, [onScreen])
        XCTAssertEqual(model.takeover, onScreen)
        model.stop()
    }
}
