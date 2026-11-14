import Foundation
import Darwin

/// Value snapshots only: exporting never queries a provider, indexes a vault, or opens a PDF.
struct ObsidianResearchSource: Sendable {
    let id: String
    let paperID: UUID
    let title: String
    let page: Int
    let excerpt: String
    let revision: String
    let sourceURL: URL?
    var noteURL: URL? = nil
    var revisionVerified: Bool = false
}

struct ObsidianAIProvenance: Sendable {
    let provider: String
    let requestedModel: String
    var reportedModel: String? = nil
    let generatedAt: Date
}

struct ObsidianResearchNote: Sendable {
    var id = UUID()
    let title: String
    let question: String
    var scope = ""
    let sources: [ObsidianResearchSource]
    var response: String? = nil
    var provenance: ObsidianAIProvenance? = nil
    var interpretation = ""
    var reviewedByUser = false
    var createdAt = Date()
}

struct ObsidianOpenQuestion: Sendable {
    let text: String
    var sourceURLs: [URL] = []
}

/// Edges are supplied explicitly by the user; the exporter never infers relationships.
struct ObsidianCanvasEdge: Sendable {
    let from: UUID
    let to: UUID
    let label: String
}

enum ObsidianArtifactExporter {
    private static let byteLimit = 4 * 1024 * 1024
    private static let inputLimit = 1024 * 1024

    static func collectionHub(id: UUID, title: String, papers: [Paper], vault: URL,
                              noteURLs: [UUID: URL] = [:], sourceURLs: [UUID: URL] = [:],
                              introduction: String = "") throws -> ObsidianExportResult {
        guard papers.count <= 2_000 else { throw failure("A reading hub can include at most 2,000 papers.") }
        try bounded([title, introduction] + papers.flatMap { [$0.title, $0.authors, $0.year] })
        let root = try rootURL(vault)
        let destination = root.appendingPathComponent("chimpread/collection-\(id.uuidString.lowercased()).md")
        let sorted = papers.sorted {
            let order = $0.title.compare($1.title, options: [.caseInsensitive, .literal])
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        var seen = Set<UUID>()
        let lines = try sorted.filter { seen.insert($0.id).inserted }.map { paper -> String in
            let target = try noteTarget(noteURLs[paper.id], vault: root)
                ?? safeSource(sourceURLs[paper.id])?.absoluteString
                ?? fallback(paper.id).absoluteString
            let details = [paper.year, paper.unread ? "Unread" : "Read"].filter { !$0.isEmpty }.map(inline).joined(separator: " · ")
            return "- [\(inline(paper.title))](<\(target)>) — \(details)"
        }
        let creation = "# \(inline(title))\n\n" + (introduction.isEmpty ? "" : prose(introduction) + "\n\n")
            + "## My notes\n\n## Open questions\n\n"
        let body = "## Papers\n\n" + (lines.isEmpty ? "No papers in this snapshot." : lines.joined(separator: "\n"))
            + "\n\nMembership comes from the selected collection. These links do not imply scientific relationships.\n"
        return try ObsidianManagedWriter.write(destination: destination, root: root,
            identity: "collection-\(id.uuidString.lowercased())", sections: ["papers": body], creationPrefix: creation)
    }

    static func saveResearchNote(_ snapshot: ObsidianResearchNote, vault: URL) throws -> ObsidianExportResult {
        guard snapshot.sources.count <= 100 else { throw failure("Save at most 100 source passages in one research note.") }
        guard snapshot.sources.allSatisfy({ $0.page > 0 && !$0.revision.isEmpty && !$0.excerpt.isEmpty }) else {
            throw failure("Each source needs an excerpt, a one-based PDF page, and its captured revision.")
        }
        guard Set(snapshot.sources.map(\.id)).count == snapshot.sources.count else { throw failure("Source identifiers must be unique.") }
        if let response = snapshot.response, !response.isEmpty, snapshot.provenance == nil {
            throw failure("An AI draft needs its captured provider and model provenance.")
        }
        try bounded([snapshot.title, snapshot.question, snapshot.scope, snapshot.response ?? "", snapshot.interpretation]
            + snapshot.sources.flatMap { [$0.id, $0.title, $0.excerpt, $0.revision] }
            + [snapshot.provenance?.provider ?? "", snapshot.provenance?.requestedModel ?? "", snapshot.provenance?.reportedModel ?? ""])
        let root = try rootURL(vault)
        let identity = "research-\(snapshot.id.uuidString.lowercased())"
        var text = "---\nchimpread_research_id: \"\(snapshot.id.uuidString.lowercased())\"\nchimpread_schema: 1\n"
            + "chimpread_review: \"\(snapshot.reviewedByUser ? "reviewed-by-user" : "unreviewed")\"\n---\n"
            + marker(identity) + "\n# \(inline(snapshot.title))\n\n"
            + "Created: \(date(snapshot.createdAt))\n\n## Question\n\n\(prose(snapshot.question))\n\n"
        if !snapshot.scope.isEmpty { text += "Scope: \(inline(snapshot.scope))\n\n" }
        text += "## My interpretation\n\n" + prose(snapshot.interpretation) + "\n\n"
        text += snapshot.reviewedByUser
            ? "Review recorded by the user at save time; this does not certify the response or its claims.\n\n"
            : "Review status: unreviewed. Saving this note does not verify its claims.\n\n"
        if let response = snapshot.response, !response.isEmpty {
            text += "## AI draft\n\n\(prose(response))\n\n"
        }
        if let provenance = snapshot.provenance {
            text += "## AI provenance\n\nProvider: \(inline(provenance.provider))\n\nRequested model: \(inline(provenance.requestedModel))\n\n"
            if let model = provenance.reportedModel { text += "Provider-reported model: \(inline(model))\n\n" }
            text += "Generated: \(date(provenance.generatedAt))\n\n"
        }
        text += "## Source passages\n\nThese are captured source excerpts, not independent verification of the response. Source order is preserved.\n\n"
        for (index, source) in snapshot.sources.enumerated() {
            text += "### [\(index + 1)] \(inline(source.title)) · PDF page \(source.page)\n\n"
            text += prose(source.excerpt).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            let target = safeSource(source.sourceURL) ?? fallback(source.paperID, page: source.page)
            text += "[Open source](<\(target.absoluteString)>)"
            if let note = try noteTarget(source.noteURL, vault: root) { text += " · [Paper note](<\(note)>)" }
            text += "\n\nSource ID: \(inline(source.id)) · Paper ID: \(source.paperID.uuidString.lowercased())\n\n"
            text += "Captured PDF revision: \(inline(source.revision))\n\n"
            text += source.revisionVerified ? "Revision checked before export.\n\n" : "Revision was not verified at export; the current PDF may differ.\n\n"
        }
        text += "## Open questions\n\n"
        return try createOnce(data: Data(text.utf8), identity: identity, extension: "md", root: root)
    }

    static func openQuestions(id: UUID, title: String, questions: [ObsidianOpenQuestion], vault: URL) throws -> ObsidianExportResult {
        guard questions.count <= 200, questions.allSatisfy({ $0.sourceURLs.count <= 100 }) else { throw failure("Too many questions or source links.") }
        try bounded([title] + questions.map(\.text) + questions.flatMap { $0.sourceURLs.map(\.absoluteString) })
        let identity = "questions-\(id.uuidString.lowercased())"
        var text = marker(identity) + "\n# \(inline(title))\n\n"
        for question in questions {
            text += "- [ ] \(inline(question.text))\n"
            for (offset, url) in question.sourceURLs.enumerated() {
                guard let url = safeSource(url) else { throw failure("Unsupported question source URL.") }
                text += "  - [Source \(offset + 1)](<\(url.absoluteString)>)\n"
            }
        }
        return try createOnce(data: Data(text.utf8), identity: identity, extension: "md", root: rootURL(vault))
    }

    static func canvas(id: UUID, title: String, papers: [Paper], edges: [ObsidianCanvasEdge], vault: URL,
                       noteURLs: [UUID: URL] = [:], sourceURLs: [UUID: URL] = [:]) throws -> ObsidianExportResult {
        guard !papers.isEmpty, papers.count <= 20, edges.count <= 100 else { throw failure("Select 1–20 papers and at most 100 explicit relationships.") }
        let ids = Set(papers.map(\.id))
        guard ids.count == papers.count,
              edges.allSatisfy({ ids.contains($0.from) && ids.contains($0.to) && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw failure("Canvas papers must be unique and every relationship must name selected papers and have a label.")
        }
        try bounded([title] + papers.map(\.title) + edges.map(\.label))
        let root = try rootURL(vault), identity = "canvas-\(id.uuidString.lowercased())"
        var nodes: [[String: Any]] = [["id": "context", "type": "text", "x": 0, "y": -220, "width": 900, "height": 160,
            "text": "# \(inline(title))\n\nA user-selected snapshot. Every relationship was explicitly supplied; none was inferred. Arrange and edit freely."]]
        for (index, paper) in papers.enumerated() {
            var node: [String: Any] = ["id": paper.id.uuidString.lowercased(), "x": (index % 4) * 360,
                "y": (index / 4) * 230, "width": 320, "height": 180]
            if let path = try relativeNote(noteURLs[paper.id], vault: root) {
                node["type"] = "file"; node["file"] = path
            } else {
                node["type"] = "text"
                let source = safeSource(sourceURLs[paper.id]) ?? fallback(paper.id)
                node["text"] = "[\(inline(paper.title))](<\(source.absoluteString)>)"
            }
            nodes.append(node)
        }
        let encodedEdges: [[String: Any]] = edges.enumerated().map { offset, edge in
            ["id": "edge-\(offset)", "fromNode": edge.from.uuidString.lowercased(), "toNode": edge.to.uuidString.lowercased(),
             "fromSide": "right", "toSide": "left", "label": edge.label]
        }
        let object: [String: Any] = ["nodes": nodes, "edges": encodedEdges, "chimpread_snapshot_id": identity]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return try createOnce(data: data, identity: identity, extension: "canvas", root: root)
    }

    private static func failure(_ message: String) -> ShelfError { .message(message) }
    private static func bounded(_ values: [String]) throws {
        var bytes = 0
        for value in values { bytes += value.utf8.count; guard bytes <= inputLimit else { throw failure("The artifact exceeds the 1 MiB input limit.") } }
    }
    private static func prose(_ value: String) -> String {
        // Preserve readable punctuation while making source/AI Markdown inert.
        var result = ""
        for scalar in value.unicodeScalars {
            if "&<>[]!`*_$#\\".unicodeScalars.contains(scalar) { result += "&#\(scalar.value);" }
            else { result.unicodeScalars.append(scalar) }
        }
        return result
    }
    private static func inline(_ value: String) -> String {
        var text = prose(value).components(separatedBy: .newlines).joined(separator: " ")
        for char in ["\\", "[", "]", "*", "_", "#", "`", "<", ">"] { text = text.replacingOccurrences(of: char, with: "\\" + char) }
        return text
    }
    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private static func marker(_ identity: String) -> String { "<!-- chimpread:snapshot \(identity) -->" }
    private static func fallback(_ id: UUID, page: Int? = nil) -> URL {
        ObsidianLinks.paperURL(paperID: id, page: page)
    }
    private static func safeSource(_ value: URL?) -> URL? {
        guard let value, ["chimpread", "https", "http", "obsidian"].contains(value.scheme?.lowercased() ?? ""),
              value.user == nil, value.password == nil, value.absoluteString.utf8.count <= 8192 else { return nil }
        return value
    }
    private static func rootURL(_ vault: URL) throws -> URL {
        guard vault.isFileURL else { throw failure("Choose a local vault folder.") }
        let root = vault.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw failure("The vault is not a folder.") }
        return root
    }
    private static func relativeNote(_ url: URL?, vault: URL) throws -> String? {
        guard let url else { return nil }
        guard url.isFileURL else { throw failure("Paper-note links must refer to local vault files.") }
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(vault.path + "/"), target.resolvingSymlinksInPath() == target,
              (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return String(target.path.dropFirst(vault.path.count + 1))
    }
    private static func noteTarget(_ url: URL?, vault: URL) throws -> String? {
        guard let path = try relativeNote(url, vault: vault) else { return nil }
        // All artifacts live directly in chimpread/, so a relative link remains useful outside Obsidian.
        return ("../" + path).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?<>")))
    }

    /// Exclusive creation through an opened directory prevents following a swapped managed-folder symlink.
    /// Existing snapshots are owned by the user; neither content nor metadata is refreshed.
    private static func createOnce(data: Data, identity: String, extension ext: String, root: URL) throws -> ObsidianExportResult {
        guard data.count <= byteLimit else { throw failure("The formatted artifact exceeds 4 MiB.") }
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw failure("The vault folder could not be opened safely.") }; defer { Darwin.close(rootFD) }
        if mkdirat(rootFD, "chimpread", 0o755) != 0 && errno != EEXIST { throw failure("The export folder could not be created.") }
        let folder = openat(rootFD, "chimpread", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folder >= 0 else { throw failure("The export folder is unavailable or is a symlink.") }; defer { Darwin.close(folder) }
        let name = identity + "." + ext
        let url = root.appendingPathComponent("chimpread/" + name)
        let fd = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        if fd < 0 {
            guard errno == EEXIST else { throw failure("The snapshot could not be created.") }
            let existing = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard existing >= 0 else { throw failure("The existing snapshot cannot be read safely.") }; defer { Darwin.close(existing) }
            var info = stat()
            guard fstat(existing, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= byteLimit else {
                throw failure("The existing snapshot is not a bounded regular file; it was preserved.")
            }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(existing, &buffer, buffer.count)
                guard count >= 0 else { throw failure("The existing snapshot could not be read.") }
                if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= byteLimit else { throw failure("The existing snapshot grew beyond 4 MiB; it was preserved.") }
            }
            let owned: Bool
            if ext == "canvas" {
                owned = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any])?["chimpread_snapshot_id"] as? String == identity
            } else { owned = String(data: bytes, encoding: .utf8)?.contains(marker(identity)) == true }
            guard owned else { throw failure("An unrelated or edited identity occupies this snapshot path; it was preserved.") }
            return .init(url: url, status: .unchanged)
        }
        var success = false
        defer { Darwin.close(fd); if !success { unlinkat(folder, name, 0) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw failure("The snapshot could not be fully written.") }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure("The snapshot could not be saved completely.") }
        success = true
        return .init(url: url, status: .created)
    }
}
