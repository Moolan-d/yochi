import SwiftUI
import UIKit

/// A full-screen program's history as text. Claude Code and other full-screen
/// programs keep their history to themselves, so the terminal the phone draws
/// has none to scroll; core reads it by scrolling the program and putting it
/// back, and it shows here, newest at the bottom, selectable for copying.
struct TerminalHistorySheet: View {
    let session: String
    let client: GatewayClient

    private enum Phase {
        case loading
        case loaded(text: String, note: String?)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.loading

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("正在读取历史…")
                case .loaded(let text, let note):
                    HistoryTextView(text: text)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if let note {
                                BannerLabel(text: note, systemImage: "info.circle")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.bar)
                            }
                        }
                case .failed(let reason):
                    ContentUnavailableView {
                        Label("无法读取历史", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(reason)
                    } actions: {
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("终端历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        switch await client.readHistory(session: session) {
        case .read(let text, let complete, let why):
            let note: String? = switch (complete, why) {
            case (true, _): nil
            case (false, "working"): "Agent 正在工作，只读到当前一屏；停下后再看完整历史"
            case (false, _): "只读到了部分历史"
            }
            phase = .loaded(text: Self.tidy(text), note: note)
        case .failed(_, let message):
            phase = .failed(message)
        }
    }

    /// Rows come as wide as the desktop's screen: trailing padding would wrap
    /// into blank lines on the phone.
    static func tidy(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/\s+$/, with: "") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }
}

/// Wrapping monospaced text that opens at its end, where the screen was.
private struct HistoryTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> BottomFirstTextView {
        let view = BottomFirstTextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.text = text
        view.accessibilityIdentifier = "terminalHistory"
        return view
    }

    func updateUIView(_ view: BottomFirstTextView, context: Context) {}
}

private final class BottomFirstTextView: UITextView {
    private var scrolledToEnd = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !scrolledToEnd, bounds.height > 0 else { return }
        scrolledToEnd = true
        let bottom = contentSize.height + adjustedContentInset.bottom - bounds.height
        setContentOffset(CGPoint(x: 0, y: max(-adjustedContentInset.top, bottom)), animated: false)
    }
}
