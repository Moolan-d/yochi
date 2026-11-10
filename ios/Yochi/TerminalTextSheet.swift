import SwiftUI
import UIKit

/// A long press in the terminal hands its visible text here: a native, selectable
/// text view with the pressed word (or the whole viewport) already selected, so
/// copying is one tap. Selecting text here never types into the terminal.
struct TerminalTextSheet: View {
    let selection: TerminalTextSelection
    let onCopied: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedText: String

    init(selection: TerminalTextSelection, onCopied: @escaping () -> Void) {
        self.selection = selection
        self.onCopied = onCopied
        _selectedText = State(initialValue: TerminalTextSelection.initialText(selection.text,
                                                                             anchor: selection.anchor))
    }

    var body: some View {
        NavigationStack {
            TerminalTextView(text: selection.text, anchor: selection.anchor, selectedText: $selectedText)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Copy") {
                            UIPasteboard.general.string = selectedText
                            onCopied()
                            dismiss()
                        }
                        .disabled(selectedText.isEmpty)
                        .accessibilityIdentifier("copyTerminalSelection")
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The terminal's visible rows in the same monospaced text the terminal draws.
/// A text view is what gives selection handles and the system edit menu without
/// writing our own.
private struct TerminalTextView: UIViewRepresentable {
    let text: String
    let anchor: NSRange?
    @Binding var selectedText: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 14, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.text = text
        let length = (text as NSString).length
        if let anchor, anchor.length > 0, anchor.location >= 0, NSMaxRange(anchor) <= length {
            view.selectedRange = anchor
        } else {
            view.selectedRange = NSRange(location: 0, length: length)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedText: $selectedText)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let selectedText: Binding<String>

        init(selectedText: Binding<String>) {
            self.selectedText = selectedText
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let text = textView.text as NSString
            let range = textView.selectedRange
            guard range.location >= 0, NSMaxRange(range) <= text.length else { return }
            selectedText.wrappedValue = text.substring(with: range)
        }
    }
}
