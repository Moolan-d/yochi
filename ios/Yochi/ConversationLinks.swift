import SwiftUI

/// Links in an Agent's reply: web addresses open in the browser, and a path
/// the session changed opens its diff on the Changes page.
enum ConversationLinks {
    static let changeScheme = "yochi-change"

    static func changeURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = changeScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// The changed file a `yochi-change` link names.
    static func changedPath(from url: URL) -> String? {
        guard url.scheme == changeScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
    }

    static func isWeb(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    /// The changed file (a path from the repository root) that `mention`
    /// points at: the same path, or an absolute one ending in it. The longest
    /// wins, so `a/b/x.swift` isn't taken for `x.swift`.
    static func changedPath(matching mention: String, in changed: [String]) -> String? {
        var mention = mention
        if mention.hasPrefix("./") { mention.removeFirst(2) }
        return changed.filter { mention == $0 || mention.hasSuffix("/" + $0) }.max { $0.count < $1.count }
    }

    private static func isPathCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "_./~-+@".contains(c)
    }

    /// Where `text` names a changed file, each with the changed path: the
    /// path as written (relative, or with its absolute prefix), without a
    /// trailing `:line`. A match must not sit inside a longer name.
    static func pathRanges(in text: String, changed: [String]) -> [(range: Range<String.Index>, path: String)] {
        var found: [(range: Range<String.Index>, path: String)] = []
        for path in changed.sorted(by: { $0.count > $1.count }) where !path.isEmpty && text.contains(path) {
            var from = text.startIndex
            while let hit = text.range(of: path, range: from..<text.endIndex) {
                from = hit.upperBound
                if hit.upperBound < text.endIndex, isPathCharacter(text[hit.upperBound]),
                   !(text[hit.upperBound] == ":" || text[hit.upperBound] == ".") { continue }
                // A following `.` is a sentence's end, not part of a name,
                // unless more name follows it.
                if hit.upperBound < text.endIndex, text[hit.upperBound] == ".",
                   let next = text.index(hit.upperBound, offsetBy: 1, limitedBy: text.endIndex),
                   next < text.endIndex, isPathCharacter(text[next]) { continue }
                var start = hit.lowerBound
                if start > text.startIndex {
                    let before = text[text.index(before: start)]
                    // Inside a name (`xSources/a.swift`), not at its start.
                    if before != "/" && isPathCharacter(before) { continue }
                    // Reach back over the absolute prefix.
                    while start > text.startIndex, isPathCharacter(text[text.index(before: start)]) {
                        start = text.index(before: start)
                    }
                }
                let range = start..<hit.upperBound
                if found.contains(where: { $0.range.overlaps(range) }) { continue }
                found.append((range, path))
            }
        }
        return found
    }

    /// The `http(s)` addresses in `text`, without the punctuation that ends a sentence.
    static func webRanges(in text: String) -> [Range<String.Index>] {
        guard text.contains("http") else { return [] }
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while let hit = text.range(of: #"https?://[^\s<>"'`\]\)]+"#, options: .regularExpression, range: from..<text.endIndex) {
            from = hit.upperBound
            var end = hit.upperBound
            while end > hit.lowerBound, ".,;:!?".contains(text[text.index(before: end)]) { end = text.index(before: end) }
            // Nothing after the scheme: not an address.
            if text.distance(from: hit.lowerBound, to: end) > "https://".count { found.append(hit.lowerBound..<end) }
        }
        return found
    }

    /// `content` with its bare web addresses and the changed paths it names
    /// made links. Links the Markdown already made stay as they are.
    static func linkify(_ content: AttributedString, changed: [String]) -> AttributedString {
        let text = String(content.characters)
        var links: [(Range<String.Index>, URL)] = webRanges(in: text).compactMap { range in
            URL(string: String(text[range])).map { (range, $0) }
        }
        for (range, path) in pathRanges(in: text, changed: changed) {
            if let url = changeURL(path: path) { links.append((range, url)) }
        }
        guard !links.isEmpty else { return content }
        var result = content
        for (range, url) in links {
            let lower = result.characters.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: range.lowerBound))
            let upper = result.characters.index(lower, offsetBy: text.distance(from: range.lowerBound, to: range.upperBound))
            guard result[lower..<upper].runs.allSatisfy({ $0.link == nil }) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

/// The paths the session changed, from the Changes list, for replies to link.
private struct ChangedPathsKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

/// Opens a changed file's diff; nil where there is no Changes page to go to.
private struct OpenChangeKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil
}

extension EnvironmentValues {
    var changedPaths: [String] {
        get { self[ChangedPathsKey.self] }
        set { self[ChangedPathsKey.self] = newValue }
    }

    var openChange: (@MainActor @Sendable (String) -> Void)? {
        get { self[OpenChangeKey.self] }
        set { self[OpenChangeKey.self] = newValue }
    }
}
