import Foundation
import PDFKit
import CoreGraphics

enum ObsidianSnapshotTests {
    /// Call from any thread; PDF extraction itself is tested on a dedicated worker.
    static func run() throws {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let outcome = ResultBox()
        queue.addOperation { outcome.result = Result { try backgroundTests() } }
        queue.waitUntilAllOperationsAreFinished()
        try outcome.result!.get()
    }
    private final class ResultBox: @unchecked Sendable { var result: Result<Void, Error>? }

    private static func backgroundTests() throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw ShelfError.message("Obsidian snapshot test: " + message) }
        }
        func rejects(_ operation: () throws -> Void) throws {
            do { try operation(); throw Failure.notRejected } catch is Failure { throw Failure.notRejected } catch {}
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chimpread-snapshot-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("source.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(file as CFURL, mediaBox: &mediaBox, nil) else { throw Failure.fixture }
        for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 20, y: 20, width: 10, height: 10)); context.endPDFPage() }
        context.closePDF()
        let document = PDFDocument(url: file)!
        let groupID = UUID().uuidString
        func add(_ type: PDFAnnotationSubtype, page: Int, contents: String?, id: String? = nil) -> PDFAnnotation {
            let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 40, height: 15), forType: type, withProperties: nil)
            annotation.contents = contents
            if let id { annotation.setValue(id, forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup")) }
            document.page(at: page)!.addAnnotation(annotation); return annotation
        }
        _ = add(.highlight, page: 0, contents: nil, id: groupID)
        let native = add(.text, page: 0, contents: "Legacy combined display", id: groupID)
        native.setValue("Exact source quotation", forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadQuote"))
        native.setValue("Reader interpretation", forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadComment"))
        _ = add(.highlight, page: 1, contents: "Imported quotation")
        _ = add(.highlight, page: 1, contents: nil)
        try require(document.write(to: file), "fixture saved")
        let first = try ObsidianSnapshot.read(pdfURL: file)
        try require(first.annotations.count == 3, "native grouping and independent imported annotations")
        let row = first.annotations[0]
        try require(row.id == groupID.lowercased() && row.quote == "Exact source quotation" && row.note == "Reader interpretation", "structured quote/comment and stable group")
        try require(first.annotations[1].id == nil && first.annotations[1].page == 2, "imported page anchor only")
        try require(first.annotations[2].quote.isEmpty && first.annotations[2].note.isEmpty, "empty highlight does not fabricate quotation")
        let second = try ObsidianSnapshot.read(pdfURL: file)
        try require(first.revision == second.revision && first.revision.count == 64, "stable content revision")
        var limits = ObsidianSnapshot.Limits(); limits.fileBytes = 8
        try rejects { _ = try ObsidianSnapshot.read(pdfURL: file, limits: limits) }
        limits = .init(); limits.pages = 1
        try rejects { _ = try ObsidianSnapshot.read(pdfURL: file, limits: limits) }
        limits = .init(); limits.annotations = 1
        try rejects { _ = try ObsidianSnapshot.read(pdfURL: file, limits: limits) }
        limits = .init(); limits.textBytes = 3
        try rejects { _ = try ObsidianSnapshot.read(pdfURL: file, limits: limits) }
        try rejects { _ = try ObsidianSnapshot.read(pdfURL: file, cancelled: { true }) }
        let linked = root.appendingPathComponent("linked.pdf")
        try fm.createSymbolicLink(at: linked, withDestinationURL: file)
        try rejects { _ = try ObsidianSnapshot.read(pdfURL: linked) }
        try fm.removeItem(at: file)
        try rejects { _ = try ObsidianSnapshot.read(pdfURL: file) }
        print("PASS bounded background PDF snapshots, native identities, quote/comment separation and incomplete-read rejection")
    }
    private enum Failure: Error { case notRejected, fixture }
}
