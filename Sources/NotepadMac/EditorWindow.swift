import AppKit

/// One document = one window: NSTextView + StatusBar, backed by a plain `EditorDocument` model.
final class EditorWindowController: NSWindowController, NSTextViewDelegate {

    /// Model behind this window. Named `doc` because NSResponder already declares an
    /// optional `document` property that a stored `let document` would clash with.
    let doc: EditorDocument

    lazy var textView: NotepadTextView = makeTextView()
    private(set) var scrollView = NSScrollView(frame: .zero)
    private let toolbar = ToolbarHeader(frame: .zero)
    private let menuBar = MenuHeader()
    private let statusBar = StatusBar(frame: .zero)
    private var highlightWork: DispatchWorkItem?
    private var wordWrapped = true
    private var programmaticEdit = false

    /// default window size (1024x768 content).
    init(document: EditorDocument) {
        self.doc = document
        super.init(window: NSWindow(contentRect: NSRect(x: 300, y: 250, width: 1024, height: 768),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false))
        window?.title = doc.displayName
        window?.contentMinSize = NSSize(width: 360, height: 220)
        window?.delegate = self
        buildContent()
        syncFromDocument()
    }

    required init?(coder: NSCoder) { fatalError("EditorWindowController is not codable") }

    // MARK: - UI construction (programmatic, no nibs)

    private func makeTextView() -> NotepadTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: scrollView.contentSize == .zero
                                       ? NSSize(width: 1024, height: 768) : scrollView.contentSize)
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let frame = NSRect(origin: .zero, size: scrollView.contentSize == .zero
                           ? NSSize(width: 1024, height: 768) : scrollView.contentSize)
        let tv = NotepadTextView(frame: frame, textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.font = NSFont.userFixedPitchFont(ofSize: 13)   // monospace default; Highlighter preserves it per-attribute
        tv.delegate = self
        return tv
    }

    private func buildContent() {
        guard let window = window else { return }
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container

        menuBar.syncViewStates(wordWrap: wordWrapped, whitespace: textView.showWhitespace, indentGuides: textView.showIndentGuides)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.verticalRulerView = LineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        wireToolbar()
        toolbar.syncToggles(wordWrap: wordWrapped, whitespace: textView.showWhitespace, indentGuides: textView.showIndentGuides)

        // Auto Layout (the old frame-based layout let the editor overlap the menu/toolbar).
        // Combined header row: menu strip + quick-action toolbar side by side in one NSStackView.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [menuBar, separator, toolbar])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 8
        // Menus keep their natural width; the toolbar absorbs extra horizontal space.
        toolbar.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        menuBar.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.setClippingResistancePriority(.required, for: .horizontal)
        window.contentMinSize.width = max(window.contentMinSize.width, menuBar.intrinsicContentSize.width + 96)

        for v in [header, scrollView, statusBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            menuBar.heightAnchor.constraint(equalToConstant: MenuHeader.height),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 22),
            toolbar.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
            toolbar.heightAnchor.constraint(equalToConstant: toolbar.preferredHeight),

            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: max(MenuHeader.height, toolbar.preferredHeight)),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBar.height)
        ])
        markEncodingCheckmarks(encodingMenuName)   // initial checkmark in both menus
    }

    // MARK: - Document sync + highlighting

    private func syncFromDocument() {
        programmaticEdit = true
        defer { programmaticEdit = false }
        textView.string = doc.text
        applyHighlightNow()                    // immediate on load (large files are skipped inside Highlighter)
        updateStatusBarMeta()
        refreshCaretStatus()
    }

    func textDidChange(_ notification: Notification) {
        guard !programmaticEdit else { return }
        doc.text = textView.string
        doc.markDirty()
        refreshTitle()
        scheduleHighlight()
        refreshCaretStatus()
        SearchPanel.shared.invalidateResults()   // any edit invalidates stored Find All ranges
    }

    private func scheduleHighlight() {
        let work = DispatchWorkItem { [weak self] in self?.applyHighlightNow() }
        highlightWork?.cancel()
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)   // debounce bursts of typing ( responsiveness)
    }

    private func applyHighlightNow() {
        // Real Highlighter API: `apply(_ language:, to storage:)` — nil for "plain" (skips rules, keeps font).
        let language = doc.languageID.isEmpty || doc.languageID == "plain"
            ? nil : Languages.byID(doc.languageID)
        if let storage = textView.textStorage { Highlighter.apply(language, to: storage) }
    }

    // MARK: - NSTextViewDelegate (user edits + caret/selection changes)

    @objc func textViewDidChange(_ notification: Notification) { textDidChange(notification) }

    // MARK: - StatusBar updates (line/col + encoding/EOL/language)

    private func refreshTitle() {
        window?.title = doc.displayName
        window?.isDocumentEdited = doc.isDirty
    }

    private func updateStatusBarMeta() {
        statusBar.update(encoding: doc.encoding.rawValue)
        statusBar.update(eol: eolShort(doc.eolStyle))
        let name = (doc.languageID == "plain" ? nil : Languages.byID(doc.languageID)?.name) ?? "None"
        statusBar.update(language: name)
    }

    private func eolShort(_ style: EOLStyle) -> String {
        switch style {
        case .windows: return "CRLF"
        case .unix: return "LF"
        case .mac: return "CR"
        }
    }

    private func refreshCaretStatus() {
        if textView.string.isEmpty {
            statusBar.update(line: 1, column: 1, selectionLength: 0, percentScroll: 0)
            return
        }
        let nsText = textView.string as NSString
        let range = textView.selectedRange()
        let location = min(range.location, nsText.length)
        let (line, col) = caretLineCol(nsText, at: location)
        statusBar.update(line: line, column: col, selectionLength: range.length, percentScroll: scrollPercent())
    }

    /// 0...1 position of the viewport within the document (status-bar percentage).
    private func scrollPercent() -> CGFloat {
        guard let clip = textView.enclosingScrollView?.contentView else { return 0 }
        let docHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        guard docHeight > 0, docHeight > clip.bounds.height else { return 1 }
        let scrolled = textView.bounds.origin.y + clip.bounds.height
        return min(max(scrolled / docHeight, 0), 1)
    }

    private func caretLineCol(_ text: NSString, at location: Int) -> (line: Int, col: Int) {
        var line = 1
        for i in 0..<location where text.character(at: i) == 0x0A { line += 1 }   // fine for typical file sizes
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        return (line, location - lineStart + 1)
    }

    func textViewDidChangeSelection(_ notification: Notification) { refreshCaretStatus() }

    // MARK: - Search integration (Find = Cmd+F, Replace = Cmd+H)

    @objc func find(_ sender: Any?) { presentSearchPanel() }

    /// Both commands use one unified Find/Replace panel, so both menu items open the same view.
    @objc func replace(_ sender: Any?) { presentSearchPanel() }

    private func presentSearchPanel() {
        SearchPanel.shared.present(over: textView, document: doc)
    }

    // MARK: - Save (keep the same encoding/EOL; BOM only if one was there)

    @objc func saveDocument(_ sender: Any?) {
        do { try writeAndSave() } catch { NSApp.presentError(error) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        do { try saveAs() } catch { NSApp.presentError(error) }
    }

    @discardableResult
    private func saveAs() throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.fileURL == nil ? "Untitled.txt" : doc.displayName
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try writeAndSave(to: url)
        return true
    }

    /// False means the user canceled choosing a destination; errors propagate to callers.
    @discardableResult
    func writeAndSave() throws -> Bool {
        guard let url = doc.fileURL else { return try saveAs() }
        try writeAndSave(to: url)
        return true
    }

    func writeAndSave(to url: URL) throws {
        doc.text = textView.string
        try doc.saveData.write(to: url, options: .atomic)
        doc.markSaved(at: url)
        refreshTitle()
    }

    // MARK: - Language / encoding selection (menu items route here via the responder chain)

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        doc.languageID = id
        applyHighlightNow()
        updateStatusBarMeta()
    }

    @objc func selectEncoding(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        switch name {
        case "UTF-8": doc.encoding = .utf8
        case "UTF-8-BOM", "UTF-8 with BOM": doc.encoding = .utf8BOM
        case "UTF-16 LE": doc.encoding = .utf16le
        case "UTF-16 BE": doc.encoding = .utf16be
        default: doc.encoding = .ansi
        }
        doc.markDirty()
        refreshTitle()
        updateStatusBarMeta()
        markEncodingCheckmarks(name)   // checkmark follows the active encoding
    }

    /// Menu-item name for the current document encoding (`TextEncoding.rawValue` is "ANSI (Latin-1)", but menus say "ANSI").
    private var encodingMenuName: String {
        switch doc.encoding {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8-BOM"
        case .utf16le: return "UTF-16 LE"
        case .utf16be: return "UTF-16 BE"
        case .ansi: return "ANSI"
        }
    }

    /// Checkmarks the active encoding in both menus (in-window Encoding menu + app Status menu).
    private func markEncodingCheckmarks(_ name: String) {
        menuBar.markEncoding(name)
        for item in NSApp.mainMenu?.items ?? [] {
            guard let sub = item.submenu else { continue }
            for encItem in sub.items where (encItem.representedObject as? String).map({ $0.hasPrefix("UTF") || $0 == "ANSI" }) == true {
                encItem.state = (encItem.title == name) ? .on : .off
            }
        }
    }

    // MARK: - Word wrap (View menu)

    @objc func toggleWordWrap(_ sender: Any? = nil) {
        wordWrapped.toggle()
        applyWordWrap()
        if let item = sender as? NSMenuItem { item.state = wordWrapped ? .on : .off } else { syncWordWrapMenuItem() }
        toolbar.syncToggles(wordWrap: wordWrapped, whitespace: textView.showWhitespace, indentGuides: textView.showIndentGuides)
        menuBar.syncViewStates(wordWrap: wordWrapped, whitespace: textView.showWhitespace, indentGuides: textView.showIndentGuides)
    }

    /// soft wrap: ON wraps at the visible width; OFF lets lines run full-width with a horizontal scroller.
    private func applyWordWrap() {
        guard let container = textView.textContainer else { return }
        if wordWrapped {
            container.widthTracksTextView = true
            container.size = NSSize(width: max(scrollView.contentSize.width, 1), height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = .zero
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.minSize = NSSize(width: max(scrollView.contentSize.width, 1), height: 0)
        }
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.hasHorizontalScroller = !wordWrapped
    }

    /// Keeps the View ▸ Word Wrap checkmark in sync when toggled from the toolbar.
    private func syncWordWrapMenuItem() {
        let wanted = wordWrapped ? NSControl.StateValue.on : .off
        for top in (NSApp.mainMenu?.items ?? []) {
            guard let sub = top.submenu else { continue }
            if let item = sub.items.first(where: { $0.action == #selector(toggleWordWrap(_:)) }) {
                item.state = wanted; return
            }
        }
    }

    // MARK: - Toolbar actions ( quick buttons)

    /// "Save All": writes every dirty document, keeping each one's own encoding/EOL.
    @objc func saveAll(_ sender: Any?) {
        for controller in NSApp.windows.compactMap({ $0.windowController as? EditorWindowController }) where controller.doc.isDirty {
            do { if try !controller.writeAndSave() { return } } catch { NSApp.presentError(error); return }
        }
    }

    @objc func zoomIn(_ sender: Any?)  { setFontPoint((textView.font?.pointSize ?? 13) + 1) }
    @objc func zoomOut(_ sender: Any?) { setFontPoint((textView.font?.pointSize ?? 13) - 1) }
    @objc func resetFontSize(_ sender: Any?) { setFontPoint(13) }

    private func setFontPoint(_ raw: CGFloat) {
        let size = min(max(raw, 8), 48)
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(.font, value: NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size), range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    @objc func toggleWhitespace(_ sender: Any?) {
        textView.showWhitespace.toggle()
        toolbar.syncToggles(wordWrap: wordWrapped, whitespace: textView.showWhitespace, indentGuides: textView.showIndentGuides)
        menuBar.syncViewStates(wordWrap: wordWrapped, whitespace: textView.showWhitespace, indentGuides: textView.showIndentGuides)
    }

    @objc func toggleIndentGuides(_ sender: Any?) {
        textView.showIndentGuides.toggle()
        toolbar.syncToggles(wordWrap: wordWrapped, whitespace: textView.showWhitespace, indentGuides: textView.showIndentGuides)
        menuBar.syncViewStates(wordWrap: wordWrapped, whitespace: textView.showWhitespace, indentGuides: textView.showIndentGuides)
    }

    private func wireToolbar() {
        toolbar.onNew = { NSApp.sendAction(#selector(AppDelegate.newDocument(_:)), to: nil, from: nil) }
        toolbar.onOpen = { NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil) }
        toolbar.onSaveAll = { [weak self] in self?.saveAll(nil) }
        toolbar.onZoomIn = { [weak self] in self?.zoomIn(nil) }
        toolbar.onZoomOut = { [weak self] in self?.zoomOut(nil) }
        toolbar.onResetFont = { [weak self] in self?.resetFontSize(nil) }
        toolbar.onToggleWordWrap = { [weak self] _ in self?.toggleWordWrap() }
        toolbar.onToggleWhitespace = { [weak self] _ in self?.toggleWhitespace(nil) }
        toolbar.onToggleIndentGuides = { [weak self] _ in self?.toggleIndentGuides(nil) }
    }

    // MARK: - Close (prompt to save when dirty)

    @objc func closeDocument(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc func closeAllDocuments(_ sender: Any?) {
        let controllers = NSApp.windows.compactMap { $0.windowController as? EditorWindowController }
        for controller in controllers where !controller.confirmSaveIfDirty() { return }   // Cancel on any one stops the rest
        for controller in controllers { controller.window?.close() }
    }

    func confirmSaveIfDirty() -> Bool {
        do {
            return try confirmSaveIfDirty(choose: {
                let alert = NSAlert()
                alert.messageText = "\"\(doc.displayName)\" has unsaved changes."
                alert.informativeText = "Do you want to save your changes?"
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Don't Save")
                alert.addButton(withTitle: "Cancel")
                return alert.runModal()
            }, save: { try writeAndSave() })
        } catch {
            NSApp.presentError(error)
            return false
        }
    }

    /// Keep the close decision testable without displaying modal dialogs.
    func confirmSaveIfDirty(choose: () -> NSApplication.ModalResponse,
                            save: () throws -> Bool) rethrows -> Bool {
        guard doc.isDirty else { return true }
        switch choose() {
        case .alertFirstButtonReturn: return try save()
        // Keep dirty state until closing actually happens: another window may cancel Close All/Quit.
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

}

extension EditorWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmSaveIfDirty() }
}
