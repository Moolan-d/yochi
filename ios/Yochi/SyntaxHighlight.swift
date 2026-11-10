import SwiftUI

/// Colors a code block's keywords, strings, comments and numbers for the
/// languages Agents write most. It is a scanner, not a parser: it knows each
/// language's comment and string syntax and its keywords, which is what makes
/// code readable at a glance. Unknown languages stay plain.
enum SyntaxHighlight {
    enum Token: Equatable { case keyword, string, comment, number }

    struct Language {
        var keywords: Set<String>
        var lineComment: String?
        var blockComment: (open: String, close: String)?
        /// Characters that open a string, each closed by itself.
        var quotes: Set<Character>
        /// Quotes that open a multi-line string when tripled: `"""`.
        var triple: Set<Character> = []
        /// Whether a backslash escapes the next character in a string.
        var escapes = true
    }

    static func language(named name: String?) -> Language? {
        switch name?.lowercased() {
        case "swift": swift
        case "ts", "tsx", "typescript", "js", "jsx", "javascript", "mjs", "cjs": script
        case "py", "python", "python3": python
        case "rs", "rust": rust
        case "sh", "bash", "zsh", "shell", "console", "shellscript": shell
        default: nil
        }
    }

    /// The code with its tokens colored; plain if the language is unknown.
    static func highlighted(_ code: String, language name: String?) -> AttributedString {
        guard let language = language(named: name) else { return AttributedString(code) }
        var result = AttributedString()
        for (text, token) in tokens(code, in: language) {
            var piece = AttributedString(text)
            if let token { piece.swiftUI.foregroundColor = color(token) }
            result.append(piece)
        }
        return result
    }

    /// The code split into pieces, each with its token or nil for plain text.
    static func tokens(_ code: String, in language: Language) -> [(String, Token?)] {
        let chars = Array(code)
        var out: [(String, Token?)] = []
        var plain = ""
        var i = 0

        func emit(_ token: Token, _ end: Int) {
            if !plain.isEmpty { out.append((plain, nil)); plain = "" }
            out.append((String(chars[i..<end]), token))
            i = end
        }
        func starts(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix)
            guard index + p.count <= chars.count else { return false }
            return Array(chars[index..<index + p.count]) == p
        }
        func find(_ suffix: String, from index: Int) -> Int {
            var j = index
            while j < chars.count {
                if starts(suffix, at: j) { return j + suffix.count }
                j += 1
            }
            return chars.count
        }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < chars.count {
            let c = chars[i]
            if let line = language.lineComment, starts(line, at: i),
               // `#` starts a shell comment only at a word's start, not in `$#` or `a#b`.
               line != "#" || i == 0 || chars[i - 1].isWhitespace {
                var end = i
                while end < chars.count, chars[end] != "\n" { end += 1 }
                emit(.comment, end)
            } else if let block = language.blockComment, starts(block.open, at: i) {
                emit(.comment, find(block.close, from: i + block.open.count))
            } else if language.triple.contains(c), starts(String(repeating: c, count: 3), at: i) {
                emit(.string, find(String(repeating: c, count: 3), from: i + 3))
            } else if language.quotes.contains(c) {
                var end = i + 1
                while end < chars.count {
                    if language.escapes, chars[end] == "\\" { end += 2; continue }
                    if chars[end] == c { end += 1; break }
                    // An unclosed string stops at the line's end, except a template.
                    if chars[end] == "\n", c != "`" { break }
                    end += 1
                }
                emit(.string, min(end, chars.count))
            } else if c.isNumber, i == 0 || !isWord(chars[i - 1]) {
                var end = i + 1
                while end < chars.count, isWord(chars[end]) || chars[end] == "." && end + 1 < chars.count && chars[end + 1].isNumber {
                    end += 1
                }
                emit(.number, end)
            } else if isWord(c), i == 0 || !isWord(chars[i - 1]) {
                var end = i + 1
                while end < chars.count, isWord(chars[end]) { end += 1 }
                let word = String(chars[i..<end])
                if language.keywords.contains(word) {
                    emit(.keyword, end)
                } else {
                    plain += word
                    i = end
                }
            } else {
                plain.append(c)
                i += 1
            }
        }
        if !plain.isEmpty { out.append((plain, nil)) }
        return out
    }

    /// Close to Xcode's default theme, darkened or lightened to read on the
    /// code block's fill in both appearances.
    static func color(_ token: Token) -> Color {
        switch token {
        case .keyword: Color(light: 0x9B2393, dark: 0xFF7AB2)
        case .string: Color(light: 0xC41A16, dark: 0xFF8170)
        case .comment: Color(light: 0x6C7986, dark: 0x8A99A6)
        case .number: Color(light: 0x1C00CF, dark: 0xD9C97C)
        }
    }

    private static let swift = Language(
        keywords: ["actor", "any", "as", "async", "await", "break", "case", "catch", "class", "continue",
                   "default", "defer", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
                   "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "mutating",
                   "nil", "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "rethrows",
                   "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw",
                   "throws", "true", "try", "typealias", "var", "where", "while"],
        lineComment: "//", blockComment: ("/*", "*/"), quotes: ["\""], triple: ["\""])

    private static let script = Language(
        keywords: ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
                   "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for",
                   "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new",
                   "null", "of", "private", "protected", "public", "readonly", "return", "static", "super",
                   "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void",
                   "while", "yield"],
        lineComment: "//", blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"])

    private static let python = Language(
        keywords: ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
                   "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                   "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "self",
                   "try", "while", "with", "yield"],
        lineComment: "#", quotes: ["\"", "'"], triple: ["\"", "'"])

    private static let rust = Language(
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                   "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
                   "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true",
                   "type", "unsafe", "use", "where", "while"],
        // Not `'`: it starts lifetimes as often as characters.
        lineComment: "//", blockComment: ("/*", "*/"), quotes: ["\""])

    private static let shell = Language(
        keywords: ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
                   "local", "return", "then", "until", "while"],
        lineComment: "#", quotes: ["\"", "'"])
}
