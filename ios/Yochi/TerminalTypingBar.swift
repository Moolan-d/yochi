import GhosttyTerminal
import SwiftUI

/// The key bar of a takeover that types straight into the terminal: a glass
/// capsule of control keys that swipes through three pages, and beside it a
/// button for the keyboard and one for the command field, which is where
/// text the terminal's ASCII keyboard can't type is written (Chinese,
/// dictation, several lines).
struct TerminalTypingBar: View {
    let model: TerminalModel
    /// The command field is shown, for the program's input to be written
    /// there instead.
    let composing: Bool
    /// The command field has the keyboard.
    let composerFocused: Bool
    /// Presses a key that is not a modifier or the arrows.
    let press: (TypingKey) -> Void
    let toggleKeyboard: () -> Void
    let toggleComposer: () -> Void

    @State private var page: Int? = 0
    @State private var showsArrows = false
    @State private var taps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 44

    private enum Page {
        static func number(_ page: Int?) -> Int { (page ?? 0) + 1 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 5) {
                pages
                dots
            }
            roundButton(systemImage: model.keyboardShown || composerFocused ? "keyboard.chevron.compact.down" : "keyboard",
                        highlighted: model.keyboardShown || composerFocused,
                        action: toggleKeyboard)
                .accessibilityLabel(model.keyboardShown || composerFocused ? "Hide Keyboard" : "Show Keyboard")
                .accessibilityIdentifier("toggleKeyboard")
            roundButton(systemImage: "square.and.pencil", highlighted: composing, action: toggleComposer)
                .accessibilityLabel(composing ? "Hide Command Field" : "Write a Command")
                .accessibilityHint("For Chinese, dictation or several lines")
                .accessibilityIdentifier("toggleComposer")
        }
        // Cap the text so seven keys keep fitting a page.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    private var pages: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(TypingKey.pages.indices, id: \.self) { index in
                    HStack(spacing: 0) {
                        ForEach(TypingKey.pages[index]) { key in keyButton(key) }
                    }
                    .padding(.horizontal, 4)
                    .containerRelativeFrame(.horizontal)
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .frame(height: height)
        .clipShape(.capsule)
        .typingGlass(in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal Keys")
        .accessibilityValue("Page \(Page.number(page)) of \(TypingKey.pages.count)")
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(TypingKey.pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == (page ?? 0) ? Color.primary : Color.primary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: page)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func keyButton(_ key: TypingKey) -> some View {
        let armed = if case .sticky(let modifier) = key.action { model.armed.contains(modifier) } else { false }
        let button = Button {
            taps += 1
            switch key.action {
            case .press: press(key)
            case .sticky(let modifier): model.toggleSticky(modifier)
            case .arrows: showsArrows = true
            }
        } label: {
            Text(key.label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .buttonStyle(TypingKeyStyle(armed: armed))
        .accessibilityLabel(key.spoken)
        .accessibilityAddTraits(armed ? .isSelected : [])
        .accessibilityIdentifier("key-\(key.id)")
        if key.action == .arrows {
            button
                .popover(isPresented: $showsArrows, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                    arrows
                        .presentationCompactAdaptation(.popover)
                }
        } else {
            button
        }
    }

    /// Up above, and left, down and right beneath it, as on a keyboard. Each
    /// press leaves the popover up, so a few can follow one another.
    private var arrows: some View {
        VStack(spacing: 4) {
            arrowButton(TypingKey.up)
            HStack(spacing: 4) {
                arrowButton(TypingKey.left)
                arrowButton(TypingKey.down)
                arrowButton(TypingKey.right)
            }
        }
        .padding(8)
    }

    private func arrowButton(_ key: TypingKey) -> some View {
        Button {
            taps += 1
            press(key)
        } label: {
            Text(key.label)
                .font(.title3.weight(.medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(TypingKeyStyle(armed: false))
        .accessibilityLabel(key.spoken)
        .accessibilityIdentifier("key-\(key.id)")
    }

    private func roundButton(systemImage: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .frame(width: height, height: height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .typingGlass(in: .circle, tint: highlighted ? .accentColor : nil)
    }
}

/// A key on the capsule: no cap of its own, only a fill while pressed or
/// while Ctrl or Alt wait for the next key.
private struct TypingKeyStyle: ButtonStyle {
    let armed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(armed ? Color.white : Color.primary)
            .frame(minWidth: 30, maxWidth: .infinity, minHeight: 44)
            .background {
                if armed {
                    Capsule().fill(Color.accentColor).padding(.vertical, 5)
                } else if configuration.isPressed {
                    Capsule().fill(Color.primary.opacity(0.15)).padding(.vertical, 5)
                }
            }
            .contentShape(.rect)
    }
}

private extension View {
    /// The Liquid Glass of iOS 26, or a material before it.
    @ViewBuilder
    func typingGlass(in shape: some InsettableShape, tint: Color? = nil) -> some View {
        if #available(iOS 26, *) {
            glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: shape)
        } else {
            background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.regularMaterial), in: shape)
                .overlay { shape.strokeBorder(Color(.separator).opacity(0.5)) }
        }
    }
}
