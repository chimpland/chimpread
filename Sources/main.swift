import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var store: ShelfStore!
    let reader = Reader()
    var organizationTimer: Timer?
    var integrationsWindow: NSWindow?
    var migrationWindow: NSWindow?
    var bibliographyWindow: NSWindow?
    var browserTimer: Timer?
    var cloud: CloudController!
    var cloudWindow: NSWindow?
    private var pendingSourceURLs: [URL] = []
    private var sourceRequest = UUID()
    func application(_ application: NSApplication, open urls: [URL]) {
        guard store != nil else { pendingSourceURLs = Array(urls.prefix(1)); return }
        if let url = urls.first { openSourceURL(url) }
    }
    private func openSourceURL(_ url: URL) {
        guard let target = ObsidianLinks.parse(url),
              let paper = store.library.papers.first(where: { $0.id == target.paperID }) else {
            sourceAlert("This paper link is unavailable in the current library."); return
        }
        if let libraryID = target.libraryID, (try? ObsidianLibraryIdentity.id(root: store.root)) != libraryID {
            sourceAlert("This link belongs to another Chimpread library."); return
        }
        guard reader.save() else { sourceAlert(reader.error ?? "Could not save the open paper."); return }
        let request = UUID(); sourceRequest = request
        let base = store.files.resolvingSymlinksInPath()
        let file = base.appendingPathComponent(paper.filename).resolvingSymlinksInPath()
        guard !paper.hasPDF || file.deletingLastPathComponent() == base else { sourceAlert("The source is outside this library."); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let matches = target.revision.map { expected in (try? Importer.hash(file)) == expected } ?? true
            DispatchQueue.main.async {
                guard let self, self.sourceRequest == request else { return }
                guard self.reader.open(paper, in: self.store.files) else { self.sourceAlert(self.reader.error ?? "The PDF could not be opened."); return }
                self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                guard matches else { self.sourceAlert("The PDF changed since this link was saved. The paper is open, but the old passage has not been verified."); return }
                if let annotationID = target.annotationID, let row = self.reader.annotations.first(where: { $0.id.lowercased() == annotationID.lowercased() }) {
                    self.reader.jump(row); return
                }
                if let page = target.page {
                    guard let document = self.reader.view.document, page <= document.pageCount, let destination = document.page(at: page - 1) else {
                        self.sourceAlert("This page is no longer available. The paper is open."); return
                    }
                    self.reader.view.go(to: destination)
                }
                if target.annotationID != nil { self.reader.status = "The annotation changed; opened its source page." }
            }
        }
    }
    private func sourceAlert(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Paper link"; alert.informativeText = text; alert.addButton(withTitle: "OK"); alert.runModal()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let iconURL = Bundle.main.url(forResource: iconName, withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        let arguments = CommandLine.arguments
        let root: URL? = arguments.firstIndex(of: "--library").flatMap { index in
            index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1], isDirectory: true) : nil
        }
        store = ShelfStore(root: root)
        cloud = CloudController(store: store, reader: reader)
        store.refreshOrganization()
        organizationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.store.refreshOrganization() }
        }
        organizationTimer?.tolerance = 15
        browserTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.processBrowserInbox() }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "chimpread"
        window.minSize = NSSize(width: 850, height: 550)
        let toolbar = NSToolbar(identifier: "PaperShelf.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ShelfView(store: store, reader: reader))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if arguments.contains("--demo"), let first = store.library.papers.first { _ = reader.open(first, in: store.files) }
        else if let recent = store.library.papers.filter({ $0.parentID == nil && $0.archived != true && ($0.lastOpened != nil || ($0.priority ?? 0) > 0) }).sorted(by: {
            if $0.lastOpened != $1.lastOpened { return ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            return ($0.priority ?? 0) > ($1.priority ?? 0)
        }).first { _ = reader.open(recent, in: store.files) }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if store != nil, let url = pendingSourceURLs.first { pendingSourceURLs = []; openSourceURL(url) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.importing == true {
            let alert = NSAlert(); alert.messageText = "An import is still running"; alert.informativeText = "Let it finish before quitting so the imported files can be recorded safely."; alert.runModal()
            return .terminateCancel
        }
        guard reader.save() else {
            let alert = NSAlert(); alert.messageText = "Annotations could not be saved"; alert.informativeText = reader.error ?? "Keep the app open and retry saving."; alert.runModal()
            return .terminateCancel
        }
        reader.rememberPage(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
    @objc func undoEdit() {
        if let text = window?.firstResponder as? NSTextView { text.undoManager?.undo() }
        else { reader.annotationUndo.undo() }
    }
    @objc func redoEdit() {
        if let text = window?.firstResponder as? NSTextView { text.undoManager?.redo() }
        else { reader.annotationUndo.redo() }
    }
    @objc func importFiles() { NotificationCenter.default.post(name: .shelfImport, object: nil) }
    @objc func showCloud() {
        if cloudWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 538, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "iCloud Sync"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: CloudSettings(cloud: cloud)); panel.center(); cloudWindow = panel
        }
        cloudWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showIntegrations() {
        if integrationsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 548, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Integrations"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: IntegrationsView(root: store.root))
            panel.center(); integrationsWindow = panel
        }
        integrationsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showMigration() {
        if migrationWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 598, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Migrate from Zotero"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: MigrationView(store: store)); panel.center(); migrationWindow = panel
        }
        migrationWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showBibliography() {
        if bibliographyWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Bibliography"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: BibliographyView(store: store)); panel.center(); bibliographyWindow = panel
        }
        bibliographyWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.url(forResource: name, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
    @objc func newCollection() { NotificationCenter.default.post(name: .shelfCollection, object: nil) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("import"), .init("collection"), .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("import"), .init("collection")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier.rawValue == "import" {
            item.label = "Import"; item.toolTip = "Import Papers (⌘O)"; item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import Papers"); item.action = #selector(importFiles)
            item.view = NSHostingView(rootView: HStack(spacing: 3) {
                Button { [weak self] in self?.importFiles() } label: {
                    Image(systemName: "square.and.arrow.down")
                }.buttonStyle(.borderless).accessibilityLabel("Import Papers")
                ShortcutHint("⌘O", action: "Import", id: "import")
            }.fixedSize())
        } else if identifier.rawValue == "collection" {
            item.label = "New Collection"; item.toolTip = "New Collection"; item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Collection"); item.action = #selector(newCollection)
        } else { return nil }
        item.target = self; return item
    }
    @objc func save() { NotificationCenter.default.post(name: .shelfSave, object: nil) }
    @objc func printPaper() { reader.printPaper() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(printPaper) { return reader.view.document != nil }
        if menuItem.action == #selector(exportObsidian) { return reader.paperID != nil }
        return true
    }
    @objc func exportPDF() { reader.exportPDF() }
    @objc func exportObsidian() { NotificationCenter.default.post(name: .shelfExportObsidian, object: nil) }
    @objc func chooseObsidian() { NotificationCenter.default.post(name: .shelfChooseObsidian, object: nil) }
    @objc func highlight() { reader.highlight() }
    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Welcome to chimpread"
        alert.informativeText = "Import PDFs with ⌘O or drop them into the paper list. Select text and choose Highlight (⌘L). Use Note (⌘N) for a margin comment; ⌘Return saves it.\n\nRight-click a paper to star it, mark it read, or edit its tags and collections. Click × in the reader to release the open PDF.\n\nFor Zotero: File → Migrate from Zotero imports Zotero RDF exports with files, notes, annotations, and collections. Use File → Bibliography (⌘B) for APA, Nature, BibTeX, or CSL-JSON. Chrome and Google Docs setup is in Integrations (⌘,).\n\nYour local library stays in Application Support/PaperShelf. Optional iCloud Drive sync is in the chimpread menu. Back up the local folder."
        alert.runModal()
    }
}

@MainActor
func makeMenus(_ delegate: AppDelegate) {
    let menu = NSMenu()
    let appItem = NSMenuItem(); let appMenu = NSMenu()
    let about = appMenu.addItem(withTitle: "About chimpread", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
    about.target = delegate
    let integrations = appMenu.addItem(withTitle: "Integrations…", action: #selector(AppDelegate.showIntegrations), keyEquivalent: ","); integrations.target = delegate
    let sync = appMenu.addItem(withTitle: "iCloud Sync…", action: #selector(AppDelegate.showCloud), keyEquivalent: ""); sync.target = delegate
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide chimpread", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit chimpread", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu; menu.addItem(appItem)
    let fileItem = NSMenuItem(); fileItem.title = "File"; let file = NSMenu(title: "File")
    let importItem = file.addItem(withTitle: "Import Papers…", action: #selector(AppDelegate.importFiles), keyEquivalent: "o"); importItem.target = delegate
    let migration = file.addItem(withTitle: "Migrate from Zotero…", action: #selector(AppDelegate.showMigration), keyEquivalent: ""); migration.target = delegate
    let bibliography = file.addItem(withTitle: "Bibliography…", action: #selector(AppDelegate.showBibliography), keyEquivalent: "b"); bibliography.target = delegate
    let save = file.addItem(withTitle: "Save Annotations", action: #selector(AppDelegate.save), keyEquivalent: "s"); save.target = delegate
    let export = file.addItem(withTitle: "Export Annotated PDF…", action: #selector(AppDelegate.exportPDF), keyEquivalent: "e"); export.target = delegate; export.keyEquivalentModifierMask = .command
    let obsidian = file.addItem(withTitle: "Open in Obsidian", action: #selector(AppDelegate.exportObsidian), keyEquivalent: "o"); obsidian.target = delegate; obsidian.keyEquivalentModifierMask = [.command, .shift]
    let vault = file.addItem(withTitle: "Choose Obsidian Vault…", action: #selector(AppDelegate.chooseObsidian), keyEquivalent: ""); vault.target = delegate
    let printItem = file.addItem(withTitle: "Print…", action: #selector(AppDelegate.printPaper), keyEquivalent: "p"); printItem.target = delegate
    file.addItem(.separator()); file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = file; menu.addItem(fileItem)
    let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
    let undo = edit.addItem(withTitle: "Undo", action: #selector(AppDelegate.undoEdit), keyEquivalent: "z"); undo.target = delegate
    let redo = edit.addItem(withTitle: "Redo", action: #selector(AppDelegate.redoEdit), keyEquivalent: "Z"); redo.keyEquivalentModifierMask = [.command, .shift]; redo.target = delegate
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit; menu.addItem(editItem)
    let helpItem = NSMenuItem(); let help = NSMenu(title: "Help")
    let helpEntry = help.addItem(withTitle: "Using chimpread", action: #selector(AppDelegate.showHelp), keyEquivalent: "/"); helpEntry.target = delegate
    helpItem.submenu = help; menu.addItem(helpItem)
    NSApp.mainMenu = menu
}

MainActor.assumeIsolated {
if let index = CommandLine.arguments.firstIndex(of: "--preview-zotero"), index + 1 < CommandLine.arguments.count {
    do {
        let plan = try ZoteroRDF.parse(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        let summary: [String: Any] = ["references": plan.items.count, "pdfs": plan.items.reduce(0) { $0 + $1.attachments.count }, "collections": plan.collections, "with_authors": plan.items.filter { !$0.paper.authors.isEmpty }.count, "with_doi": plan.items.filter { !$0.paper.doi.isEmpty }.count, "warnings": plan.warnings]
        print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)); exit(0)
    } catch { fputs("Preview failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--mcp") || CommandLine.arguments.contains("--audit-library") || CommandLine.arguments.contains("--native-host") {
    let args = CommandLine.arguments
    let root = args.firstIndex(of: "--library").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PaperShelf")
    if args.contains("--native-host") { BrowserHost(root: root).run(); exit(0) }
    if args.contains("--audit-library") {
        do { try auditLibrary(root); exit(0) }
        catch { fputs("Audit failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    MCPServer(root: root).run(); exit(0)
}
let app = NSApplication.shared
if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests(); try runConnectorTests(); try runCloudTests(); try runResearchIndexTests(); try runResearchControllerTests(); try runResearchPlanTests(); try runAIProviderTests(); try ObsidianTests.run(); try ObsidianLinksTests.run(); try ObsidianSnapshotTests.run(); try ObsidianArtifactsTests.run(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--obsidian-memory-test") {
    do { try runObsidianMemoryTests(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--memory-test") {
    do { try runMemoryTest(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--research-memory-test") {
    do { try runResearchMemoryTests(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--make-demo"), index + 1 < CommandLine.arguments.count {
    do { try makeDemo(at: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
makeMenus(delegate)
app.run()
}
