import Foundation
import Observation
import UIKit

/// Keeps a session page's feeds for a while after the page closes, so coming
/// back soon shows the last conversation and terminal at once and carries on
/// from there instead of loading from nothing. Only memory: nothing is
/// written to disk (GLOSSARY: Conversation History is not cached).
///
/// An entry is in use while a page shows it; once the last page leaves, it
/// stays for `ttl` with its streams still open, then it is stopped and
/// dropped. Memory warnings and the app going to the background drop every
/// entry not in use, and at most `limit` unused entries are kept.
@MainActor
final class FeedCache<Entry: AnyObject> {
    private struct Slot {
        let entry: Entry
        var users = 0
        /// When the last page left; nil while in use.
        var releasedAt: ContinuousClock.Instant?
    }

    let ttl: Duration
    let limit: Int
    private let now: () -> ContinuousClock.Instant
    private let discard: (Entry) -> Void
    private var slots: [String: Slot] = [:]
    private var sweeper: Task<Void, Never>?

    init(ttl: Duration = .seconds(60), limit: Int = 4,
         now: @escaping () -> ContinuousClock.Instant = { .now },
         discard: @escaping (Entry) -> Void) {
        self.ttl = ttl
        self.limit = limit
        self.now = now
        self.discard = discard
    }

    /// The kept entry, if any; changes nothing, so a view's init may ask.
    func cached(_ key: String) -> Entry? { slots[key]?.entry }

    var count: Int { slots.count }

    func isInUse(_ key: String) -> Bool { (slots[key]?.users ?? 0) > 0 }

    /// A page shows `entry`: it is kept for that key from now on. Returns
    /// whether it was already kept, which means its content is current.
    /// When another entry is kept for the key and no page shows it, `entry`
    /// takes its place; when one is in use, `entry` stays the page's own.
    @discardableResult
    func acquire(_ key: String, _ entry: Entry) -> Bool {
        if var slot = slots[key] {
            if slot.entry === entry {
                slot.users += 1
                slot.releasedAt = nil
                slots[key] = slot
                return true
            }
            guard slot.users == 0 else { return false }
            discard(slot.entry)
        }
        slots[key] = Slot(entry: entry, users: 1)
        return false
    }

    /// A page showing `entry` left. A page's own entry, never kept, stops now.
    func release(_ key: String, _ entry: Entry) {
        guard var slot = slots[key], slot.entry === entry else {
            discard(entry)
            return
        }
        slot.users = max(0, slot.users - 1)
        if slot.users == 0 { slot.releasedAt = now() }
        slots[key] = slot
        trimToLimit()
        scheduleSweep()
    }

    /// Drops entries unused for `ttl` or longer.
    func sweep() {
        let now = now()
        for (key, slot) in slots {
            guard slot.users == 0, let released = slot.releasedAt, now - released >= ttl else { continue }
            slots[key] = nil
            discard(slot.entry)
        }
    }

    /// Drops every entry no page shows: memory is short, or the app left
    /// the foreground and its streams close anyway.
    func dropUnused() {
        for (key, slot) in slots where slot.users == 0 {
            slots[key] = nil
            discard(slot.entry)
        }
    }

    func removeAll() {
        let all = slots.values
        slots = [:]
        all.forEach { discard($0.entry) }
    }

    /// Past the limit, the longest unused go first.
    private func trimToLimit() {
        let unused = slots.filter { $0.value.users == 0 }
            .sorted { ($0.value.releasedAt ?? now()) < ($1.value.releasedAt ?? now()) }
        for (key, slot) in unused.prefix(max(0, unused.count - limit)) {
            slots[key] = nil
            discard(slot.entry)
        }
    }

    private func scheduleSweep() {
        sweeper?.cancel()
        guard slots.values.contains(where: { $0.users == 0 }) else { return }
        let wait = ttl + .milliseconds(100)
        sweeper = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            sweep()
            scheduleSweep()
        }
    }
}

/// Everything one session's page streams: the conversation, the screen read
/// for dialogs, and the terminal for a page that shows it.
@MainActor
final class SessionFeeds {
    let conversation = ConversationFeed()
    let screen = ScreenFeed()
    let terminal = TerminalModel()

    func stop() {
        conversation.stop()
        screen.stop()
        terminal.stop()
    }
}

/// The session pages' cache, one per Gateway connection.
@MainActor
final class SessionFeedStore {
    let cache: FeedCache<SessionFeeds>
    private var observers: [NSObjectProtocol] = []

    init(ttl: Duration = .seconds(60), limit: Int = 4) {
        cache = FeedCache(ttl: ttl, limit: limit) { $0.stop() }
        let center = NotificationCenter.default
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cache.dropUnused() }
            })
        }
    }

    static func key(host: String, session: String) -> String { "\(host)\n\(session)" }

    /// The kept feeds for a page about to open, or fresh ones.
    func feeds(host: String, session: String) -> SessionFeeds {
        cache.cached(Self.key(host: host, session: session)) ?? SessionFeeds()
    }
}
