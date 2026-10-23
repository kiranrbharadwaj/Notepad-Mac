import AppKit
import Foundation

// Run with `swift run NotepadMac --selftest`
enum SelfTest {
    static func run() -> Bool {
        var pass = true
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "  ok   " : " FAIL ") + name)
            if !cond { pass = false }
        }

        let utf8 = Data("héllo\n".utf8)
        check("utf8 roundtrip", TextEncoding.detect(utf8) == .utf8 && TextEncoding.utf8.decode(utf8) == "héllo\n")

        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)
        check("utf8-bom detect", TextEncoding.detect(bom) == .utf8BOM && TextEncoding.utf8BOM.strippedBOM(bom).count == 1)

        let u16 = "ab".data(using: .utf16LittleEndian)!
        check("utf16le detect", TextEncoding.detect(Data([0xFF, 0xFE]) + u16) == .utf16le
              && TextEncoding.utf16le.decode(TextEncoding.utf16le.strippedBOM(Data([0xFF, 0xFE]) + u16)) == "ab")

        let be = Data([0xFE, 0xFF]) + ("ab".data(using: .utf16BigEndian)!)
        check("utf16be detect", TextEncoding.detect(be) == .utf16be
              && TextEncoding.utf16be.decode(TextEncoding.utf16be.strippedBOM(be)) == "ab")

        let ansi = Data([0x48, 0xE9]) // H + é in Latin-1
        check("ansi decode", TextEncoding.detect(ansi) == .ansi && TextEncoding.ansi.decode(ansi) == "H\u{E9}")

        check("eol windows", EOLStyle.detect(in: "a\r\nb\r\nc") == .windows)
        check("eol unix", EOLStyle.detect(in: "a\nb\nc") == .unix)
        check("eol mac", EOLStyle.detect(in: "a\rb\rc") == .mac)

        let mixed = "a\r\nb\nc\rd"
        check("normalize->crlf", EOLStyle.normalize(mixed, to: .windows) == "a\r\nb\r\nc\r\nd")
        check("normalize->lf", EOLStyle.normalize(mixed, to: .unix) == "a\nb\nc\nd")

        let encoded = [UInt8](TextEncoding.utf8BOM.encode("z"))
        check("bom write", Array(encoded.prefix(3)) == [0xEF, 0xBB, 0xBF])

        // MARK: SearchEngine — Find All line numbers across EOL styles + context preview
        var opts = FindOptions()
        opts.caseSensitive = true
        opts.wrapAround = false
        do {
            let lf = "foo bar foo\nbaz foo" as NSString
            let found = try SearchEngine.findAll("foo", in: lf, options: opts)
            check("findall count (lf)", found.count == 3)
            check("findall lines (lf)", found.map(\.line) == [1, 1, 2])

            let crlf = "one\r\ntwo two\r\nthree" as NSString
            let f2 = try SearchEngine.findAll("two", in: crlf, options: opts)
            check("findall line (crlf)", f2.count == 2 && f2.first?.line == 2)

            // Lone `\r` EOLs must count as breaks (old code only counted `\n`).
            let cr = "alpha\rbeta\rgamma" as NSString
            let f3 = try SearchEngine.findAll("gamma", in: cr, options: opts)
            check("findall line (cr-only)", f3.count == 1 && f3.first?.line == 3)

            // A CRLF pair counts once, not twice.
            let afterCrlf = "a\r\nb" as NSString
            let f4 = try SearchEngine.findAll("b", in: afterCrlf, options: opts)
            check("crlf boundary counted once", f4.first?.line == 2)

            // Long line: preview elides both ends but keeps the match.
            let padL = String(repeating: "x", count: 60), padR = String(repeating: "y", count: 60)
            let longLine = (padL + " needle " + padR) as NSString
            let f5 = try SearchEngine.findAll("needle", in: longLine, options: opts)
            let snippet = SearchEngine.contextSnippet(for: f5[0].range, in: longLine)
            check("snippet elides both ends", snippet.hasPrefix("…") && snippet.hasSuffix("…"))
            check("snippet keeps match", snippet.contains("needle"))

            // Short line: shown intact, no ellipsis.
            let short = "hello world" as NSString
            let f6 = try SearchEngine.findAll("world", in: short, options: opts)
            check("snippet short line intact", SearchEngine.contextSnippet(for: f6[0].range, in: short) == "hello world")

            // Case-insensitive by default: every case variant of the query matches.
            var wordOpts = FindOptions()   // defaults: ignoreCase on, whole-word off
            let ciText = "a cat and a CAT cAt" as NSString
            let f7 = try SearchEngine.findAll("cat", in: ciText, options: wordOpts)
            check("case-insensitive default", f7.count == 3)

            // …and case-sensitive matching honors the flag (only exact-case hit).
            var csOpts = FindOptions()
            csOpts.caseSensitive = true
            let f7b = try SearchEngine.findAll("cat", in: ciText, options: csOpts)
            check("case-sensitive honors flag", f7b.count == 1)

            // Whole-word matching excludes substring hits ("category").
            wordOpts.wholeWord = true
            let f8 = try SearchEngine.findAll("cat", in: ("a cat and a category" as NSString), options: wordOpts)
            check("whole-word excludes substring", f8.count == 1 && (f8.first?.range.location ?? -1) == 2)
        } catch {
            check("search engine no-throw", false)
        }
        // Regression checks for replacement templates, including absent optional groups.
        do {
            var regex = FindOptions()
            regex.useRegex = true
            let storage = NSTextStorage(string: "ab b")
            let count = try SearchEngine.replaceAll("(a)?b", replacement: "<$1>", in: storage, options: regex)
            check("replace all optional captures", count == 2 && storage.string == "<a> <>")
            let single = NSTextStorage(string: "abc 123")
            try SearchEngine.replaceOne("(abc)", replacement: "$1-$0", in: single, options: regex,
                                        at: NSRange(location: 0, length: 3))
            check("replace one expands captures", single.string == "abc-abc 123")
            try SearchEngine.replaceOne("abc", replacement: "bad", in: single, options: regex,
                                        at: NSRange(location: 8, length: 3))
            check("replace one rejects unrelated selection", single.string == "abc-abc 123")
            let literal = NSTextStorage(string: "abc")
            _ = try SearchEngine.replaceAll("abc", replacement: "$1", in: literal, options: FindOptions())
            check("literal replacement preserves dollar", literal.string == "$1")
        } catch { check("replacement regression no-throw", false) }

        // AppKit objects are created without presenting editor windows.
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        let highlighted = NSTextStorage(string: "let x = 1 // comment", attributes: [.font: font])
        Highlighter.apply(Languages.javascript, to: highlighted)
        let keywordFont = highlighted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let commentFont = highlighted.attribute(.font, at: 15, effectiveRange: nil) as? NSFont
        check("highlight preserves font and zoom", keywordFont?.fontName == font.fontName && keywordFont?.pointSize == 19)
        check("highlight italicizes comments", commentFont.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true)
        Highlighter.apply(nil, to: highlighted)
        let resetFont = highlighted.attribute(.font, at: 15, effectiveRange: nil) as? NSFont
        check("plain text clears comment italics", resetFont.map { !NSFontManager.shared.traits(of: $0).contains(.italicFontMask) && $0.pointSize == 19 } == true)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let doc = EditorDocument()
            let controller = EditorWindowController(document: doc)
            controller.textView.string = "edited\ntext"
            controller.textDidChange(Notification(name: NSText.didChangeNotification))
            check("editing syncs document and dirty state", doc.text == "edited\ntext" && doc.isDirty)
            let file = directory.appendingPathComponent("sample.txt")
            try controller.writeAndSave(to: file)
            let written = try String(contentsOf: file, encoding: .utf8)
            check("save writes current text and EOL", written == "edited\r\ntext")
            check("successful save clears dirty state", !doc.isDirty && doc.fileURL == file)
            controller.textView.string = "newest text"
            doc.markDirty()
            _ = try controller.writeAndSave()
            check("repeat save reads live editor", try String(contentsOf: file, encoding: .utf8) == "newest text")
            doc.markDirty()
            check("cancel Save As prevents closing", !controller.confirmSaveIfDirty(choose: { .alertFirstButtonReturn }, save: { false }) && doc.isDirty)
            check("cancel close preserves edits", !controller.confirmSaveIfDirty(choose: { .alertThirdButtonReturn }, save: { true }) && doc.isDirty)
            check("discard decision preserves dirty state until close", controller.confirmSaveIfDirty(choose: { .alertSecondButtonReturn }, save: { false }) && doc.isDirty)
            check("successful save permits closing", controller.confirmSaveIfDirty(choose: { .alertFirstButtonReturn }, save: { true }))
            do {
                try controller.writeAndSave(to: directory.appendingPathComponent("missing/file.txt"))
                check("failed save throws", false)
            } catch {
                check("failed save preserves dirty state and path", doc.isDirty && doc.fileURL == file)
            }
        } catch { check("save regression no-throw", false) }
        return pass
    }
}
