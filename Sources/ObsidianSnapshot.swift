import Foundation
import PDFKit
import CryptoKit

/// Complete or throws. No PDFKit object escapes this off-main, serialized extractor.
enum ObsidianSnapshot {
    struct Value: Sendable {
        var annotations: [ObsidianAnnotation]
        var revision: String
    }
    struct Limits {
        var fileBytes = 128 * 1024 * 1024
        var pages = 2000
        var annotations = 20_000
        var groups = 10_000
        var textBytes = 2 * 1024 * 1024
    }
    private static let lock = NSLock()
    private struct Group {
        var page: Int
        var id: String?
        var quotes: [String] = []
        var notes: [String] = []
    }

    /// Read actual annotation content, never the reader's fallback display label.
    static func content(_ annotation: PDFAnnotation) -> (quote: String, note: String) {
        let rawID = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup")) as? String
        if rawID.flatMap(UUID.init(uuidString:)) != nil,
           let quote = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadQuote")) as? String,
           let comment = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadComment")) as? String {
            return (quote, comment)
        }
        let text = annotation.contents ?? ""
        return annotation.type == "Highlight" ? (text, "") : ("", text)
    }

    static func read(pdfURL: URL, limits: Limits = Limits(), cancelled: () -> Bool = { false }) throws -> Value {
        guard !Thread.isMainThread else { throw ShelfError.message("PDF annotation extraction must run in the background.") }
        lock.lock(); defer { lock.unlock() }
        try check(cancelled)
        guard pdfURL.isFileURL,
              (try FileManager.default.attributesOfItem(atPath: pdfURL.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw ShelfError.message("The saved PDF is unavailable or is not a regular file.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("chimpread-annotations-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw ShelfError.message("Could not create annotation snapshot.") }
        let output = try FileHandle(forWritingTo: temporary)
        let revision: String
        do { revision = try stream(pdfURL, limit: limits.fileBytes, output: output, cancelled: cancelled); try output.close() }
        catch { try? output.close(); throw error }
        let annotations: [ObsidianAnnotation] = try autoreleasepool {
            guard let document = PDFDocument(url: temporary), !document.isLocked, document.pageCount > 0 else {
                throw ShelfError.message("The PDF could not be read; existing exported annotations were kept.")
            }
            guard document.pageCount <= limits.pages else { throw ShelfError.message("The PDF exceeds the annotation page limit.") }
            var groups: [Group] = [], positions: [String: Int] = [:]
            var bytes = 0, count = 0
            for index in 0..<document.pageCount {
                try check(cancelled)
                try autoreleasepool {
                    guard let page = document.page(at: index) else { throw ShelfError.message("A PDF page could not be read.") }
                    let annotations = page.annotations
                    count += annotations.count
                    guard count <= limits.annotations else { throw ShelfError.message("The PDF exceeds the annotation limit.") }
                    for annotation in annotations {
                        try check(cancelled)
                        guard ["Highlight", "Text", "Underline", "StrikeOut", "FreeText"].contains(annotation.type ?? "") else { continue }
                        let rawID = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup")) as? String
                        let id = rawID.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
                        let (quote, note) = content(annotation)
                        bytes += quote.utf8.count + note.utf8.count
                        guard bytes <= limits.textBytes else { throw ShelfError.message("PDF annotations exceed the text limit.") }
                        let slot: Int
                        if let id, let known = positions[id] { slot = known }
                        else {
                            guard groups.count < limits.groups else { throw ShelfError.message("The PDF exceeds the annotation group limit.") }
                            slot = groups.count; groups.append(Group(page: index + 1, id: id))
                            if let id { positions[id] = slot }
                        }
                        if !quote.isEmpty { groups[slot].quotes.append(quote) }
                        if !note.isEmpty { groups[slot].notes.append(note) }
                    }
                }
            }
            return groups.map { ObsidianAnnotation(page: $0.page, quote: $0.quotes.joined(separator: "\n"), note: $0.notes.joined(separator: "\n\n"), id: $0.id) }
        }
        // Refuse stale extraction if the source changed while the temporary copy was read.
        guard try stream(pdfURL, limit: limits.fileBytes, output: nil, cancelled: cancelled) == revision else {
            throw ShelfError.message("The PDF changed during annotation extraction. Try again.")
        }
        return Value(annotations: annotations, revision: revision)
    }

    private static func check(_ cancelled: () -> Bool) throws { if cancelled() { throw CancellationError() } }
    private static func stream(_ url: URL, limit: Int, output: FileHandle?, cancelled: () -> Bool) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256(), bytes = 0
        while true {
            try check(cancelled)
            guard let chunk = try input.read(upToCount: min(1024 * 1024, max(1, limit - bytes + 1))), !chunk.isEmpty else { break }
            bytes += chunk.count
            guard bytes <= limit else { throw ShelfError.message("The PDF exceeds the annotation file-size limit.") }
            hash.update(data: chunk); try output?.write(contentsOf: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
