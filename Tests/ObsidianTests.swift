import Foundation
import PDFKit

enum ObsidianTests {
    @MainActor static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chimpread-obsidian-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ShelfError.message("Obsidian test: " + message) }
        }
        var paper = Paper(title: "Title / with [punctuation] 日本語", filename: "paper.pdf", sourceHash: "")
        paper.notes = "A saved note\n<!-- chimpread:end -->"
        let annotation = ObsidianAnnotation(page: 3, quote: "First line\nSecond line", note: "My annotation")
        let first = try ObsidianExporter.export(paper: paper, vault: root, pdfURL: root.appendingPathComponent("a b.pdf"), annotations: [annotation])
        try require(first.status == .created, "initial export")
        try require(first.url.deletingLastPathComponent().lastPathComponent == "chimpread", "dedicated folder")
        try require(first.obsidianURL?.scheme == "obsidian", "open URL")
        try require(first.obsidianURL?.absoluteString.contains("path=%2F") == true, "encoded absolute path")
        let physicalPath = realpath(first.url.path, nil)!
        let openPath = URLComponents(url: first.obsidianURL!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        try require(openPath == String(cString: physicalPath), "handoff resolves macOS path aliases for registered vaults")
        free(physicalPath)
        let emptyHighlight = PDFAnnotation(bounds: .zero, forType: .highlight, withProperties: nil)
        let emptyRow = AnnotationRow(id: "imported", page: 1, text: "Highlight", annotation: emptyHighlight, members: [emptyHighlight])
        let copiedEmpty = try ObsidianExportController.annotationForCopy(emptyRow)
        try require(copiedEmpty.quote.isEmpty && copiedEmpty.note.isEmpty, "clipboard does not invent a quotation from a display label")
        let comment = PDFAnnotation(bounds: .zero, forType: .text, withProperties: nil)
        comment.contents = "Reader interpretation"
        emptyHighlight.contents = "Source quotation"
        let mixedRow = AnnotationRow(id: "imported", page: 1, text: "Combined display", annotation: comment, members: [comment, emptyHighlight])
        let copiedMixed = try ObsidianExportController.annotationForCopy(mixedRow)
        try require(copiedMixed.quote == "Source quotation" && copiedMixed.note == "Reader interpretation", "clipboard preserves quote/comment distinction")
        let initial = try String(contentsOf: first.url, encoding: .utf8)
        try require(initial.contains("#page=3") && initial.contains("> Second line"), "page and multiline quote")
        let again = try ObsidianExporter.export(paper: paper, vault: root, pdfURL: root.appendingPathComponent("a b.pdf"), annotations: [annotation])
        try require(again.status == .unchanged, "idempotent export including escaped delimiters")
        try ("---\naliases: [My paper]\n---\n" + initial + "\nMy Obsidian edits 🐒\n").write(to: first.url, atomically: true, encoding: .utf8)
        paper.title = "Renamed title"
        let updated = try ObsidianExporter.export(paper: paper, vault: root)
        try require(updated.url == first.url && updated.status == .updated, "stable path on rename")
        let edited = try String(contentsOf: first.url, encoding: .utf8)
        try require(edited.hasSuffix("My Obsidian edits 🐒\n"), "user suffix preserved")
        try require(edited.contains("My annotation"), "unavailable annotations preserve previous snapshot")
        try require(edited.hasPrefix("---\naliases: [My paper]\n---\n"), "user properties preserved")
        try edited.replacingOccurrences(of: "Renamed title", with: "User changed title").write(to: first.url, atomically: true, encoding: .utf8)
        let userVersion = try Data(contentsOf: first.url)
        let conflict = try ObsidianExporter.export(paper: paper, vault: root)
        let conflictAgain = try ObsidianExporter.export(paper: paper, vault: root)
        try require(conflictAgain.url == conflict.url, "identical conflict deduplicated")
        try require(conflict.status == .conflict && conflict.url != first.url, "separate incoming conflict")
        try require(try Data(contentsOf: first.url) == userVersion, "conflict leaves user bytes unchanged")
        try "Existing unrelated note".write(to: first.url, atomically: true, encoding: .utf8)
        let unrelated = try ObsidianExporter.export(paper: paper, vault: root)
        try require(unrelated.status == .conflict, "unrecognized note protected")
        var hostile = Paper(title: "![title](https://example.invalid/title.png)", filename: "hostile.pdf", sourceHash: "")
        let payload = "![remote](https://example.invalid/tracker)\n<img src='https://example.invalid/pixel'>\n<iframe src='https://example.invalid/frame'></iframe>\n![[remote.png]]\n[click](javascript:alert(1))\n&#33;[[encoded]]\n<!-- chimpread:end -->\n```dataviewjs\nfetch('https://example.invalid')\n```\n$math$ #tag"
        hostile.authors = payload; hostile.year = payload; hostile.doi = payload
        hostile.tags = [payload]; hostile.collections = [payload]; hostile.notes = payload
        let hostileExport = try ObsidianExporter.export(paper: hostile, vault: root,
            pdfURL: root.appendingPathComponent("safe local.pdf"),
            annotations: [.init(page: 2, quote: payload, note: payload)])
        let allEscaped = try String(contentsOf: hostileExport.url, encoding: .utf8)
        let escaped = String(allEscaped.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false).last ?? "")
        for syntax in ["![", "<img", "<iframe", "![[", "[click]", "https://example.invalid", "javascript:", "```dataviewjs", "$math$", "&#33;[[encoded]]"] {
            try require(!escaped.contains(syntax), "source syntax is inert: " + syntax)
        }
        try require(escaped.contains("&#33;&#91;remote&#93;&#40;"), "Markdown image encoded")
        try require(escaped.contains("&#60;img src&#61;&#39;"), "HTML tag encoded")
        try require(escaped.contains("&#33;&#91;&#91;remote&#46;png&#93;&#93;"), "Obsidian embed encoded")
        try require(escaped.contains("&#38;&#35;33&#59;"), "pre-encoded entity remains literal")
        try require(!escaped.contains("<!-- chimpread:end -->"), "injected legacy terminator is inert")
        try require(escaped.contains("[Open PDF](<") && escaped.contains("#page=2"), "generated local links remain active")
        let hostileAgain = try ObsidianExporter.export(paper: hostile, vault: root,
            pdfURL: root.appendingPathComponent("safe local.pdf"), annotations: [.init(page: 2, quote: payload, note: payload)])
        try require(hostileAgain.status == .unchanged, "escaped content remains idempotent")
        try fm.removeItem(at: first.url)
        let outside = root.appendingPathComponent("outside.md")
        try "DO NOT CHANGE".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: first.url, withDestinationURL: outside)
        do { _ = try ObsidianExporter.export(paper: paper, vault: root); throw TestFailure.expectedRejection } catch is TestFailure { throw TestFailure.expectedRejection } catch {}
        try require(try String(contentsOf: outside, encoding: .utf8) == "DO NOT CHANGE", "file symlink rejected")
        try fm.removeItem(at: root.appendingPathComponent("chimpread"))
        let other = root.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("chimpread"), withDestinationURL: other)
        do { _ = try ObsidianExporter.export(paper: paper, vault: root); throw TestFailure.expectedRejection } catch is TestFailure { throw TestFailure.expectedRejection } catch {}
        try require(try fm.contentsOfDirectory(atPath: other.path).isEmpty, "folder symlink rejected")
        try fm.removeItem(at: root.appendingPathComponent("chimpread"))
        paper.notes = String(repeating: "x", count: 3 * 1024 * 1024)
        do { _ = try ObsidianExporter.export(paper: paper, vault: root); throw TestFailure.expectedRejection } catch is TestFailure { throw TestFailure.expectedRejection } catch {}
        // Exercise the GUI's export preparation without opening a chooser or any real vault.
        let store = ShelfStore(root: root.appendingPathComponent("snapshot-library"))
        let saved = Paper(title: "Closed annotated paper", filename: "saved.pdf", sourceHash: "")
        let previous = Paper(title: "Draft paper", filename: "previous.pdf", sourceHash: "")
        try fixturePDF(at: store.files.appendingPathComponent(saved.filename), title: saved.title, pages: 1)
        try fixturePDF(at: store.files.appendingPathComponent(previous.filename), title: previous.title, pages: 1)
        let document = PDFDocument(url: store.files.appendingPathComponent(saved.filename))!
        let savedAnnotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 20, height: 20), forType: .text, withProperties: nil)
        savedAnnotation.contents = "Saved annotation from previously closed PDF"
        document.page(at: 0)!.addAnnotation(savedAnnotation)
        try require(document.write(to: store.files.appendingPathComponent(saved.filename)), "write annotation fixture")
        var library = store.library; library.papers = [previous, saved]
        try require(store.commit(library), "save fixture library")
        let reader = Reader()
        try require(reader.open(previous, in: store.files), "open draft paper")
        reader.beginNote(); reader.updateDraft("Unfinished draft stays private")
        let snapshot = try ObsidianExportController.snapshot(paper: saved, store: store, reader: reader)
        try require(snapshot.annotations.count == 1 && snapshot.annotations[0].note.contains("Saved annotation"), "closed PDF annotations read before export")
        try require(!snapshot.annotations.contains { $0.note.contains("Unfinished draft") }, "draft excluded")
        try require(reader.open(previous, in: store.files) && reader.draft?.text == "Unfinished draft stays private", "previous draft restored after export switch")
        try fm.removeItem(at: store.files.appendingPathComponent(saved.filename))
        do { _ = try ObsidianExportController.snapshot(paper: saved, store: store, reader: reader); throw TestFailure.expectedRejection } catch is TestFailure { throw TestFailure.expectedRejection } catch {}
        try moreTests(root: root)
        print("PASS Obsidian export, idempotency, edits, conflicts, links, symlinks, inert source Markdown, complete annotation snapshots and bounded input")
    }
    private static func moreTests(root: URL) throws {
        let fm = FileManager.default
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw ShelfError.message("Obsidian: " + message) } }
        let vault = root.appendingPathComponent("v2-vault"), library = root.appendingPathComponent("v2-library")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        var paper = Paper(title: "Readable title", filename: "", sourceHash: "")
        let first = try ObsidianExporter.export(paper: paper, vault: vault, libraryRoot: library)
        try check(first.url.lastPathComponent.hasPrefix("Readable title"), "readable filename")
        let one = ObsidianAnnotation(page: 1, quote: "Evidence", note: "Meaning", id: UUID().uuidString)
        let complete = try ObsidianExporter.export(paper: paper, vault: vault, libraryRoot: library, coverage: .complete([one]))
        try check(complete.status == .updated, "first complete snapshot adds annotation region")
        let cleared = try ObsidianExporter.export(paper: paper, vault: vault, libraryRoot: library, coverage: .complete([]))
        try check(try !String(contentsOf: cleared.url, encoding: .utf8).contains("Evidence"), "explicit empty removes annotation")
        paper.title = "New title"
        let renamed = try ObsidianExporter.export(paper: paper, vault: vault, libraryRoot: library)
        try check(renamed.url == first.url, "metadata change does not rename file")
        let moved = vault.appendingPathComponent("Moved note.md")
        try fm.moveItem(at: first.url, to: moved)
        try ObsidianExporter.relink(paperID: paper.id, vault: vault, noteURL: moved, libraryRoot: library)
        let linked = try ObsidianExporter.export(paper: paper, vault: vault, libraryRoot: library)
        try check(linked.url == moved, "relinked note updated without duplicate")
        let external = vault.appendingPathComponent("Existing notes.md")
        let human = "---\naliases: [Mine]\n---\n# My ideas\nKeep exactly.\n"
        try human.write(to: external, atomically: true, encoding: .utf8)
        let another = Paper(title: "Attached", filename: "", sourceHash: "")
        let attached = try ObsidianExporter.attach(paper: another, vault: vault, noteURL: external, libraryRoot: library, coverage: .complete([one]))
        try check(try String(contentsOf: attached.url, encoding: .utf8).hasPrefix(human), "attach preserves all original bytes")
        var changed = another; changed.title = "Updated source"
        ObsidianManagedWriter.beforeCommitForTesting = {
            let text = try String(contentsOf: external, encoding: .utf8)
            try (text + "\nConcurrent human edit\n").write(to: external, atomically: true, encoding: .utf8)
        }
        defer { ObsidianManagedWriter.beforeCommitForTesting = nil }
        let raced = try ObsidianExporter.export(paper: changed, vault: vault, libraryRoot: library)
        ObsidianManagedWriter.beforeCommitForTesting = nil
        try check(raced.status == .conflict, "concurrent save detected")
        try check(try String(contentsOf: external, encoding: .utf8).contains("Concurrent human edit"), "concurrent human edit preserved")
        let pdf = root.appendingPathComponent("portable.pdf")
        try Data("synthetic portable bytes".utf8).write(to: pdf)
        let portablePaper = Paper(title: "Portable", filename: "portable.pdf", sourceHash: "")
        let portable = try ObsidianExporter.export(paper: portablePaper, vault: vault, pdfURL: pdf, libraryRoot: library,
            coverage: .complete([one]), options: .init(portablePDF: true))
        let portableText = try String(contentsOf: portable.url, encoding: .utf8)
        try check(portableText.contains("../chimpread/attachments/") && !portableText.contains("file:"), "portable links are relative")
        let again = try ObsidianExporter.export(paper: portablePaper, vault: vault, pdfURL: pdf, libraryRoot: library,
            coverage: .complete([one]), options: .init(portablePDF: true))
        try check(again.status == .unchanged, "portable repeat stable")
    }
    private enum TestFailure: Error { case expectedRejection }
}
