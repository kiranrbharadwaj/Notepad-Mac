import AppKit

/// Application delegate:  menu bar, window registry, New/Open actions.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strong references to live windows (NSApp does not retain window controllers).
    private var controllers: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        for path in CommandLine.arguments.dropFirst() where !path.hasPrefix("-") {
            openFile(URL(fileURLWithPath: path))
        }
        if controllers.isEmpty { newDocument(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the last window quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Window registry

    private func register(_ controller: EditorWindowController) {
        controllers.append(controller)
    }

    private func unregister(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
    }

    /// Create a window for `doc`, cascade it, and show it.
    private func present(_ doc: EditorDocument, cascadeIndex: Int) {
        let controller = EditorWindowController(document: doc)
        register(controller)
        if let window = controller.window {
            var origin = NSPoint(x: 100, y: 480)
            if let screen = NSScreen.main?.visibleFrame {
                let step = CGFloat(cascadeIndex % 6) * 26
                origin = NSPoint(x: screen.minX + 90 + step,
                                 y: max(screen.minY, screen.maxY - window.frame.height - 70 - step))
            }
            window.setFrameOrigin(origin)
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self, weak controller] _ in
                if let controller { self?.unregister(controller) }
            }
        }
        controller.showWindow(nil)
    }

    // MARK: - File actions (target-nil menu items route here via the responder chain)

    @objc func newDocument(_ sender: Any?) {
        present(EditorDocument(), cascadeIndex: controllers.count)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        for url in panel.urls { openFile(url) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openFile(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers where !controller.confirmSaveIfDirty() { return .terminateCancel }
        return .terminateNow
    }

    private func openFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let doc = EditorDocument()
            guard doc.load(data: data, url: url) else {
                presentError("Could not read \"\(url.lastPathComponent)\" as text.", detail: "The file may be binary.")
                return
            }
            doc.languageID = Languages.forPath(url.path).id
            present(doc, cascadeIndex: controllers.count)
        } catch {
            presentError("Could not open \"\(url.lastPathComponent)\".", detail: error.localizedDescription)
        }
    }

    private func presentError(_ messageText: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = detail
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Menu bar (layout + shortcuts)

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // --- App menu (first slot, as required by macOS) ---
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "NotepadMac")
        appItem.submenu = appMenu
        add(appMenu, "About NotepadMac", nil, "")
        appMenu.addItem(.separator())
        add(appMenu, "Hide NotepadMac", #selector(NSApplication.hide(_:)), "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        add(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        appMenu.addItem(.separator())
        add(appMenu, "Quit NotepadMac", #selector(NSApplication.terminate(_:)), "q")

        // --- File (New / Open / Save / Save As... + Close) ---
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        add(fileMenu, "New", #selector(newDocument(_:)), "n")
        add(fileMenu, "Open...", #selector(openDocument(_:)), "o")
        add(fileMenu, "Close Document", #selector(EditorWindowController.closeDocument(_:)), "w")
        fileMenu.addItem(.separator())
        add(fileMenu, "Save", #selector(EditorWindowController.saveDocument(_:)), "s")
        add(fileMenu, "Save As...", #selector(EditorWindowController.saveDocumentAs(_:)), "S")
        add(fileMenu, "Save All", #selector(EditorWindowController.saveAll(_:)), "")

        // --- Edit (Undo / Redo / Cut-Copy-Paste / Select All) ---
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        add(editMenu, "Undo", Selector(("undo:")), "z")   // routed via responder chain to NSTextView's undo manager
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        add(editMenu, "Cut", #selector(NSText.cut(_:)), "x")
        add(editMenu, "Copy", #selector(NSText.copy(_:)), "c")
        add(editMenu, "Paste", #selector(NSText.paste(_:)), "v")
        editMenu.addItem(.separator())
        add(editMenu, "Select All", #selector(NSText.selectAll(_:)), "a")

        // --- Search (Find / Replace / Go To Line) ---
        let searchItem = NSMenuItem(); mainMenu.addItem(searchItem)
        let searchMenu = NSMenu(title: "Search"); searchItem.submenu = searchMenu
        add(searchMenu, "Find...", #selector(EditorWindowController.find(_:)), "f")
        add(searchMenu, "Replace...", #selector(EditorWindowController.replace(_:)), "h")

        // --- View (Word Wrap / Auto-Complete) ---
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        let wrap = NSMenuItem(title: "Word Wrap", action: #selector(EditorWindowController.toggleWordWrap(_:)), keyEquivalent: "")
        wrap.target = nil; wrap.state = .on
        viewMenu.addItem(wrap)
        let ws = NSMenuItem(title: "Show Whitespace", action: #selector(EditorWindowController.toggleWhitespace(_:)), keyEquivalent: "")
        ws.target = nil; ws.state = .on
        viewMenu.addItem(ws)
        let ig = NSMenuItem(title: "Indent Guides", action: #selector(EditorWindowController.toggleIndentGuides(_:)), keyEquivalent: "")
        ig.target = nil; ig.state = .on
        viewMenu.addItem(ig)

        // --- Language (Language menu — Core / Web groups) ---
        let langItem = NSMenuItem(); mainMenu.addItem(langItem)
        let langMenu = NSMenu(title: "Language"); langItem.submenu = langMenu
        var index = 0
        for group in Languages.groups {
            if index > 0 { langMenu.addItem(.separator()) }
            let groupItem = NSMenuItem(); langMenu.addItem(groupItem)
            let submenu = NSMenu(title: group.name); groupItem.submenu = submenu
            add(submenu, "None", #selector(EditorWindowController.selectLanguage(_:)), "", tag: index, representedObject: 0)
            for language in group.languages {
                add(submenu, language.name, #selector(EditorWindowController.selectLanguage(_:)), "", tag: index, representedObject: language.id)
            }
            index += 1
        }

        // --- Window (Close All / Move to Top ...) + Help ---
        let windowItem = NSMenuItem(); mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        add(windowMenu, "Close All", #selector(EditorWindowController.closeAllDocuments(_:)), "")
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem(); mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help"); helpItem.submenu = helpMenu
        add(helpMenu, "NotepadMac Help", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        NSApp.helpMenu = helpMenu

        // --- Status menu (status bar: Encoding / EOL / Language) ---
        let statusItem = NSMenuItem(); mainMenu.addItem(statusItem)
        let statusMenu = NSMenu(title: "Status"); statusItem.submenu = statusMenu
        langMenu.title = "Language"   // keep group title in sync (no-op guard)
        for encName in ["UTF-8", "UTF-8-BOM", "UTF-16 LE", "UTF-16 BE", "ANSI"] {
            add(statusMenu, encName, #selector(EditorWindowController.selectEncoding(_:)), "", representedObject: encName)
        }
    }

    /// Convenience: create a menu item with target = nil so it routes through the responder chain.
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String,
                     tag: Int = 0, representedObject: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if tag != 0 { item.tag = tag }
        if let object = representedObject { item.representedObject = object }
        menu.addItem(item)
        return item
    }
}
