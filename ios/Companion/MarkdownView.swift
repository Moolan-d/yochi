import SwiftUI

/// One block of an Agent message's Markdown in reading order. SwiftUI's `Text`
/// draws inline styles but not block structure, so the message is drawn one
/// block at a time: lists after their markers, quotes with a bar, code in a
/// box and tables as aligned columns.
struct MarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        /// Levels 1 through 6.
        case heading(Int)
        /// The first block of a list item, drawn after its marker: a bullet
        /// that changes with depth, or the item's number.
        case listItem(marker: String)
        /// The first word of the fence's info string, if any.
        case code(language: String?)
        case table(MarkdownTable)
        case rule
    }

    var kind: Kind
    /// The text with its inline styles: strong, emphasis, code, links.
    var content: AttributedString
    /// How many list items contain the block: 0 outside any list.
    var listDepth = 0
    /// How many block quotes contain the block.
    var quoteDepth = 0

    /// The block as plain text, for tests and VoiceOver.
    var text: String { String(content.characters) }
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    var columns: [Alignment]
    /// The header row first, then the body; every row has one cell per column.
    var rows: [[AttributedString]]
}

extension MarkdownBlock {
    private final class Parsed {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    /// Parsed messages by their text. A lazy conversation list builds a row
    /// again each time it scrolls back into view, and the text of a finished
    /// message never changes, so it is parsed once. NSCache gives the memory
    /// back under pressure.
    nonisolated(unsafe) private static let parsedCache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 400
        return cache
    }()

    /// `parse`, kept for the next time the same text is drawn.
    static func cachedParse(_ markdown: String) -> [MarkdownBlock] {
        let key = markdown as NSString
        if let hit = parsedCache.object(forKey: key) { return hit.blocks }
        let blocks = parse(markdown)
        parsedCache.setObject(Parsed(blocks), forKey: key)
        return blocks
    }

    /// Splits Markdown into blocks with Foundation's GFM parser, which reports
    /// structure only through each run's presentation intent: runs are grouped
    /// by their innermost block, and lists and quotes by the intents around it.
    /// Nothing is fetched; images keep their alt text and HTML stays text.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(kind: .paragraph, content: AttributedString(markdown))]
        }

        var blocks: [MarkdownBlock] = []
        var current: (id: Int, block: MarkdownBlock)?
        var table: (id: Int, columns: [MarkdownTable.Alignment], rows: [Int: [Int: AttributedString]])?
        // A list item's marker goes on its first block only.
        var markedItems: Set<Int> = []

        func flush() {
            if let current { blocks.append(current.block) }
            current = nil
        }
        func flushTable() {
            guard let done = table else { return }
            table = nil
            let rows = done.rows.keys.sorted().map { row in
                done.columns.indices.map { done.rows[row]?[$0] ?? AttributedString() }
            }
            blocks.append(MarkdownBlock(kind: .table(MarkdownTable(columns: done.columns, rows: rows)),
                                        content: AttributedString()))
        }

        for run in parsed.runs {
            let piece = inline(parsed[run.range], intent: run.inlinePresentationIntent)
            let components = run.presentationIntent?.components ?? []

            if let tableIndex = components.firstIndex(where: { if case .table = $0.kind { true } else { false } }) {
                flush()
                let tableIntent = components[tableIndex]
                if table?.id != tableIntent.identity {
                    flushTable()
                    guard case .table(let columns) = tableIntent.kind else { continue }
                    table = (tableIntent.identity, columns.map(Self.alignment), [:])
                }
                var row = 0, column = 0
                for component in components[..<tableIndex] {
                    switch component.kind {
                    case .tableCell(let index): column = index
                    case .tableRow(let index): row = index
                    case .tableHeaderRow: row = 0
                    default: break
                    }
                }
                table?.rows[row, default: [:]][column, default: AttributedString()].append(piece)
                continue
            }
            flushTable()

            guard let innermost = components.first else {
                // Text outside any block: keep it with what came before.
                if current != nil { current?.block.content.append(piece) } else {
                    current = (-1, MarkdownBlock(kind: .paragraph, content: piece))
                }
                continue
            }
            if current?.id == innermost.identity {
                current?.block.content.append(piece)
                continue
            }
            flush()

            var listDepth = 0, quoteDepth = 0
            var item: (id: Int, ordinal: Int, ordered: Bool)?
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .listItem(let ordinal):
                    listDepth += 1
                    // The list that holds the innermost item says how to mark it.
                    if item == nil, index + 1 < components.count {
                        let ordered = if case .orderedList = components[index + 1].kind { true } else { false }
                        item = (component.identity, ordinal, ordered)
                    }
                case .blockQuote:
                    quoteDepth += 1
                default: break
                }
            }

            var kind: Kind
            var content = piece
            switch innermost.kind {
            case .header(let level):
                kind = .heading(level)
            case .codeBlock(let language):
                kind = .code(language: language?.split(separator: " ").first.map(String.init))
                // The fence's closing newline is not part of the code.
                while content.characters.last == "\n" {
                    content.removeSubrange(content.index(beforeCharacter: content.endIndex)..<content.endIndex)
                }
            case .thematicBreak:
                kind = .rule
                content = AttributedString()
            default:
                kind = .paragraph
            }
            if kind == .paragraph, let item, markedItems.insert(item.id).inserted {
                kind = .listItem(marker: item.ordered ? "\(item.ordinal)." : Self.bullet(depth: listDepth))
            }
            current = (innermost.identity,
                       MarkdownBlock(kind: kind, content: content, listDepth: listDepth, quoteDepth: quoteDepth))
        }
        flush()
        flushTable()
        return blocks
    }

    /// A run's text with only its inline styling. A soft line break stays a
    /// line break, as Claude Code's terminal shows it, rather than a space.
    private static func inline(_ run: AttributedSubstring, intent: InlinePresentationIntent?) -> AttributedString {
        var piece = AttributedString(run)
        piece.presentationIntent = nil
        if let intent, intent.contains(.softBreak) || intent.contains(.lineBreak) {
            return AttributedString("\n")
        }
        return piece
    }

    private static func alignment(_ column: PresentationIntent.TableColumn) -> MarkdownTable.Alignment {
        switch column.alignment {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    private static func bullet(depth: Int) -> String {
        ["•", "◦", "▪︎"][(depth - 1) % 3]
    }
}

/// An Agent message's Markdown, laid out block by block.
struct MarkdownText: View {
    let text: String

    @ScaledMetric(relativeTo: .body) private var blockGap: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var itemGap: CGFloat = 6
    @ScaledMetric(relativeTo: .body) private var aboveHeading: CGFloat = 20

    var body: some View {
        let _ = Perf.count("MarkdownText")
        let blocks = MarkdownBlock.cachedParse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
                    .padding(.top, gap(before: index, in: blocks))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func gap(before index: Int, in blocks: [MarkdownBlock]) -> CGFloat {
        guard index > 0 else { return 0 }
        let block = blocks[index], previous = blocks[index - 1]
        if case .heading = block.kind { return aboveHeading }
        if case .heading = previous.kind { return itemGap }
        // Items of one list, and what continues an item, sit closer than paragraphs.
        if block.listDepth > 0, previous.listDepth > 0 { return itemGap }
        return blockGap
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 4

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<block.quoteDepth, id: \.self) { _ in
                Capsule().fill(Color(.tertiaryLabel)).frame(width: 3)
            }
            content
                .foregroundStyle(block.quoteDepth > 0 ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, leadingIndent)
    }

    /// An item's marker sits one level out from its text; a block continuing
    /// the item lines up with that text.
    private var leadingIndent: CGFloat {
        guard block.listDepth > 0 else { return 0 }
        if case .listItem = block.kind { return CGFloat(block.listDepth - 1) * indent }
        return CGFloat(block.listDepth) * indent
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            styled(.body)
        case .heading(let level):
            styled(Self.headingFont(level))
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: indent - 6, alignment: .trailing)
                styled(.body)
            }
        case .code(let language):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                // Code scrolls sideways rather than wrapping, so its lines stay lines.
                ScrollView(.horizontal) {
                    Text(verbatim: block.text)
                        .font(.footnote.monospaced())
                        .lineSpacing(2)
                        .fixedSize()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
    }

    private func styled(_ font: Font) -> some View {
        Text(MarkdownStyle.styled(block.content, in: font))
            .font(font)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Every level is bold, as Claude Code's terminal draws them; the top two are larger.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        default: .body.weight(.bold)
        }
    }
}

enum MarkdownStyle {
    /// Strong text in a real bold weight and inline code tinted. `Text` draws
    /// the strong intent only semibold, which barely shows in Chinese; and the
    /// monospaced design has no CJK glyphs, so code in Chinese needs the tint
    /// to read as code.
    static func styled(_ content: AttributedString, in font: Font) -> AttributedString {
        var result = content
        for run in content.runs {
            guard var intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.stronglyEmphasized) {
                intent.remove(.stronglyEmphasized)
                result[run.range].inlinePresentationIntent = intent.isEmpty ? nil : intent
                result[run.range].font = font.weight(.bold)
            }
            if intent.contains(.code) {
                result[run.range].font = font.monospaced()
                result[run.range].backgroundColor = Color(.tertiarySystemFill)
            }
        }
        return result
    }
}

/// A table as columns that keep their widths across rows. A narrow table
/// fits the phone with its cells wrapping; a wide one scrolls sideways.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    @ScaledMetric(relativeTo: .subheadline) private var minimumColumnWidth: CGFloat = 96

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5)
        }
    }

    private var grid: some View {
        MarkdownTableLayout(columns: table.columns.count, minimumColumnWidth: minimumColumnWidth) {
            ForEach(table.rows.indices, id: \.self) { row in
                ForEach(table.columns.indices, id: \.self) { column in
                    cell(row: row, column: column)
                }
            }
        }
    }

    private func cell(row: Int, column: Int) -> some View {
        let header = row == 0
        let font: Font = header ? .subheadline.weight(.semibold) : .subheadline
        let alignment = table.columns[column]
        return Text(MarkdownStyle.styled(table.rows[row][column], in: font))
            .font(font)
            .lineSpacing(2)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignment == .center ? .top : alignment == .trailing ? .topTrailing : .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(header ? Color(.secondarySystemBackground) : .clear)
            .overlay(alignment: .bottom) {
                if row < table.rows.count - 1 { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
            }
            .overlay(alignment: .trailing) {
                if column < table.columns.count - 1 { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
            }
            .accessibilityAddTraits(header ? .isHeader : [])
    }
}

/// Columns as wide as their content asks while the table fits; past that a
/// short column keeps its width and the long ones share what is left, each at
/// least `minimumColumnWidth` (or its content, if narrower). Each row is as tall
/// as its tallest cell, so a long cell wraps without moving other columns.
struct MarkdownTableLayout: Layout {
    let columns: Int
    let minimumColumnWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(available: proposal.width, subviews: subviews)
        return CGSize(width: widths.reduce(0, +), height: rowHeights(widths: widths, subviews: subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(available: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in rowHeights(widths: widths, subviews: subviews).enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard subviews.indices.contains(index) else { continue }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: widths[column], height: height))
                x += widths[column]
            }
            y += height
        }
    }

    /// Without a width to fit, the narrowest the table goes: that is what
    /// decides whether it fits the phone or scrolls, and how it scrolls.
    func columnWidths(available: CGFloat?, subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        var ideal = [CGFloat](repeating: 0, count: columns)
        for (index, subview) in subviews.enumerated() {
            ideal[index % columns] = max(ideal[index % columns], ceil(subview.sizeThatFits(.unspecified).width))
        }
        return Self.share(available ?? 0, ideal: ideal, minimum: minimumColumnWidth)
    }

    /// Fills `available` when the columns can; never narrower than each
    /// column's floor, so the sum may overrun it, and the table then scrolls.
    static func share(_ available: CGFloat, ideal: [CGFloat], minimum: CGFloat) -> [CGFloat] {
        let total = ideal.reduce(0, +)
        // Room to spare: every column grows by the same share of its content.
        if total <= available {
            guard total > 0 else { return ideal.map { _ in available / CGFloat(ideal.count) } }
            return ideal.map { $0 * available / total }
        }
        var widths = ideal
        var open = Set(ideal.indices)
        var remaining = available
        // Columns narrower than an even share keep their width; repeat with the rest.
        while !open.isEmpty {
            let fair = remaining / CGFloat(open.count)
            let fitting = open.filter { ideal[$0] <= fair }
            guard !fitting.isEmpty else {
                for column in open { widths[column] = max(fair, min(ideal[column], minimum)) }
                break
            }
            for column in fitting { remaining -= ideal[column] }
            open.subtract(fitting)
        }
        return widths
    }

    private func rowHeights(widths: [CGFloat], subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            (start..<min(start + columns, subviews.count)).map { index in
                subviews[index].sizeThatFits(ProposedViewSize(width: widths[index - start], height: nil)).height
            }.max() ?? 0
        }
    }
}
