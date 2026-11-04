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
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
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
        let model = TerminalModel()
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        model.resume(config, session: "t1", fontSize: 9)
        model.resume(config, session: "t1", fontSize: 12)
        XCTAssertEqual(model.attempt, 2)
        model.stop()
    }
}
