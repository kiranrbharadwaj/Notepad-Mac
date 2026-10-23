import AppKit
import Foundation

struct FindOptions {
    var caseSensitive = false
    var wholeWord = false
    var useRegex = false
    var wrapAround = true
}

enum SearchError: Error, LocalizedError {
    case invalidPattern
    var errorDescription: String? { "Invalid search pattern" }
}

/// Directional, optional wrap-around search over an NSString.
struct SearchEngine {
    enum Direction { case forward, backward }

    static func matches(_ query: String, options: FindOptions) throws -> NSRegularExpression {
        let body = options.useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        let pattern = options.wholeWord && !options.useRegex ? "\\b\(body)\\b" : body
        guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw SearchError.invalidPattern }
        var opts: NSRegularExpression.Options = []
        if !options.caseSensitive { opts.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: opts)
    }

    /// Find the next match relative to `anchor` (a selection range).
    static func find(_ query: String, in text: NSString, options: FindOptions, direction: Direction, anchor: NSRange) throws -> NSRange? {
        guard !query.isEmpty else { return nil }
        let regex = try matches(query, options: options)
        let all = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))

        switch direction {
        case .forward:
            let start = anchor.length > 0 ? NSMaxRange(anchor) : anchor.location + (anchor.location == 0 && anchor.length == 0 ? 0 : 1)
            if let hit = all.first(where: { $0.range.location >= min(start, text.length) }) { return hit.range }
            guard options.wrapAround else { return nil }
            return all.first?.range  // wrap to beginning (skip match already covered by anchor start..?)

        case .backward:
            let before = anchor.length > 0 ? anchor.location : max(anchor.location - 1, 0)
            if let hit = all.last(where: { $0.range.location < min(before + 1, text.length) && ($0.range.location < (anchor.length > 0 ? anchor.location : anchor.location)) }) { return hit.range }
            guard options.wrapAround else { return nil }
            return all.last?.range
        }
    }

    /// Replace every occurrence; returns count. Caller must be inside `NSTextStorage.replaceCharacters` transaction or begin/endEditing.
    static func replaceAll(_ query: String, replacement: String, in storage: NSTextStorage, options: FindOptions) throws -> Int {
        guard !query.isEmpty else { return 0 }
        let regex = try matches(query, options: options)
        let text = (storage.string as NSString)
        let all = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        storage.beginEditing()
        for m in all.reversed() {
            let replaced = options.useRegex
                ? regex.replacementString(for: m, in: text as String, offset: 0, template: replacement)
                : replacement
            storage.replaceCharacters(in: m.range, with: replaced)
        }
        storage.endEditing()
        return all.count
    }

    /// Count every occurrence in the whole document ("Find All" count).
    static func countAll(_ query: String, in text: NSString, options: FindOptions) throws -> Int {
        guard !query.isEmpty else { return 0 }
        let regex = try matches(query, options: options)
        return regex.numberOfMatches(in: text as String, range: NSRange(location: 0, length: text.length))
    }

    /// One occurrence found by Find All (editor lists these with their line numbers).
    struct Match {
        let range: NSRange
        let line: Int   // 1-based, like editor's results list
    }

    /// Every occurrence in document order. Line numbers are computed lazily per match.
    static func findAll(_ query: String, in text: NSString, options: FindOptions) throws -> [Match] {
        guard !query.isEmpty else { return [] }
        let regex = try matches(query, options: options)
        let all = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        var result: [Match] = []
        result.reserveCapacity(all.count)
        for m in all {
            result.append(Match(range: m.range, line: lineNumber(of: m.range.location, in: text)))
        }
        return result
    }

    /// 1-based line number containing a UTF-16 offset.
    /// EOL-aware like editor: `\r\n` counts as one break; lone `\n` and lone `\r` count too.
    private static func lineNumber(of loc: Int, in text: NSString) -> Int {
        guard loc > 0 else { return 1 }
        var line = 1
        let n = min(loc, text.length)
        var i = 0
        while i < n {
            let ch = text.character(at: i)
            if ch == 0x0D || ch == 0x0A {                       // \r or \n
                line += 1
                if ch == 0x0D && i + 1 < n, text.character(at: i + 1) == 0x0A { i += 2 } else { i += 1 }
            } else {
                i += 1
            }
        }
        return line
    }

    /// preview for the results list: the match's line with a context window
    /// around it, elided (`…`) on either side when the line is long. EOL-aware.
    static func contextSnippet(for range: NSRange, in text: NSString) -> String {
        let n = text.length
        guard n > 0 else { return "" }
        func isEOL(_ i: Int) -> Bool {
            guard i >= 0 && i < n else { return false }
            let c = text.character(at: i)
            return c == 0x0D || c == 0x0A
        }

        // Boundaries of the line containing the match.
        var start = min(max(range.location, 0), n - 1)
        while start > 0 && !isEOL(start - 1) { start -= 1 }
        var end = min(NSMaxRange(range), n)
        while end < n && !isEOL(end) { end += 1 }

        let half: Int = 40   // context characters on each side of the match (UTF-16 units ≈ chars for ASCII)
        let lo = max(start, range.location - half)
        let hi = min(end, NSMaxRange(range) + half)
        var snippet = text.substring(with: NSRange(location: lo, length: hi - lo))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lo > start { snippet = "…" + snippet }
        if hi < end { snippet = snippet + "…" }
        return snippet
    }

    /// Replace one occurrence (the range found by `find`).
    static func replaceOne(_ query: String, replacement: String, in storage: NSTextStorage, options: FindOptions, at range: NSRange) throws {
        guard !query.isEmpty else { return }
        let regex = try matches(query, options: options)
        let text = storage.string
        guard let match = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .first(where: { $0.range == range }) else { return }
        let value = options.useRegex
            ? regex.replacementString(for: match, in: text, offset: 0, template: replacement)
            : replacement
        storage.replaceCharacters(in: range, with: value)
    }
}
