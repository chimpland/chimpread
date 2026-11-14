import AppKit
import Combine
import Foundation
import PDFKit
import CryptoKit
import UniformTypeIdentifiers

/// One worker across windows. There is no vault watcher, polling or model runtime.
private enum ObsidianWork {
    static let queue = DispatchQueue(label: "chimpread.obsidian", qos: .utility)
    static let lock = NSLock()
    static var active = false
    static func begin() -> Bool { lock.lock(); defer { lock.unlock() }; if active { return false }; active = true; return true }
    static func end() { lock.lock(); active = false; lock.unlock() }
}
final class ObsidianCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum ObsidianLibraryIdentity {
    static func id(root: URL) throws -> UUID {
        let file = root.appendingPathComponent("obsidian-library-id.txt")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count < 100, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
                throw ShelfError.message("The library link identity is unreadable. Your papers were not changed.")
            }
            return id
        }
        let id = UUID()
        try Data(id.uuidString.utf8).write(to: file, options: .withoutOverwriting)
        return id
    }
}

@MainActor
final class ObsidianExportController: ObservableObject {
    @Published private(set) var exporting = false
    @Published private(set) var status = ""
    @Published var autoRefresh: Bool { didSet { UserDefaults.standard.set(autoRefresh, forKey: settingsKey + ".refresh") } }
    private let store: ShelfStore
    private let reader: Reader
    private var cancellation: ObsidianCancellation?
    private var refreshTask: DispatchWorkItem?
    private var settingsKey: String { "obsidian." + store.root.path }
    private var vaultKey: String { "obsidian.vault." + store.root.path }

    init(store: ShelfStore, reader: Reader) {
        self.store = store; self.reader = reader
        autoRefresh = UserDefaults.standard.bool(forKey: "obsidian." + store.root.path + ".refresh")
    }
    func cancel() { cancellation?.cancel(); status = "Stopping after the current file…" }
    func chooseVault() {
        guard !exporting else { return }
        if let vault = pickVault() { status = "Using \(vault.lastPathComponent). Nothing exported." }
    }
    private var rememberedVault: URL? {
        guard let path = UserDefaults.standard.string(forKey: vaultKey) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : nil
    }
    private func pickVault() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose your Obsidian vault"
        panel.message = "Paper notes go in a chimpread folder. Your existing notes stay yours."
        panel.prompt = "Use this vault"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        if let path = UserDefaults.standard.string(forKey: vaultKey) { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: vaultKey); return url
    }
    private func destination() -> URL? { rememberedVault ?? pickVault() }

    /// Selects and freezes metadata on the main actor, extracts saved PDF content on the serial worker.
    func export(paper: Paper, open: Bool = true, portable: Bool = false, onlyLinked: Bool = false) {
        guard !exporting, !store.syncing, !store.importing else { return }
        guard let vault = onlyLinked ? rememberedVault : destination() else { return }
        guard let current = store.library.papers.first(where: { $0.id == paper.id }), reader.save() else { return }
        if portable {
            let alert = NSAlert(); alert.messageText = "Include a PDF in this vault?"
            alert.informativeText = "This copies the saved PDF for reading on other devices. Your vault’s sync service may upload it. Existing edited copies are preserved."
            alert.addButton(withTitle: "Include PDF"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let root = store.root, pdf = current.hasPDF ? store.files.appendingPathComponent(current.filename) : nil
        let template = UserDefaults.standard.string(forKey: settingsKey + ".template")
        perform(open: open, quiet: onlyLinked) { token in
            if onlyLinked, try ObsidianExporter.linkedNote(paperID: current.id, vault: vault, libraryRoot: root) == nil { return nil }
            let snapshot = try Self.readSnapshot(pdf, token: token)
            let annotations = snapshot.annotations
            if token.cancelled { throw CancellationError() }
            return try ObsidianExporter.export(paper: current, vault: vault, pdfURL: pdf, annotations: annotations,
                libraryRoot: root, coverage: .complete(annotations), options: .init(portablePDF: portable, creationTemplate: template), sourceRevision: snapshot.revision.isEmpty ? nil : snapshot.revision)
        }
    }

    nonisolated private static func readAnnotations(_ pdf: URL?, token: ObsidianCancellation) throws -> [ObsidianAnnotation] {
        return try readSnapshot(pdf, token: token).annotations
    }
    nonisolated private static func readSnapshot(_ pdf: URL?, token: ObsidianCancellation) throws -> ObsidianSnapshot.Value {
        guard let pdf else { return .init(annotations: [], revision: "") }
        guard ResearchIndexGate.shared.begin() else { throw ShelfError.message("The library is reading PDFs. Try again when that job finishes.") }
        defer { ResearchIndexGate.shared.end() }
        return try ObsidianSnapshot.read(pdfURL: pdf, cancelled: { token.cancelled })
    }

    /// Compatibility entry used by regression tests; production uses bounded worker extraction above.
    static func snapshot(paper: Paper, store: ShelfStore, reader: Reader) throws -> (paper: Paper, pdfURL: URL?, annotations: [ObsidianAnnotation]) {
        guard let current = store.library.papers.first(where: { $0.id == paper.id }) else { throw ShelfError.message("Paper no longer exists.") }
        guard reader.save() else { throw ShelfError.message(reader.error ?? "Could not save the paper.") }
        let pdf = current.hasPDF ? store.files.appendingPathComponent(current.filename) : nil
        let group = DispatchGroup(); group.enter()
        var result: Result<[ObsidianAnnotation], Error>!
        DispatchQueue.global(qos: .utility).async {
            result = Result { try readAnnotations(pdf, token: ObsidianCancellation()) }; group.leave()
        }
        group.wait()
        return (current, pdf, try result.get())
    }

    func scheduleRefresh(paperID: UUID) {
        guard autoRefresh, rememberedVault != nil else { return }
        refreshTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, let paper = self.store.library.papers.first(where: { $0.id == paperID }) else { return }
            self.export(paper: paper, open: false, onlyLinked: true)
        }
        refreshTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    func locate(paper: Paper, attach: Bool = false) {
        guard !exporting, let vault = destination() else { return }
        let panel = NSOpenPanel(); panel.title = attach ? "Connect an existing note" : "Locate this paper’s note"
        panel.message = attach ? "A separate generated section is added. Your writing is preserved." : "Choose the note you moved or renamed."
        panel.allowedContentTypes = [.plainText]; panel.directoryURL = vault
        guard panel.runModal() == .OK, let url = panel.url, url.pathExtension.lowercased() == "md" else { return }
        let root = store.root
        guard let current = store.library.papers.first(where: { $0.id == paper.id }), reader.save() else { return }
        let pdf = current.hasPDF ? store.files.appendingPathComponent(current.filename) : nil
        perform { token in
            if attach {
                let annotations = try Self.readAnnotations(pdf, token: token)
                return try ObsidianExporter.attach(paper: current, vault: vault, noteURL: url, libraryRoot: root, pdfURL: pdf, coverage: .complete(annotations))
            }
            try ObsidianExporter.relink(paperID: current.id, vault: vault, noteURL: url, libraryRoot: root)
            return .init(url: url, status: .unchanged)
        }
    }
    func chooseTemplate() {
        let panel = NSOpenPanel(); panel.title = "Choose a new-note template"
        panel.message = "Optional plain Markdown, used only for new notes. Existing notes never change."
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else { throw ShelfError.message("Choose a UTF-8 template under 64 KiB.") }
            UserDefaults.standard.set(text, forKey: settingsKey + ".template"); status = "Template saved for new notes."
        } catch { showError(error.localizedDescription) }
    }
    func clearTemplate() { UserDefaults.standard.removeObject(forKey: settingsKey + ".template"); status = "Using the simple default note." }

    func copy(paper: Paper, row: AnnotationRow) {
        do {
            let text = ObsidianLinks.copyMarkdown(paper: paper, annotation: try Self.annotationForCopy(row))
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            status = "Copied annotation and source link."
        } catch { showError(error.localizedDescription) }
    }
    static func annotationForCopy(_ row: AnnotationRow) throws -> ObsidianAnnotation {
        guard row.members.count <= 20_000 else { throw ShelfError.message("This annotation has too many parts to copy.") }
        var quotes: [String] = [], notes: [String] = [], bytes = 0
        for member in row.members {
            let content = ObsidianSnapshot.content(member)
            bytes += content.quote.utf8.count + content.note.utf8.count
            guard bytes <= 2 * 1024 * 1024 else { throw ShelfError.message("This annotation is too large to copy.") }
            if !content.quote.isEmpty { quotes.append(content.quote) }
            if !content.note.isEmpty { notes.append(content.note) }
        }
        let native = row.members.compactMap { $0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup")) as? String }.first
        return ObsidianAnnotation(page: row.page, quote: quotes.joined(separator: "\n"),
            note: notes.joined(separator: "\n\n"), id: native)
    }
    func copyPaperLink(_ paper: Paper) {
        let url = ObsidianLinks.paperURL(paperID: paper.id, page: reader.paperID == paper.id ? paper.page + 1 : nil)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        status = "Copied paper link."
    }

    func collection(_ title: String, canvas: Bool = false) {
        guard !exporting, let vault = destination() else { return }
        let papers = store.library.papers.filter { $0.archived != true && $0.collections.contains(title) && $0.parentID == nil }
        guard !papers.isEmpty else { status = "This collection is empty."; return }
        if canvas && papers.count > 20 { showError("Canvas is limited to 20 papers. Use a smaller collection; the reading page supports larger collections."); return }
        let key = settingsKey + ".collection." + title
        let id = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        let root = store.root
        perform { token in
            var links: [UUID: URL] = [:]
            for paper in papers {
                if token.cancelled { throw CancellationError() }
                links[paper.id] = try ObsidianExporter.linkedNote(paperID: paper.id, vault: vault, libraryRoot: root)
            }
            if canvas { return try ObsidianArtifactExporter.canvas(id: id, title: title, papers: papers, edges: [], vault: vault, noteURLs: links) }
            return try ObsidianArtifactExporter.collectionHub(id: id, title: title, papers: papers, vault: vault, noteURLs: links)
        }
    }
    func refreshCollection(_ title: String) {
        guard !exporting, let vault = rememberedVault, reader.save() else { return }
        let papers = store.library.papers.filter { $0.archived != true && $0.collections.contains(title) }
        let root = store.root, files = store.files
        perform(open: false) { token in
            var last: ObsidianExportResult?
            for paper in papers {
                if token.cancelled { throw CancellationError() }
                guard try ObsidianExporter.linkedNote(paperID: paper.id, vault: vault, libraryRoot: root) != nil else { continue }
                let pdf = paper.hasPDF ? files.appendingPathComponent(paper.filename) : nil
                let annotations = try Self.readAnnotations(pdf, token: token)
                last = try ObsidianExporter.export(paper: paper, vault: vault, pdfURL: pdf, annotations: annotations, libraryRoot: root, coverage: .complete(annotations))
                if last?.status == .conflict { return last }
            }
            return last
        }
    }
    func questions(_ title: String) {
        guard !exporting, let vault = destination(), let question = prompt(title: "Save a research question", message: "Add a question to explore. It stays ordinary editable text in Obsidian.") else { return }
        let sources = reader.paperID.map { [ObsidianLinks.paperURL(paperID: $0)] } ?? []
        perform { _ in try ObsidianArtifactExporter.openQuestions(id: UUID(), title: title, questions: [.init(text: question, sourceURLs: sources)], vault: vault) }
    }
    func saveAnswer(_ snapshot: ResearchAnswerSnapshot) {
        let sources = snapshot.sources.enumerated().map { index, hit in
            ObsidianResearchSource(id: String(index + 1), paperID: hit.paperID, title: hit.title, page: hit.page,
                excerpt: hit.text, revision: hit.revision,
                sourceURL: ObsidianLinks.paperURL(paperID: hit.paperID, page: hit.page, revision: hit.revision))
        }
        saveResearchNote(.init(id: snapshot.id, title: snapshot.question, question: snapshot.question, scope: snapshot.scope,
            sources: sources, response: snapshot.answer,
            provenance: .init(provider: snapshot.provider.rawValue, requestedModel: snapshot.requestedModel, reportedModel: snapshot.reportedModel, generatedAt: snapshot.createdAt), createdAt: snapshot.createdAt))
    }
    func saveResearchNote(_ note: ObsidianResearchNote) {
        guard !exporting, let vault = destination() else { return }
        guard let interpretation = prompt(title: "Save research note", message: "Optional: why are you keeping this? The saved note includes the question and source passages. AI text stays labeled as a draft.", allowEmpty: true) else { return }
        let sources = note.sources
        let sourceFiles = Dictionary(uniqueKeysWithValues: store.library.papers.filter { paper in sources.contains { $0.paperID == paper.id } }.map { ($0.id, store.files.appendingPathComponent($0.filename)) })
        var value = note; value.interpretation = interpretation
        perform { token in
            var verified: [ObsidianResearchSource] = []
            var hashes: [UUID: String] = [:]
            for source in sources {
                if token.cancelled { throw CancellationError() }
                guard let url = sourceFiles[source.paperID] else { throw ShelfError.message("A source is no longer in the library. The research note was not written.") }
                let hash = try hashes[source.paperID] ?? Importer.hash(url)
                hashes[source.paperID] = hash
                guard hash == source.revision else { throw ShelfError.message("A source PDF changed. Search again before saving this research note.") }
                var checked = source; checked.revisionVerified = true; verified.append(checked)
            }
            let checked = ObsidianResearchNote(id: value.id, title: value.title, question: value.question, scope: value.scope, sources: verified,
                response: value.response, provenance: value.provenance, interpretation: value.interpretation, reviewedByUser: value.reviewedByUser, createdAt: value.createdAt)
            return try ObsidianArtifactExporter.saveResearchNote(checked, vault: vault)
        }
    }
    private func prompt(title: String, message: String, allowEmpty: Bool = false) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 58)); field.placeholderString = allowEmpty ? "Your interpretation (optional)" : "Your question"
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowEmpty || !text.isEmpty ? text : nil
    }

    private func perform(open: Bool = true, quiet: Bool = false, work: @escaping (ObsidianCancellation) throws -> ObsidianExportResult?) {
        guard !exporting, ObsidianWork.begin() else { status = "An Obsidian job is already running."; return }
        let token = ObsidianCancellation(); cancellation = token; exporting = true; status = "Preparing Obsidian note…"
        ObsidianWork.queue.async { [weak self] in
            let result = Result { try work(token) }; ObsidianWork.end()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.exporting = false; self.cancellation = nil
                switch result {
                case .success(let value):
                    if let value { self.showResult(value, open: open, quiet: quiet) }
                    else { self.status = "No linked notes to update." }
                case .failure(let error):
                    if error is CancellationError { self.status = "Stopped. Completed notes were kept." }
                    else { self.status = error.localizedDescription; if !quiet { self.showError(error.localizedDescription) } }
                }
            }
        }
    }
    private func showResult(_ result: ObsidianExportResult, open: Bool, quiet: Bool) {
        if result.status == .conflict {
            status = "Your edits were kept. An incoming version is ready."
            if !quiet {
                let alert = NSAlert(); alert.messageText = "Your edits were kept"
                alert.informativeText = "The generated section changed in Obsidian. Compare the incoming version before replacing anything."
                alert.addButton(withTitle: "Open incoming version"); alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { openNote(result) }
            }
            return
        }
        status = result.status == .unchanged ? "Obsidian note is up to date." : "Saved to Obsidian."
        if open { openNote(result) }
    }
    private func openNote(_ result: ObsidianExportResult) {
        if let url = result.obsidianURL, NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }
    private func showError(_ message: String) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Obsidian"; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.runModal()
    }
}
