import Foundation
import CryptoKit
import Darwin

struct ObsidianAnnotation: Sendable {
    var page: Int
    var quote: String
    var note: String
    var id: String? = nil
}

enum ObsidianAnnotationCoverage: Sendable {
    case complete([ObsidianAnnotation])
    case unavailable(String)
}

struct ObsidianExportOptions: Sendable {
    var portablePDF = false
    /// User-authored Markdown used only when creating a new note.
    var creationTemplate: String? = nil
}

struct ObsidianExportResult: Sendable {
    enum Status: Sendable { case created, updated, unchanged, conflict }
    var url: URL
    var status: Status
    var obsidianURL: URL? {
        var components = URLComponents()
        components.scheme = "obsidian"; components.host = "open"
        // Foundation preserves macOS aliases such as /tmp, while Obsidian records
        // the physical vault path (/private/tmp). Match the path used by the OS.
        let resolved = realpath(url.path, nil)
        defer { if let resolved { free(resolved) } }
        let path = resolved.map { String(cString: $0) } ?? url.path
        components.percentEncodedQuery = "path=" + (path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        return components.url
    }
}

/// Bounded, explicit file operations. Parent directories are opened one component at
/// a time with O_NOFOLLOW; all final reads/writes are anchored to that directory FD.
/// Coordination and a final byte comparison detect competing changes. This is not
/// a cross-process compare-and-swap guarantee against uncoordinated editors.
enum ObsidianManagedWriter {
    static let limit = 4 * 1024 * 1024
    private static let fm = FileManager.default
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ value: String) -> String { hash(Data(value.utf8)) }
    private static func failure(_ message: String) -> ShelfError { .message(message) }

    static func plain(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if (33...47).contains(code) || (58...64).contains(code) || (91...96).contains(code) || (123...126).contains(code) {
                result += "&#\(code);"
            } else if code < 32 && code != 9 && code != 10 && code != 13 { result += "�" }
            else { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    static func root(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw failure("Choose a local vault folder.") }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let fd = open(resolved.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("The vault folder is unavailable.") }
        close(fd); return resolved
    }

    static func relative(_ url: URL, root: URL) throws -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard url.isFileURL, parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
            throw failure("The selected file must be inside the selected vault.")
        }
        return parts.dropFirst(rootParts.count).joined(separator: "/")
    }

    private static func withParent<T>(_ url: URL, root: URL, create: Bool = false, _ body: (Int32, String) throws -> T) throws -> T {
        let parts = try relative(url, root: root).split(separator: "/").map(String.init)
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot open the export folder safely.") }
        defer { close(fd) }
        for component in parts.dropLast() {
            if create, mkdirat(fd, component, 0o700) != 0, errno != EEXIST { throw failure("Cannot create the export folder.") }
            let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw failure("An export folder is missing, a link, or inaccessible.") }
            close(fd); fd = child
        }
        return try body(fd, parts.last!)
    }

    private static func read(_ parent: Int32, _ name: String) throws -> Data? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw failure("The export file is a link or cannot be opened.")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw failure("The export path is not a regular file.") }
        guard info.st_size <= limit else { throw failure("The note exceeds the 4 MiB limit; it was left unchanged.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= limit {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw failure("Cannot read the export file.") }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw failure("The note grew beyond the 4 MiB limit; it was left unchanged.")
    }

    static func boundedRead(_ url: URL, root: URL) throws -> Data {
        try withParent(url, root: root) { fd, name in
            guard let data = try read(fd, name) else { throw failure("The linked note is missing. Locate it before updating.") }
            return data
        }
    }

    private static func writeNew(_ data: Data, parent: Int32, name: String) throws -> Bool {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 { if errno == EEXIST { return false }; throw failure("Cannot create the export file.") }
        var succeeded = false
        defer { close(fd); if !succeeded { unlinkat(parent, name, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw failure("Cannot write the export file.") }
                guard count > 0 else { throw failure("The export write made no progress.") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure("Cannot finish writing the export file.") }
        succeeded = true; return true
    }

    @discardableResult static func createOnce(destination: URL, root: URL, data: Data) throws -> Bool {
        guard data.count <= limit else { throw failure("The export exceeds 4 MiB.") }
        return try withParent(destination, root: root, create: true) { fd, name in
            if try writeNew(data, parent: fd, name: name) { return true }
            guard try read(fd, name) == data else { throw failure("The destination already contains different or edited content; it was preserved.") }
            return false
        }
    }

    static func section(_ name: String, identity: String, body: String) -> String {
        "<!-- chimpread:v2 \(identity) \(name) sha256=\(hash(body)) -->\n" + body + "<!-- chimpread:end \(identity) \(name) -->"
    }

    private static func token(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func region(_ text: String, identity: String, name: String) -> Range<String.Index>? {
        let start = "<!-- chimpread:v2 \(identity) \(name) sha256=", end = "<!-- chimpread:end \(identity) \(name) -->"
        guard let begin = text.range(of: start), text.range(of: start, range: begin.upperBound..<text.endIndex) == nil,
              let headerEnd = text.range(of: " -->\n", range: begin.upperBound..<text.endIndex),
              let finish = text.range(of: end, range: headerEnd.upperBound..<text.endIndex),
              text.range(of: end, range: finish.upperBound..<text.endIndex) == nil,
              text[begin.upperBound..<headerEnd.lowerBound] == hash(String(text[headerEnd.upperBound..<finish.lowerBound])) else { return nil }
        return begin.lowerBound..<finish.upperBound
    }

    /// Legacy migration preserves human prefix/suffix and retains old annotations
    /// when extraction is unavailable. Only accepts the original verified format.
    private static func legacy(_ text: String, identity: String, sections: [String: String]) -> String? {
        let prefix = "<!-- chimpread:generated sha256=", end = "<!-- chimpread:end -->"
        guard text.components(separatedBy: prefix).count == 2, text.components(separatedBy: end).count == 2,
              let begin = text.range(of: prefix), let header = text.range(of: " -->\n", range: begin.upperBound..<text.endIndex),
              let finish = text.range(of: end, range: header.upperBound..<text.endIndex) else { return nil }
        let body = String(text[header.upperBound..<finish.lowerBound])
        guard text[begin.upperBound..<header.lowerBound] == hash(body), body.contains("Chimpread ID: `\(identity)`") else { return nil }
        var migrated = sections
        if migrated["annotations"] == nil {
            if let annotationStart = body.range(of: "## Annotations\n") {
                let tail = body[annotationStart.lowerBound...]
                let stop = tail.range(of: "---\nExported from chimpread.")?.lowerBound ?? tail.endIndex
                migrated["annotations"] = String(tail[..<stop])
            } else { migrated["annotations"] = "## Annotations\n\nNo previous annotation snapshot.\n\n" }
        }
        let replacement = migrated.keys.sorted().map { section($0, identity: identity, body: migrated[$0]!) }.joined(separator: "\n\n")
        return text.replacingCharacters(in: begin.lowerBound..<finish.upperBound, with: replacement)
    }

    /// Tests inject a competing save at the precise pre-commit boundary. No hook
    /// is configured by the application. Keep calls serialized in tests.
    static var beforeCommitForTesting: (() throws -> Void)?

    static func write(destination: URL, root: URL, identity: String, sections: [String: String],
                      creationPrefix: String, recoveryDirectory: URL? = nil, allowAttach: Bool = false) throws -> ObsidianExportResult {
        guard token(identity), !sections.isEmpty, sections.keys.allSatisfy(token),
              !sections.values.contains(where: { $0.contains("<!-- chimpread:") }) else { throw failure("Invalid managed note identity or section.") }
        let generated = sections.keys.sorted().map { section($0, identity: identity, body: sections[$0]!) }.joined(separator: "\n\n")
        let fresh = creationPrefix + generated + "\n"
        guard fresh.utf8.count <= limit else { throw failure("The formatted note exceeds 4 MiB.") }
        // Ensure parents exist before coordinating a newly created destination.
        try withParent(destination, root: root, create: true) { _, _ in () }
        var outcome: Result<ObsidianExportResult, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [], error: &coordinationError) { coordinated in
            outcome = Result {
                try withParent(coordinated, root: root) { fd, name in
                    func incoming() throws -> ObsidianExportResult {
                        let stem = "\(identity)-incoming-\(hash(fresh).prefix(20))"
                        for attempt in 0..<16 {
                            let file = stem + (attempt == 0 ? "" : "-\(attempt)") + ".md"
                            let data = Data(fresh.utf8)
                            if try writeNew(data, parent: fd, name: file) { return .init(url: coordinated.deletingLastPathComponent().appendingPathComponent(file), status: .conflict) }
                            if try read(fd, file) == data { return .init(url: coordinated.deletingLastPathComponent().appendingPathComponent(file), status: .conflict) }
                        }
                        throw failure("Incoming note names are occupied. Existing files were preserved.")
                    }
                    guard let original = try read(fd, name) else {
                        if try writeNew(Data(fresh.utf8), parent: fd, name: name) { return .init(url: coordinated.standardizedFileURL, status: .created) }
                        return try incoming()
                    }
                    guard let old = String(data: original, encoding: .utf8) else { throw failure("The existing note is not UTF-8; it was preserved.") }
                    var updated = old
                    if !old.contains("<!-- chimpread:v2 ") {
                        if let migrated = legacy(old, identity: identity, sections: sections) { updated = migrated }
                        else if allowAttach && !old.contains("<!-- chimpread:") { updated = old + "\n\n" + generated + "\n" }
                        else { return try incoming() }
                    } else {
                        for key in sections.keys.sorted() {
                            if let range = region(updated, identity: identity, name: key) {
                                updated.replaceSubrange(range, with: section(key, identity: identity, body: sections[key]!))
                            } else if updated.contains("<!-- chimpread:v2 \(identity) "), !updated.contains("<!-- chimpread:v2 \(identity) \(key) ") {
                                updated += "\n\n" + section(key, identity: identity, body: sections[key]!) + "\n"
                            } else { return try incoming() }
                        }
                    }
                    guard updated != old else { return .init(url: coordinated.standardizedFileURL, status: .unchanged) }
                    let bytes = Data(updated.utf8)
                    guard bytes.count <= limit else { throw failure("The updated note exceeds 4 MiB; it was preserved.") }
                    // Keep one bounded pre-update copy locally (or beside the note
                    // for callers without a library). No user files are enumerated.
                    let recovery = recoveryDirectory ?? root.appendingPathComponent("chimpread/.recovery", isDirectory: true)
                    try saveRecovery(original, destination: recovery.appendingPathComponent(identity + ".md"), root: recoveryDirectory == nil ? root : recovery.deletingLastPathComponent())
                    let temporary = ".chimpread-\(UUID().uuidString).tmp"
                    guard try writeNew(bytes, parent: fd, name: temporary) else { throw failure("Cannot reserve the export temporary file.") }
                    defer { unlinkat(fd, temporary, 0) }
                    try beforeCommitForTesting?()
                    guard try read(fd, name) == original else { return try incoming() }
                    guard renameat(fd, temporary, fd, name) == 0 else { throw failure("Could not replace the note; its recovery copy is available.") }
                    return .init(url: coordinated.standardizedFileURL, status: .updated)
                }
            }
        }
        if let outcome { return try outcome.get() }
        throw coordinationError ?? failure("Obsidian export did not complete.")
    }

    private static func saveRecovery(_ data: Data, destination: URL, root: URL) throws {
        try withParent(destination, root: root, create: true) { fd, name in
            // A dedicated single recovery slot per identity bounds disk usage.
            _ = try read(fd, name) // reject links/special files before replacement
            let temp = ".recovery-\(UUID()).tmp"
            guard try writeNew(data, parent: fd, name: temp) else { throw failure("Cannot create a recovery copy.") }
            defer { unlinkat(fd, temp, 0) }
            guard renameat(fd, temp, fd, name) == 0 else { throw failure("Cannot preserve a recovery copy.") }
        }
    }
}

enum ObsidianExporter {
    private struct Receipt: Codable {
        var version = 1
        var paperID: UUID
        var relativePath: String
        var bookmark: Data?
        var pending: Bool
    }
    private static let fm = FileManager.default
    private static func failure(_ message: String) -> ShelfError { .message(message) }
    private static func receiptURL(_ id: UUID, vault: URL, libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent("ObsidianLinks/\(ObsidianManagedWriter.hash(vault.path).prefix(24))/\(id.uuidString.lowercased()).json")
    }
    private static func load(_ id: UUID, vault: URL, libraryRoot: URL) throws -> Receipt? {
        let url = receiptURL(id, vault: vault, libraryRoot: libraryRoot)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try ObsidianManagedWriter.boundedRead(url, root: libraryRoot)
        guard data.count <= 64 * 1024 else { throw failure("The local Obsidian link receipt is too large.") }
        let value = try JSONDecoder().decode(Receipt.self, from: data)
        guard value.version == 1, value.paperID == id else { throw failure("The local Obsidian link receipt is incompatible.") }
        return value
    }
    private static func save(_ value: Receipt, vault: URL, libraryRoot: URL) throws {
        let url = receiptURL(value.paperID, vault: vault, libraryRoot: libraryRoot)
        // Receipt directories contain application state only; no vault enumeration.
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parent = try ObsidianManagedWriter.root(url.deletingLastPathComponent())
        guard parent == url.deletingLastPathComponent().standardizedFileURL else { throw failure("The local receipt folder must not be a symbolic link.") }
        if fm.fileExists(atPath: url.path) { _ = try ObsidianManagedWriter.boundedRead(url, root: libraryRoot) }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    private static func resolved(_ receipt: Receipt, vault: URL) throws -> URL {
        if let bookmark = receipt.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                _ = try ObsidianManagedWriter.relative(url, root: vault)
                _ = try ObsidianManagedWriter.boundedRead(url, root: vault)
                return url.standardizedFileURL
            }
        }
        let url = vault.appendingPathComponent(receipt.relativePath).standardizedFileURL
        _ = try ObsidianManagedWriter.relative(url, root: vault)
        if !receipt.pending { _ = try ObsidianManagedWriter.boundedRead(url, root: vault) }
        return url
    }

    static func linkedNote(paperID: UUID, vault: URL, libraryRoot: URL) throws -> URL? {
        let root = try ObsidianManagedWriter.root(vault)
        guard let receipt = try load(paperID, vault: root, libraryRoot: libraryRoot) else { return nil }
        return try resolved(receipt, vault: root)
    }

    static func relink(paperID: UUID, vault: URL, noteURL: URL, libraryRoot: URL) throws {
        let root = try ObsidianManagedWriter.root(vault)
        let data = try ObsidianManagedWriter.boundedRead(noteURL, root: root)
        guard let text = String(data: data, encoding: .utf8),
              text.contains("<!-- chimpread:v2 \(paperID.uuidString.lowercased()) ") || text.contains("Chimpread ID: `\(paperID.uuidString.lowercased())`") else {
            throw failure("That note does not identify this paper. Use Attach to an existing note instead.")
        }
        try record(paperID, url: noteURL, vault: root, libraryRoot: libraryRoot)
    }

    private static func record(_ id: UUID, url: URL, vault: URL, libraryRoot: URL) throws {
        let receipt = Receipt(paperID: id, relativePath: try ObsidianManagedWriter.relative(url, root: vault),
                              bookmark: try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), pending: false)
        try save(receipt, vault: vault, libraryRoot: libraryRoot)
    }

    private static func filename(_ paper: Paper) -> String {
        let title = paper.title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        let readable = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String((readable.isEmpty ? "Paper" : readable).prefix(64)) + " — " + paper.id.uuidString.lowercased() + ".md"
    }

    static func export(paper: Paper, vault: URL, pdfURL: URL? = nil, annotations: [ObsidianAnnotation] = [],
                       libraryRoot: URL? = nil, coverage: ObsidianAnnotationCoverage? = nil,
                       options: ObsidianExportOptions = .init(), sourceRevision: String? = nil) throws -> ObsidianExportResult {
        let root = try ObsidianManagedWriter.root(vault)
        let coverage = coverage ?? (annotations.isEmpty ? .unavailable("Annotations were not read.") : .complete(annotations))
        let legacy = root.appendingPathComponent("chimpread/\(paper.id.uuidString.lowercased()).md")
        var destination = legacy
        if let libraryRoot {
            if let receipt = try load(paper.id, vault: root, libraryRoot: libraryRoot) { destination = try resolved(receipt, vault: root) }
            else {
                destination = fm.fileExists(atPath: legacy.path) ? legacy : root.appendingPathComponent("chimpread/" + filename(paper))
                // Save intent before writing, so a crash cannot orphan a readable
                // note when its paper title changes before the next attempt.
                try save(Receipt(paperID: paper.id, relativePath: try ObsidianManagedWriter.relative(destination, root: root), bookmark: nil, pending: true), vault: root, libraryRoot: libraryRoot)
            }
        }
        let attachment = options.portablePDF ? try portablePDF(paper: paper, source: pdfURL, vault: root, expectedRevision: sourceRevision) : nil
        let sections = try render(paper: paper, pdfURL: attachment ?? pdfURL, coverage: coverage, revision: sourceRevision, noteURL: destination, vault: root)
        let prefix = try creationPrefix(paper: paper, template: options.creationTemplate)
        let recovery = libraryRoot?.appendingPathComponent("ObsidianRecovery", isDirectory: true)
        let result = try ObsidianManagedWriter.write(destination: destination, root: root, identity: paper.id.uuidString.lowercased(), sections: sections, creationPrefix: prefix, recoveryDirectory: recovery)
        if let libraryRoot, result.status != .conflict { try record(paper.id, url: result.url, vault: root, libraryRoot: libraryRoot) }
        return result
    }

    static func attach(paper: Paper, vault: URL, noteURL: URL, libraryRoot: URL, pdfURL: URL? = nil,
                       coverage: ObsidianAnnotationCoverage = .unavailable("Annotations were not read.")) throws -> ObsidianExportResult {
        let root = try ObsidianManagedWriter.root(vault)
        _ = try ObsidianManagedWriter.boundedRead(noteURL, root: root) // attach requires an existing note
        let sections = try render(paper: paper, pdfURL: pdfURL, coverage: coverage, revision: nil, noteURL: noteURL, vault: root)
        let result = try ObsidianManagedWriter.write(destination: noteURL, root: root, identity: paper.id.uuidString.lowercased(), sections: sections,
                                                     creationPrefix: "", recoveryDirectory: libraryRoot.appendingPathComponent("ObsidianRecovery"), allowAttach: true)
        if result.status != .conflict { try record(paper.id, url: noteURL, vault: root, libraryRoot: libraryRoot) }
        return result
    }

    private static func creationPrefix(paper: Paper, template: String?) throws -> String {
        if let template {
            guard template.utf8.count <= 128 * 1024, !template.contains("<!-- chimpread:") else { throw failure("The creation template is too large or contains managed section markers.") }
        }
        let alias = String(data: try JSONEncoder().encode([paper.title]), encoding: .utf8)!
        return "---\naliases: \(alias)\nchimpread_id: \(paper.id.uuidString.lowercased())\n---\n\n" + (template ?? "# \(ObsidianManagedWriter.plain(paper.title))\n\n## My notes\n\n## Questions\n\n") + "\n\n"
    }

    private static func render(paper: Paper, pdfURL: URL?, coverage: ObsidianAnnotationCoverage, revision: String?, noteURL: URL, vault: URL) throws -> [String: String] {
        var count = 0
        for field in [paper.title, paper.authors, paper.year, paper.doi, paper.notes] + paper.tags + paper.collections {
            count += field.utf8.count
            guard count <= ObsidianManagedWriter.limit / 2 else { throw failure("Paper metadata exceeds the export content limit.") }
        }
        func line(_ text: String) -> String { ObsidianManagedWriter.plain(text).components(separatedBy: .newlines).joined(separator: " ") }
        var metadata = "## Source\n\n### \(line(paper.title))\n\n"
        for (key, value) in [("Authors", paper.authors), ("Year", paper.year), ("DOI", paper.doi), ("Tags", paper.tags.joined(separator: ", ")), ("Collections", paper.collections.joined(separator: ", "))] {
            if !value.isEmpty { metadata += "\(key): \(line(value))\n\n" }
        }
        metadata += "[Open in Chimpread](<\(ObsidianLinks.paperURL(paperID: paper.id).absoluteString)>)\n\n"
        let pdf = pdfURL.flatMap { $0.isFileURL ? $0.standardizedFileURL : nil }
        let pdfLink: String? = pdf.map { file in
            if let relative = try? ObsidianManagedWriter.relative(file, root: vault),
               let noteRelative = try? ObsidianManagedWriter.relative(noteURL, root: vault) {
                let directoryDepth = noteRelative.split(separator: "/").count - 1
                return (String(repeating: "../", count: directoryDepth) + relative).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
            }
            return file.absoluteString
        }
        if let pdfLink { metadata += "[Open PDF](<\(pdfLink)>)\n\n" }
        metadata += "### Saved paper notes\n\n" + (paper.notes.isEmpty ? "No saved paper notes." : ObsidianManagedWriter.plain(paper.notes)) + "\n\n"
        var sections = ["metadata": metadata]
        if case .complete(let annotations) = coverage {
            guard annotations.count <= 10_000 else { throw failure("Export at most 10,000 annotation groups at a time.") }
            var body = "## Annotations\n\n"
            if annotations.isEmpty { body += "No saved annotations.\n\n" }
            var seen = Set<String>()
            for annotation in annotations {
                count += annotation.quote.utf8.count + annotation.note.utf8.count
                guard count <= ObsidianManagedWriter.limit / 2, annotation.page > 0 else { throw failure("Annotations exceed the content limit or have an invalid page.") }
                let anchor = annotation.id.flatMap { ObsidianLinks.blockID(annotationID: $0) }
                if let anchor, !seen.insert(anchor).inserted { throw failure("Duplicate annotation identity; export was cancelled.") }
                body += "### Page \(annotation.page)\n\n"
                if !annotation.quote.isEmpty { body += ObsidianManagedWriter.plain(annotation.quote).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n\n" }
                if !annotation.note.isEmpty { body += ObsidianManagedWriter.plain(annotation.note) + "\n\n" }
                let source = ObsidianLinks.paperURL(paperID: paper.id, page: annotation.page, annotationID: anchor == nil ? nil : annotation.id, revision: revision)
                body += "[Return to source](<\(source.absoluteString)>)"
                if let pdfLink { body += " · [PDF page](<\(pdfLink)#page=\(annotation.page)>)" }
                if let anchor { body += " ^\(anchor)" }
                body += "\n\n"
                guard body.utf8.count <= ObsidianManagedWriter.limit else { throw failure("Formatted annotations exceed 4 MiB.") }
            }
            sections["annotations"] = body
        }
        // Include a placeholder only for new notes in write(), while updates with
        // unavailable coverage omit the annotations key and retain existing bytes.
        return sections
    }

    /// Optional copy of a single selected PDF, streamed to a temporary file. The
    /// content-derived name is immutable: an edited destination is never replaced.
    private static func portablePDF(paper: Paper, source: URL?, vault: URL, expectedRevision: String?) throws -> URL? {
        guard let source, source.isFileURL else { throw failure("A local PDF is required for portable export.") }
        let directory = vault.appendingPathComponent("chimpread/attachments", isDirectory: true)
        // Reserve a safe directory through the anchored writer before streaming.
        let marker = directory.appendingPathComponent(".chimpread-attachments")
        try ObsidianManagedWriter.createOnce(destination: marker, root: vault, data: Data("chimpread attachments v1\n".utf8))
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        // Streaming copy uses a private local staging file. The final copy is
        // installed without overwriting, then content-checked on subsequent runs.
        let temporary = fm.temporaryDirectory.appendingPathComponent("chimpread-portable-\(UUID()).pdf")
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw failure("Cannot stage the portable PDF.") }
        defer { try? fm.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        var digest = SHA256(), copied = 0
        do {
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                copied += chunk.count
                guard copied <= 128 * 1024 * 1024 else { throw failure("Portable PDFs are limited to 128 MiB per file.") }
                digest.update(data: chunk); try output.write(contentsOf: chunk)
            }
            try output.synchronize(); try output.close()
        } catch { try? output.close(); throw error }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard expectedRevision == nil || expectedRevision == hash else { throw failure("The PDF changed during portable export. Try again; no note was changed.") }
        let destination = directory.appendingPathComponent(paper.id.uuidString.lowercased() + "-" + hash + ".pdf")
        try ObsidianManagedWriter.installLargeFile(temporary, destination: destination, root: vault, expectedHash: hash)
        return destination
    }
}

extension ObsidianManagedWriter {
    /// Streaming, anchored copy for optional attachments. No mmap or Data(contentsOf:).
    static func installLargeFile(_ source: URL, destination: URL, root: URL, expectedHash: String) throws {
        try withParent(destination, root: root, create: true) { parent, name in
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 {
                guard errno == EEXIST else { throw failure("Cannot create the portable PDF.") }
                let existing = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard existing >= 0 else { throw failure("The portable PDF destination is a link or inaccessible.") }
                var info = stat()
                guard fstat(existing, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(existing); throw failure("The portable PDF destination is not a regular file.") }
                let handle = FileHandle(fileDescriptor: existing, closeOnDealloc: true)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash else { throw failure("The portable PDF was edited; it was preserved. Choose a new destination before retrying.") }
                return
            }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var succeeded = false
            defer { try? output.close(); if !succeeded { unlinkat(parent, name, 0) } }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try output.synchronize(); succeeded = true
        }
    }
}
