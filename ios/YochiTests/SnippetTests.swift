import Foundation
import Testing

@testable import Yochi

@MainActor
struct SnippetTests {
    private func store(_ name: String = UUID().uuidString) -> (SnippetStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "snippet-tests-\(name)")!
        defaults.removePersistentDomain(forName: "snippet-tests-\(name)")
        return (SnippetStore(defaults: defaults), defaults)
    }

    @Test("A new install starts with a few common ones")
    func presets() {
        let (store, _) = store()
        #expect(store.snippets.count == 5)
        #expect(store.snippets.map(\.text).contains(String(localized: "Run the tests")))
    }

    @Test("Adding trims, ignores blanks, and survives a relaunch")
    func addAndPersist() {
        let (store, defaults) = store()
        #expect(!store.add("   \n"))
        #expect(store.add("  Rebase on main  "))
        #expect(store.snippets.last?.text == "Rebase on main")
        let again = SnippetStore(defaults: defaults)
        #expect(again.snippets == store.snippets)
    }

    @Test("Editing, deleting and moving change the list in order")
    func editDeleteMove() throws {
        let (store, defaults) = store()
        let first = try #require(store.snippets.first)
        #expect(store.update(first.id, to: " Go on "))
        #expect(store.snippets[0].text == "Go on")
        #expect(!store.update(first.id, to: " "), "a blank edit is refused")
        #expect(store.snippets[0].text == "Go on")
        let second = store.snippets[1]
        store.move(from: IndexSet(integer: 1), to: 0)
        #expect(store.snippets[0] == second)
        store.remove(at: IndexSet(integer: 0))
        #expect(!store.snippets.contains(second))
        #expect(SnippetStore(defaults: defaults).snippets == store.snippets)
        store.resetToDefaults()
        #expect(store.snippets.count == 5)
    }

    @Test("Nothing saved yet, or something unreadable, means the presets")
    func unreadableFallsBack() {
        let (_, defaults) = store()
        defaults.set(Data("nonsense".utf8), forKey: SnippetStore.key)
        #expect(SnippetStore(defaults: defaults).snippets.count == 5)
    }
}
