import SwiftUI

/// The home pages' colors as plain numbers, so a test can check their
/// contrast.
enum HomeColorValues {
    /// Dark orange text for a question, and the pill's fill and text.
    static let warnText: (light: UInt32, dark: UInt32) = (0x8F540C, 0xF2B866)
    static let warnFill: (light: UInt32, dark: UInt32) = (0xF4E9D8, 0x4A3818)
    static let errorText: (light: UInt32, dark: UInt32) = (0xA3201A, 0xFF9E96)
    static let errorFill: (light: UInt32, dark: UInt32) = (0xF9DEDB, 0x4D2220)
    /// The page behind the cards, and the cards (system grouped rows).
    static let page: (light: UInt32, dark: UInt32) = (0xF2F3F0, 0x121211)
    static let card: (light: UInt32, dark: UInt32) = (0xFFFFFF, 0x1C1C1E)

    /// Text and the color it sits on; each must read at 4.5:1.
    static let pairs: [(UInt32, UInt32)] = [
        (warnText.light, warnFill.light), (warnText.dark, warnFill.dark),
        (errorText.light, errorFill.light), (errorText.dark, errorFill.dark),
        (warnText.light, card.light), (warnText.dark, card.dark),
        (errorText.light, card.light), (errorText.dark, card.dark),
    ]
}

extension Color {
    /// A color that follows light and dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    init(pair: (light: UInt32, dark: UInt32)) {
        self.init(light: pair.light, dark: pair.dark)
    }

    /// Warm gray behind the grouped cards.
    static let homePage = Color(pair: HomeColorValues.page)
    static let warnText = Color(pair: HomeColorValues.warnText)
    static let warnFill = Color(pair: HomeColorValues.warnFill)
    static let errorText = Color(pair: HomeColorValues.errorText)
    static let errorFill = Color(pair: HomeColorValues.errorFill)

    /// The tile of the space with this id; gray outside any space.
    static func spaceTile(_ id: String?) -> Color {
        guard let id else { return Color(light: 0x6E6E73, dark: 0x5C5C61) }
        let index = SpacePalette.index(for: id)
        return Color(light: SpacePalette.light[index], dark: SpacePalette.dark[index])
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Marks

/// The mark on a space tile's corner, and the glyph of a program's square.
enum ProgramGlyph: Equatable {
    case claude, pi
    /// Any other Agent CLI.
    case agent
    /// A shell, dev server and the like.
    case terminal

    init(_ session: Session) {
        switch session.program?.lowercased() {
        case "claude" where session.isAgent: self = .claude
        case "pi": self = .pi
        default: self = session.isAgent ? .agent : .terminal
        }
    }

    @ViewBuilder
    var glyph: some View {
        switch self {
        case .claude: Image(systemName: "asterisk")
        case .pi: Text(verbatim: "π")
        case .agent: Image(systemName: "cpu")
        case .terminal: Image(systemName: "apple.terminal")
        }
    }

    /// The program's own color; nil keeps the plain one.
    var brand: Color? { self == .claude ? AgentBrand.claude : nil }
}

extension HomeRow {
    /// The letter on its tile: the space's, else the folder's (or machine's).
    var tileLetter: String {
        let name = [space, folder, session.machine].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "?"
        return String(name.prefix(1)).uppercased()
    }

    /// The same row without its tab: under the tab's own header it says nothing.
    var withoutTab: HomeRow {
        HomeRow(session: session, space: space, tab: nil, unseen: unseen, spaceID: spaceID)
    }
}

/// A rounded square in a space's color with its first letter in white; an
/// Agent's or terminal's tile wears the program's badge on the corner.
struct SpaceTile: View {
    let letter: String
    /// The space's id, which picks the color; nil for the gray of no space.
    let spaceID: String?
    var badge: ProgramGlyph?

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(Color.spaceTile(spaceID))
            .frame(width: size, height: size)
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    ProgramBadge(glyph: badge, size: size * 0.46)
                        .offset(x: size * 0.1, y: size * 0.1)
                }
            }
            .accessibilityHidden(true)
    }
}

struct ProgramBadge: View {
    let glyph: ProgramGlyph
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: size, height: size)
            .overlay {
                glyph.glyph
                    .font(.system(size: size * 0.62, weight: .bold))
                    .foregroundStyle(glyph.brand ?? Color(light: 0x3A3A3C, dark: 0x3A3A3C))
            }
            .shadow(color: .black.opacity(0.18), radius: 0.5)
    }
}

/// The program's mark in a rounded square, for the lists inside a space,
/// where the space's tile would say the same thing on every row.
struct ProgramSquare: View {
    let session: Session

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 36

    var body: some View {
        let glyph = ProgramGlyph(session)
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(glyph.brand.map { $0.opacity(0.16) } ?? Color(.tertiarySystemFill))
            .frame(width: size, height: size)
            .overlay {
                glyph.glyph
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(glyph.brand ?? .secondary)
            }
            .accessibilityHidden(true)
    }
}

/// "Needs You" in a pill; the number of Agents on a space's row.
struct StatusPill: View {
    enum Tone { case warn, error }

    let text: String
    var tone: Tone = .warn

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tone == .warn ? Color.warnText : Color.errorText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone == .warn ? Color.warnFill : Color.errorFill, in: .capsule)
    }
}

/// A small arc that turns while an Agent works; still with Reduce Motion.
struct WorkingIndicator: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Circle().inset(by: 1).trim(from: 0, to: 0.3)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                SpinningArc(lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct UnseenDot: View {
    var body: some View {
        Circle().fill(.blue).frame(width: 10, height: 10).accessibilityHidden(true)
    }
}

/// What a row says at its trailing edge: the state, then how long ago.
/// Color is never alone: the row's label says the state in words.
struct RowStatus: View {
    let row: HomeRow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 8) {
                switch row.signal {
                case .needsYou: StatusPill(text: String(localized: "Needs You"))
                case .error: StatusPill(text: String(localized: "Error"), tone: .error)
                case .working: WorkingIndicator()
                case .unseen: UnseenDot()
                case nil: EmptyView()
                }
                if let since = row.since(at: context.date) {
                    Text(since)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A tab's panes as a little map: gray panes, light blue where an Agent
/// works or waits, with a dot where it waits for the user.
struct MiniPaneMap: View {
    let layout: PaneNode
    let marks: [String: PaneMark]
    var size = CGSize(width: 34, height: 22)

    var body: some View {
        Canvas { context, canvas in
            let gap: CGFloat = size.width > 40 ? 2.5 : 2
            for frame in layout.frames(in: CGRect(origin: .zero, size: canvas), gap: gap) {
                let mark = frame.session.flatMap { marks[$0] } ?? .idle
                let shape = Path(roundedRect: frame.rect, cornerRadius: 2.5, style: .continuous)
                context.fill(shape, with: .color(mark == .idle ? Color(.tertiaryLabel).opacity(0.35) : Color.blue.opacity(0.32)))
                if mark == .blocked {
                    let dot: CGFloat = min(5, min(frame.rect.width, frame.rect.height) * 0.6)
                    let spot = CGRect(x: frame.rect.midX - dot / 2, y: frame.rect.midY - dot / 2, width: dot, height: dot)
                    context.fill(Path(ellipseIn: spot), with: .color(.warnText))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
