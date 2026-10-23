import AppKit

/// Find / Replace panel (single reusable instance, like editor).
final class SearchPanel: NSPanel {
    static let shared = SearchPanel()

    private let queryField = NSSearchField()
    private let replaceField = NSTextField()
    private let caseCheckbox = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wordCheckbox = NSButton(checkboxWithTitle: "Whole Word", target: nil, action: nil)
    private let regexCheckbox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private var statusLabel: NSTextField!

    // MARK: Find All results list ("Find all" — click a row to jump there)
    private let resultsTable = NSTableView()
    private lazy var resultsScroll: NSScrollView = {
        let s = NSScrollView()
        s.documentView = resultsTable
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.borderType = .bezelBorder
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()
    private var resultsHeightConstraint: NSLayoutConstraint!
    private var matches: [SearchEngine.Match] = []
    private var rowTexts: [String] = []

    /// Extra panel height while the results list is expanded. Top edge stays fixed; we grow downward.
    private let resultsExtraHeight: CGFloat = 216
    private var expandedDelta: CGFloat = 0

    weak var textView: NSTextView?
    weak var document: EditorDocument?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 132),
                   styleMask: [.titled, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Find"
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .floating
        buildUI()
    }

    override var canBecomeKey: Bool { true }

    // MARK: - UI construction (programmatic, no nib)

    private func buildUI() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 132))
        contentView = content

        queryField.placeholderString = "Find what"
        replaceField.placeholderString = "Replace with"
        [queryField, replaceField].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let findNextBtn = NSButton(title: "Find Next", target: self, action: #selector(findNext))
        findNextBtn.bezelStyle = .rounded
        findNextBtn.keyEquivalent = "\r" // Return anywhere in panel = next match
        let findPrevBtn = NSButton(title: "Find Prev", target: self, action: #selector(findPrevious))
        findPrevBtn.bezelStyle = .rounded
        let findAllBtn = NSButton(title: "Find All", target: self, action: #selector(findAllAction))
        findAllBtn.bezelStyle = .rounded
        let replaceOneBtn = NSButton(title: "Replace", target: self, action: #selector(replaceCurrent))
        replaceOneBtn.bezelStyle = .rounded
        let replaceAllBtn = NSButton(title: "Replace All", target: self, action: #selector(replaceAllAction))
        replaceAllBtn.bezelStyle = .rounded
        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closePanel))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}" // Escape

        [findNextBtn, findPrevBtn, findAllBtn, replaceOneBtn, replaceAllBtn, closeBtn].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0)
        }

        caseCheckbox.state = .off; wordCheckbox.state = .off; regexCheckbox.state = .off
        let optionsStack = NSStackView(views: [caseCheckbox, wordCheckbox, regexCheckbox])
        optionsStack.orientation = .horizontal
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let findLbl = NSTextField(labelWithString: "Find:")
        let repLbl = NSTextField(labelWithString: "Replace:")
        [findLbl, repLbl].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }

        [queryField, replaceField, optionsStack, statusLabel].forEach { content.addSubview($0) }

        NSLayoutConstraint.activate([
            findLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            findLbl.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            queryField.leadingAnchor.constraint(equalTo: findLbl.trailingAnchor, constant: 8),
            queryField.trailingAnchor.constraint(equalTo: findNextBtn.leadingAnchor, constant: -8),
            queryField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            findNextBtn.trailingAnchor.constraint(equalTo: findPrevBtn.leadingAnchor, constant: -6),
            findPrevBtn.trailingAnchor.constraint(equalTo: findAllBtn.leadingAnchor, constant: -6),
            findAllBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -6),
            closeBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            findNextBtn.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            repLbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            repLbl.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),
            replaceField.leadingAnchor.constraint(equalTo: repLbl.trailingAnchor, constant: 8),
            replaceField.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 10),
            replaceOneBtn.leadingAnchor.constraint(equalTo: findNextBtn.leadingAnchor),
            replaceOneBtn.topAnchor.constraint(equalTo: replaceField.topAnchor),
            replaceAllBtn.leadingAnchor.constraint(equalTo: findPrevBtn.leadingAnchor),
            replaceAllBtn.topAnchor.constraint(equalTo: replaceField.topAnchor),
            optionsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            optionsStack.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),
            optionsStack.topAnchor.constraint(equalTo: replaceField.bottomAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: closeBtn.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: optionsStack.centerYAnchor)
        ])

        // Find All results list — hidden (zero height) until "Find All" produces matches.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        column.title = "Match"
        column.width = 420
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil          // The results list has no header
        resultsTable.rowSizeStyle = .default
        resultsTable.usesAutomaticRowHeights = false
        resultsTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        resultsTable.allowsMultipleSelection = false
        resultsTable.target = self
        resultsTable.doubleAction = #selector(selectResultLine)
        resultsTable.delegate = self
        resultsTable.dataSource = self      // required — table is view-based and row-backed; without it the list renders empty
        // Row click → jump to occurrence (delegate, extension below)
        resultsScroll.isHidden = true
        content.addSubview(resultsScroll)

        resultsHeightConstraint = resultsScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            resultsScroll.leadingAnchor.constraint(equalTo: findLbl.leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: closeBtn.trailingAnchor),
            resultsScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            resultsHeightConstraint
        ])
    }

    /// Grow/shrink the panel for the results list, keeping its top edge fixed.
    private func setResultsExpanded(_ expand: Bool) {
        let delta: CGFloat = expand ? resultsExtraHeight : 0
        guard delta != expandedDelta else { return }
        var f = frame
        let d = delta - expandedDelta
        f.size.height += d
        f.origin.y -= d          // keep top edge fixed; grow downward
        expandedDelta = delta
        setFrame(f, display: true)
        resultsHeightConstraint.constant = delta
        resultsScroll.isHidden = !expand
    }

    private func clearResults() {
        matches.removeAll()
        rowTexts.removeAll()
        resultsTable.reloadData()
        setResultsExpanded(false)
    }

    // MARK: - lifecycle

    func present(over textView: NSTextView, document: EditorDocument?) {
        self.textView = textView
        self.document = document
        statusLabel.stringValue = ""
        clearResults()
        if let window = textView.window {
            setFrameOrigin(NSPoint(x: window.frame.minX + 60, y: window.frame.maxY - 170))
        }
        makeKeyAndOrderFront(nil)
        // Pre-fill with current selection.
        let sel = textView.selectedRange()
        if sel.length > 0 { queryField.stringValue = (textView.string as NSString).substring(with: sel) }
        selectAllInQuery()
    }

    private func selectAllInQuery() {
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.queryField else { return }
            field.selectText(NSRange(location: 0, length: (field.stringValue as NSString).length))
        }
    }

    // MARK: - actions

    private var options: FindOptions {
        FindOptions(caseSensitive: caseCheckbox.state == .on,
                    wholeWord: wordCheckbox.state == .on,
                    useRegex: regexCheckbox.state == .on)
    }

    @objc func findNext() { _ = perform(.forward) }
    @objc func findPrevious() { _ = perform(.backward) }

    /// "Find All": list every occurrence with its line number; click a row to jump there.
    @objc func findAllAction() {
        guard let tv = textView, !queryField.stringValue.isEmpty else { return }
        do {
            let all = try SearchEngine.findAll(queryField.stringValue, in: tv.string as NSString, options: options)
            matches = all   // keep every hit — no cap; rowTexts is precomputed so rows stay cheap
            rowTexts = matches.map { "L\($0.line): \(Self.lineSnippet(for: $0.range, in: tv.string as NSString))" }
            resultsTable.reloadData()
            setResultsExpanded(true)
            statusLabel.stringValue = "\(all.count) occurrence\(all.count == 1 ? "" : "s") found"
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    /// Context around the match (). Long lines are shown as a window centered on the hit, so one giant line can't produce an unreadable row.
    private static func lineSnippet(for range: NSRange, in text: NSString) -> String {
        let n = text.length
        guard n > 0 else { return "" }

        // Line bounds — \n, \r\n and a lone \r all count as EOL.
        var start = min(range.location, n - 1)
        while start > 0 { let c = text.character(at: start - 1); if c == 10 || c == 13 { break }; start -= 1 }
        var end = min(NSMaxRange(range), n)
        while end < n { let c = text.character(at: end); if c == 10 || c == 13 { break }; end += 1 }

        let maxLen = 80   // keep table rows readable ()
        var lo = start, hi = end
        if hi - lo > maxLen {
            // Window covering the match; prefer keeping the hit visible.
            lo = max(start, min(range.location - 24, hi - maxLen))
            hi = min(end, lo + maxLen)
            // If we started mid-word, cut just after the next space (only if that boundary is before the hit).
            if lo > start {
                var p = lo
                while p < hi && text.character(at: p) != 32 && (p - lo) <= 16 { p += 1 }
                if p < hi && p <= range.location { lo = p + 1 }
            }
        }

        let s = text.substring(with: NSRange(location: lo, length: hi - lo))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > maxLen ? String(s.prefix(maxLen - 1)) + "…" : s
    }

    private func perform(_ direction: SearchEngine.Direction) -> Bool {
        guard let tv = textView, !queryField.stringValue.isEmpty else { return false }
        do {
            if let range = try SearchEngine.find(queryField.stringValue, in: tv.string as NSString, options: options, direction: direction, anchor: tv.selectedRange()) {
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
                statusLabel.stringValue = "Found"
                return true
            } else {
                NSSound.beep()
                statusLabel.stringValue = "Nothing found"
                return false
            }
        } catch {
            statusLabel.stringValue = error.localizedDescription
            NSSound.beep()
            return false
        }
    }

    @objc func replaceCurrent() {
        guard let tv = textView else { return }
        do {
            try SearchEngine.replaceOne(queryField.stringValue, replacement: replaceField.stringValue, in: tv.textStorage!, options: options, at: tv.selectedRange())
            tv.didChangeText()
            clearResults()   // stored ranges are now stale after the edit
            _ = perform(.forward) // continue searching after replace
        } catch { statusLabel.stringValue = error.localizedDescription; NSSound.beep() }
    }

    @objc func replaceAllAction() {
        guard let tv = textView else { return }
        do {
            let count = try SearchEngine.replaceAll(queryField.stringValue, replacement: replaceField.stringValue, in: tv.textStorage!, options: options)
            tv.didChangeText()
            clearResults()   // stored ranges are now stale after the edit
            statusLabel.stringValue = "Replaced \(count) occurrence(s)"
        } catch { statusLabel.stringValue = error.localizedDescription; NSSound.beep() }
    }

    @objc func closePanel() { orderOut(nil) }

    /// Called from EditorWindow whenever document text changes — stored Find All locations are now stale, so drop them ().
    func invalidateResults() { clearResults() }
}

// MARK: - Find All results list ( table)

extension SearchPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rowTexts.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < rowTexts.count else { return nil }
        return rowTexts[row]
    }

    @objc private func selectResultLine() {
        guard let tv = textView else { return }
        let row = resultsTable.clickedRow
        guard row >= 0, row < matches.count else { return }
        let text = tv.string as NSString
        let match = matches[row].range
        guard NSMaxRange(match) <= text.length else { return }
        let line = text.lineRange(for: match)
        tv.setSelectedRange(line)
        tv.scrollRangeToVisible(line)
        tv.window?.makeKeyAndOrderFront(nil)
        tv.window?.makeFirstResponder(tv)
    }

    /// Clicking a result row jumps the editor to that occurrence.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = resultsTable.selectedRow
        guard row >= 0, row < matches.count, let tv = textView else { return }
        let range = matches[row].range
        // The stored range is only valid while the text hasn't changed since Find All ran.
        let full = tv.string as NSString
        guard range.location + range.length <= full.length else {
            statusLabel.stringValue = "Results are stale — run Find All again"
            clearResults()   // drop every stored location; they no longer map to the current text
            return
        }
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        statusLabel.stringValue = "Line \(matches[row].line)"
    }
}
