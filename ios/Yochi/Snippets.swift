import SwiftUI

/// A piece of text the composer can insert: what the user says to the Agent
/// again and again.
struct Snippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
}

/// The user's snippets, on this iPhone only (UserDefaults, no sync).
@MainActor @Observable
final class SnippetStore {
    static let shared = SnippetStore()
    static let key = "snippets"

    /// What a new install starts with.
    static var defaults: [Snippet] {
        [String(localized: "Continue"), String(localized: "Run the tests"), String(localized: "Commit this"),
         String(localized: "OK, go with your suggestion"), String(localized: "Stop first, and explain what you plan to do next")]
            .map { Snippet(text: $0) }
    }

    private let defaultsStore: UserDefaults
    private(set) var snippets: [Snippet]

    init(defaults store: UserDefaults = .standard) {
        defaultsStore = store
        if let data = store.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = saved
        } else {
            snippets = Self.defaults
        }
    }

    /// Nothing but whitespace isn't a snippet.
    @discardableResult
    func add(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        snippets.append(Snippet(text: text))
        save()
        return true
    }

    @discardableResult
    func update(_ id: Snippet.ID, to text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = snippets.firstIndex(where: { $0.id == id }) else { return false }
        snippets[index].text = text
        save()
        return true
    }

    func remove(at offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func resetToDefaults() {
        snippets = Self.defaults
        save()
    }

    private func save() {
        defaultsStore.set(try? JSONEncoder().encode(snippets), forKey: Self.key)
    }
}

/// Settings → Snippets: add, edit, delete and reorder.
struct SnippetsView: View {
    @State private var store = SnippetStore.shared
    @State private var editing: Snippet?
    @State private var adding = false

    var body: some View {
        HomeForm {
            Section {
                ForEach(store.snippets) { snippet in
                    Button { editing = snippet } label: {
                        Text(snippet.text)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
                .onDelete { store.remove(at: $0) }
                .onMove { store.move(from: $0, to: $1) }
                Button("Add Snippet", systemImage: "plus") { adding = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("addSnippet")
            } footer: {
                Text("Snippets are kept on this device. The + menu in a conversation inserts them into the message.")
            }
            Section {
                Button("Restore Default Snippets", role: .destructive) { store.resetToDefaults() }
                    .frame(minHeight: 44)
            }
        }
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) { SnippetEditor(title: "Add Snippet", text: "") { store.add($0) } }
        .sheet(item: $editing) { snippet in
            SnippetEditor(title: "Edit Snippet", text: snippet.text) { store.update(snippet.id, to: $0) }
        }
    }
}

private struct SnippetEditor: View {
    let title: LocalizedStringKey
    @State var text: String
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Text to insert", text: $text, axis: .vertical)
                    .lineLimit(2...8)
                    .accessibilityIdentifier("snippetText")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if save(text) { dismiss() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
