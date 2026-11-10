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
        /// The first block of a task list item, `- [ ]` or `- [x]`, drawn
        /// after a check circle instead of a bullet.
        case taskItem(done: Bool)
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

    /// How much there is to reveal: a block's characters, a table or rule as one.
    var revealLength: Int {
        switch kind {
        case .table, .rule: 1
        default: max(1, content.characters.count)
        }
    }

    /// The first `length` of a message, as it would read part-way through
    /// arriving: whole blocks, then the start of the next. The message is
    /// parsed once whole, so a reveal costs no parsing per frame; a table or
    /// rule shows whole.
    static func revealed(_ blocks: [MarkdownBlock], upTo length: Int) -> [MarkdownBlock] {
        var left = length
        var out: [MarkdownBlock] = []
        for block in blocks {
            guard left > 0 else { break }
            let size = block.revealLength
            if size <= left {
                out.append(block)
            } else {
                var part = block
                let characters = block.content.characters
                let end = characters.index(characters.startIndex, offsetBy: left)
                part.content = AttributedString(block.content[block.content.startIndex..<end])
                out.append(part)
            }
            left -= size
        }
        return out
    }

    /// The message as far as `position`, its newest characters fading in:
    /// a character is clear once the position is `fade` past it, and the one
    /// the position is on has only just begun to show. Code, tables and rules
    /// are drawn without the fade.
    static func revealed(_ blocks: [MarkdownBlock], at position: Double, fade: Double) -> [MarkdownBlock] {
        var out = revealed(blocks, upTo: Int(position.rounded(.up)))
        guard fade > 0 else { return out }
        var start = 0
        for index in out.indices {
            let block = out[index]
            let length = block.revealLength
            defer { start += length }
            // Clear already, or not text the fade can be drawn on.
            guard Double(start + length) > position - fade else { continue }
            switch block.kind {
            case .paragraph, .heading, .listItem, .taskItem: break
            case .code, .table, .rule: continue
            }
            let base: Color = block.quoteDepth > 0 ? .secondary : .primary
            let content = block.content
            let characters = content.characters
            let first = max(0, Int((position - fade).rounded(.down)) - start)
            guard first < length else { continue }
            var at = characters.index(characters.startIndex, offsetBy: first)
            var faded = AttributedString(content[content.startIndex..<at])
            for offset in first..<length {
                let next = characters.index(after: at)
                var piece = AttributedString(content[at..<next])
                let opacity = min(1, max(0, (position - Double(start + offset)) / fade))
                if opacity < 1 {
                    let color = MarkdownStyle.isTintedCode(piece.runs.first) ? MarkdownStyle.codeTint : base
                    piece.swiftUI.foregroundColor = color.opacity(opacity)
                }
                faded.append(piece)
                at = next
            }
            out[index].content = faded
        }
        return out
    }

    static func revealLength(of blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { $0 + $1.revealLength }
    }

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
                let name = language?.split(separator: " ").first.map(String.init)
                kind = .code(language: name)
                // The fence's closing newline is not part of the code.
                var code = String(content.characters)
                while code.last == "\n" { code.removeLast() }
                // Colored here, once, so a reveal only cuts the colored text.
                content = SyntaxHighlight.highlighted(code, language: name)
            case .thematicBreak:
                kind = .rule
                content = AttributedString()
            default:
                kind = .paragraph
            }
            if kind == .paragraph, let item, markedItems.insert(item.id).inserted {
                if !item.ordered, let done = Self.taskMark(content) {
                    kind = .taskItem(done: done)
                    content.removeSubrange(content.startIndex..<content.characters.index(content.startIndex, offsetBy: 4))
                } else {
                    kind = .listItem(marker: item.ordered ? "\(item.ordinal)." : Self.bullet(depth: listDepth))
                }
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

    /// GitHub's task list syntax, which Foundation's parser leaves as text:
    /// whether `[ ] ` or `[x] ` starts the item, and if so whether it is done.
    private static func taskMark(_ content: AttributedString) -> Bool? {
        let start = String(content.characters.prefix(4))
        switch start {
        case "[ ] ": return false
        case "[x] ", "[X] ": return true
        default: return nil
        }
    }

    private static func bullet(depth: Int) -> String {
        ["•", "◦", "▪︎"][(depth - 1) % 3]
    }
}

/// An Agent message's Markdown, laid out block by block.
struct MarkdownText: View {
    let text: String
    /// Draw only this much of the message, as `MarkdownBlock.revealed` counts
    /// it, the last `fade` characters fading in; nil draws all of it.
    var shown: Double?
    var fade: Double = 0

    @ScaledMetric(relativeTo: .callout) private var blockGap: CGFloat = 10
    @ScaledMetric(relativeTo: .callout) private var itemGap: CGFloat = 4
    @ScaledMetric(relativeTo: .callout) private var belowHeading: CGFloat = 6
    @ScaledMetric(relativeTo: .callout) private var aboveHeading: CGFloat = 18

    var body: some View {
        let _ = Perf.count("MarkdownText")
        let parsed = MarkdownBlock.cachedParse(text)
        let blocks = shown.map { MarkdownBlock.revealed(parsed, at: $0, fade: fade) } ?? parsed
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
        if case .heading = previous.kind { return belowHeading }
        // Items of one list, and what continues an item, sit closer than paragraphs.
        if block.listDepth > 0, previous.listDepth > 0 { return itemGap }
        return blockGap
    }
}

/// One block, in a type scale a step below the system's body size: replies
/// are long and the phone is narrow, so 16 pt text with room between lines
/// reads better than 17 pt packed tight, as in Apple's own Mail and Notes.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    @ScaledMetric(relativeTo: .callout) private var indent: CGFloat = 20
    @ScaledMetric(relativeTo: .callout) private var lineSpacing: CGFloat = 5
    @ScaledMetric(relativeTo: .callout) private var codeSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var quoteCodeSize: CGFloat = 13

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<block.quoteDepth, id: \.self) { _ in
                Capsule().fill(Color(.separator)).frame(width: 3)
            }
            content
                .foregroundStyle(isQuote ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, leadingIndent)
    }

    private var isQuote: Bool { block.quoteDepth > 0 }
    /// 16 pt, a quote one step smaller.
    private var bodyFont: Font { isQuote ? .subheadline : .callout }
    /// Monospaced type looks a size larger than proportional type at the same size.
    private var codeFont: Font { .system(size: isQuote ? quoteCodeSize : codeSize, design: .monospaced) }

    /// An item's marker sits one level out from its text; a block continuing
    /// the item lines up with that text.
    private var leadingIndent: CGFloat {
        guard block.listDepth > 0 else { return 0 }
        switch block.kind {
        case .listItem, .taskItem: return CGFloat(block.listDepth - 1) * indent
        default: return CGFloat(block.listDepth) * indent
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            styled(bodyFont, code: codeFont)
        case .heading(let level):
            let font = Self.headingFont(level)
            styled(font, code: font.monospaced(), lineSpacing: 2)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(bodyFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: indent - 6, alignment: .trailing)
                styled(bodyFont, code: codeFont)
            }
        case .taskItem(let done):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(bodyFont)
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .frame(minWidth: indent - 6, alignment: .trailing)
                    .accessibilityLabel(done ? String(localized: "Completed") : String(localized: "To Do"))
                styled(bodyFont, code: codeFont, done: done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        case .code(let language):
            MarkdownCodeBlock(code: block.content, language: language)
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

    private func styled(_ font: Font, code: Font, lineSpacing: CGFloat? = nil, done: Bool = false) -> some View {
        MarkdownStyle.text(block.content, in: font, code: code)
            .strikethrough(done, color: Color(.tertiaryLabel))
            .font(font)
            .lineSpacing(lineSpacing ?? self.lineSpacing)
            .textRenderer(InlineCodeRenderer())
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Headings step down from 20 pt to the body's 16, all semibold: on a
    /// phone, size marks only the top two levels and weight does the rest.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .callout.weight(.semibold)
        }
    }
}

/// A fenced code block: its language and a copy button above the code,
/// colored when the language is known. Code scrolls sideways rather than
/// wrapping, so its lines stay lines; a long block shows its start until
/// asked for the rest.
struct MarkdownCodeBlock: View {
    let code: AttributedString
    let language: String?

    @State private var expanded = false
    @State private var copied = false
    @ScaledMetric(relativeTo: .footnote) private var lineSpacing: CGFloat = 6

    /// Blocks longer than this fold to `foldedLines`.
    static let foldsAbove = 15
    static let foldedLines = 10

    var body: some View {
        let text = String(code.characters)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let folded = lines > Self.foldsAbove && !expanded
        VStack(alignment: .leading, spacing: 0) {
            header(copying: text)
            Divider()
            ScrollView(.horizontal) {
                Text(folded ? Self.prefix(of: code, lines: Self.foldedLines) : code)
                    .font(.footnote.monospaced())
                    .lineSpacing(lineSpacing)
                    .fixedSize()
                    .padding(12)
            }
            .mask {
                LinearGradient(stops: [.init(color: .black, location: folded ? 0.6 : 1),
                                       .init(color: .black.opacity(folded ? 0.1 : 1), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            if lines > Self.foldsAbove {
                Divider()
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Show Less" : "Show All (\(lines) Lines)")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10, style: .continuous))
    }

    private func header(copying text: String) -> some View {
        HStack {
            Text(verbatim: language ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                UIPasteboard.general.string = text
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    // The row is shorter than a touch target; the button is not.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .sensoryFeedback(.success, trigger: copied) { _, new in new }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 34)
    }

    /// The first `lines` lines of the code, colors kept.
    static func prefix(of code: AttributedString, lines: Int) -> AttributedString {
        var seen = 0
        var index = code.startIndex
        while index < code.endIndex {
            if code.characters[index] == "\n" {
                seen += 1
                if seen == lines { return AttributedString(code[code.startIndex..<index]) }
            }
            index = code.characters.index(after: index)
        }
        return code
    }
}

enum MarkdownStyle {
    /// Inline code's color. The monospaced design has no CJK glyphs, so in a
    /// Chinese reply the font alone would not set code apart.
    static let codeTint = Color(light: 0x8A4F62, dark: 0xD2A7B5)
    /// Space either side of inline code, inside its box.
    static let codeInset: CGFloat = 3

    /// Whether a run is inline code drawn in `codeTint`; code in a link keeps the link's color.
    static func isTintedCode(_ run: AttributedString.Runs.Run?) -> Bool {
        guard let run, run.inlinePresentationIntent?.contains(.code) == true else { return false }
        return run.link == nil
    }

    /// Strong text in a real bold weight and inline code in `code`, tinted.
    /// `Text` draws the strong intent only semibold, which barely shows in Chinese.
    static func styled(_ content: AttributedString, in font: Font, code codeFont: Font? = nil) -> AttributedString {
        typealias ForegroundColor = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
        typealias Kern = AttributeScopes.SwiftUIAttributes.KerningAttribute
        var result = content
        var previous: AttributedString.Runs.Run?
        for run in content.runs {
            defer { previous = run }
            guard var intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.stronglyEmphasized) {
                intent.remove(.stronglyEmphasized)
                result[run.range].inlinePresentationIntent = intent.isEmpty ? nil : intent
                result[run.range].font = font.weight(.bold)
            }
            guard intent.contains(.code) else { continue }
            result[run.range].font = codeFont ?? font.monospaced()
            if isTintedCode(run), run[ForegroundColor.self] == nil {
                result[run.range][ForegroundColor.self] = codeTint
            }
            // Room for the box: after the code's last character, and after
            // the character before it, unless the code starts a line.
            let last = content.index(beforeCharacter: run.range.upperBound)
            result[last..<run.range.upperBound][Kern.self] = codeInset + 1
            if let previous, previous.inlinePresentationIntent?.contains(.code) != true {
                let before = content.index(beforeCharacter: run.range.lowerBound)
                if content.characters[before] != "\n" {
                    result[before..<run.range.lowerBound][Kern.self] = codeInset + 1
                }
            }
        }
        return result
    }

    /// The content as one `Text`, its inline code marked for `InlineCodeRenderer`.
    static func text(_ content: AttributedString, in font: Font, code codeFont: Font? = nil) -> Text {
        let styled = styled(content, in: font, code: codeFont)
        var result: Text?
        var segment = AttributedString()
        var segmentIsCode = false
        func close() {
            guard !segment.characters.isEmpty else { return }
            let text = segmentIsCode ? Text(segment).customAttribute(InlineCode()) : Text(segment)
            result = result.map { $0 + text } ?? text
            segment = AttributedString()
        }
        for run in styled.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            if isCode != segmentIsCode {
                close()
                segmentIsCode = isCode
            }
            segment.append(styled[run.range])
        }
        close()
        return result ?? Text(styled)
    }
}

/// Marks the inline code in a `Text` for `InlineCodeRenderer`.
struct InlineCode: TextAttribute {}

/// Draws a rounded box behind each stretch of inline code on a line, then
/// the text. `Text` can color a run's background, but only edge to edge
/// with square corners, which reads as a highlight rather than code.
struct InlineCodeRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var boxes: [CGRect] = []
        for line in layout {
            var box: CGRect?
            for run in line {
                if run[InlineCode.self] != nil {
                    let rect = run.typographicBounds.rect
                    box = box.map { $0.union(rect) } ?? rect
                } else if let done = box {
                    boxes.append(done)
                    box = nil
                }
            }
            if let box { boxes.append(box) }
        }
        let inset = MarkdownStyle.codeInset
        for box in boxes {
            // The kern after the last character is inside the run; leave a point
            // of it outside. Code that starts a line keeps to the text's margin.
            let left = max(0, box.minX - inset)
            let rect = CGRect(x: left, y: box.minY - 1, width: box.maxX - 1 - left, height: box.height + 2)
            context.fill(Path(roundedRect: rect, cornerRadius: 4, style: .continuous),
                         with: .color(Color(.quaternarySystemFill)))
        }
        for line in layout { context.draw(line) }
    }
}

/// A table as columns that keep their widths across rows. A narrow table
/// fits the phone with its cells wrapping; a wide one scrolls sideways.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    @ScaledMetric(relativeTo: .subheadline) private var minimumColumnWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .subheadline) private var cellSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var codeSize: CGFloat = 12.5

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
        // A size below the reply's text, the header smaller still and gray.
        let font: Font = header ? .footnote.weight(.semibold) : .system(size: cellSize)
        let alignment = table.columns[column]
        return MarkdownStyle.text(table.rows[row][column], in: font,
                                  code: .system(size: codeSize, design: .monospaced))
            .font(font)
            .foregroundStyle(header ? .secondary : .primary)
            .lineSpacing(3)
            .textRenderer(InlineCodeRenderer())
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignment == .center ? .top : alignment == .trailing ? .topTrailing : .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // Every other body row shaded, so a wide row is easy to follow.
            .background(header ? Color(.tertiarySystemFill) : row.isMultiple(of: 2) ? Color(.quaternarySystemFill) : .clear)
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
