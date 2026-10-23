import AppKit

final class Highlighter {
    static let maxHighlightBytes = 3_000_000 // skip highlighting on very large files

    private static let colors: [TokenRole: NSColor] = [
        .keyword: NSColor(red: 0.05, green: 0.25, blue: 0.95, alpha: 1),   // blue
        .builtin: NSColor(red: 0.55, green: 0.32, blue: 0.0, alpha: 1),    // brown
        .number:  NSColor(red: 1.0,  green: 0.45, blue: 0.0, alpha: 1),    // orange
        .string:  NSColor(red: 0.0,  green: 0.48, blue: 0.0, alpha: 1),    // green
        .comment: NSColor(white: 0.62, alpha: 1)                            // gray
    ]

    /// Re-applies highlighting for the whole document (deterministic reset first).
    static func apply(_ language: LanguageDef?, to storage: NSTextStorage) {
        guard !storage.string.isEmpty else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        var fonts: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: full) { value, range, _ in
            if let font = value as? NSFont {
                fonts.append((range, NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)))
            }
        }
        for (range, font) in fonts { storage.addAttribute(.font, value: font, range: range) }

        guard let lang = language, storage.length <= maxHighlightBytes else { return }

        // Tier 1: keywords / builtins / custom patterns (lowest priority).
        if !lang.keywords.isEmpty {
            color(storage, pattern: wordListPattern(lang.keywords), role: .keyword)
        }
        if !lang.builtins.isEmpty {
            color(storage, pattern: wordListPattern(lang.builtins), role: .builtin)
        }
        for (pattern, role) in lang.customPatterns {
            color(storage, pattern: pattern, role: role, options: [.anchorsMatchLines])
        }

        // Tier 2: numbers.
        let num = "\\b0[xX][0-9a-fA-F]+\\b|\\b\\d[\\d_]*\\.\\d+([eE][-+]?\\d+)?\\b|(?<![\\w.])(\\d[\\d_]*)[lLfFuU]?(?![\\w.])"
        color(storage, pattern: num, role: .number)

        // Tier 3: strings (overwrite any keyword hit inside them).
        for d in lang.stringDelims {
            let q = NSRegularExpression.escapedPattern(for: String(d))
            color(storage, pattern: "\(q)[^\\n]*?(?=\(q)|$)", role: .string)
        }
        if lang.id == "python" { // triple-quoted strings
            for d in ["\"", "'"] {
                let q = NSRegularExpression.escapedPattern(for: String(d))
                color(storage, pattern: "[fFbBrRuUxX]{1,2}\(q)[^\\n]*?(?=\(q)|$)", role: .string)   // f"/r' prefixes ()
                let t = NSRegularExpression.escapedPattern(for: String(repeating: d, count: 3))
                color(storage, pattern: "\(t)[\\s\\S]*?\(t)", role: .string)
            }
        }

        // Tier 4: comments (top priority).
        for prefix in lang.lineCommentPrefixes {
            let p = NSRegularExpression.escapedPattern(for: prefix)
            color(storage, pattern: "\(p)[^\n]*", role: .comment)
        }
        for (open, close) in lang.blockComments {
            let o = NSRegularExpression.escapedPattern(for: open)
            let c = NSRegularExpression.escapedPattern(for: close)
            color(storage, pattern: "\(o)[\\s\\S]*?\(c)", role: .comment)
        }
    }

    // MARK: - internals

    private static func wordListPattern(_ words: Set<String>) -> String {
        "\\b(" + Array(words).sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
    }

    private static func color(_ storage: NSTextStorage, pattern: String, role: TokenRole, options: NSRegularExpression.Options = []) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let baseColor = colors[role] else { return }
        let full = NSRange(location: 0, length: storage.length)
        for m in regex.matches(in: storage.string, options: [], range: full) where m.range.length > 0 {
            apply(role: role, baseColor: baseColor, to: storage, range: m.range)
        }
    }

    private static func apply(role: TokenRole, baseColor: NSColor, to storage: NSTextStorage, range: NSRange) {
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: baseColor]
        if role == .comment { // italicize comments (keep document font family/size)
            let idx = min(range.location, max(storage.length - 1, 0))
            if let f = storage.attribute(.font, at: idx, effectiveRange: nil) as? NSFont {
                attrs[.font] = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
            }
        }
        storage.addAttributes(attrs, range: range)
    }
}
