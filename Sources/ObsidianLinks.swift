import Foundation

/// Versioned identity-only navigation. Links never contain filesystem paths or commands.
enum ObsidianLinks {
    struct Target: Equatable, Sendable {
        let paperID: UUID
        let page: Int?
        let annotationID: String?
        let revision: String?
        let libraryID: UUID?
    }
    static let maximumPage = 1_000_000

    static func paperURL(paperID: UUID, page: Int? = nil, annotationID: String? = nil,
                         revision: String? = nil, libraryID: UUID? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "chimpread"; components.host = "paper"
        components.path = "/" + paperID.uuidString.lowercased()
        var items = [URLQueryItem(name: "v", value: "1")]
        if let libraryID { items.append(.init(name: "library", value: libraryID.uuidString.lowercased())) }
        if let page, (1...maximumPage).contains(page) {
            items.append(.init(name: "page", value: String(page)))
            if let annotationID, let id = UUID(uuidString: annotationID) {
                items.append(.init(name: "annotation", value: id.uuidString.lowercased()))
            }
            if let revision, validRevision(revision) {
                items.append(.init(name: "revision", value: revision.lowercased()))
            }
        }
        components.queryItems = items
        // All components above are generated from fixed strings, integers or UUIDs.
        return components.url!
    }

    static func parse(_ url: URL) -> Target? {
        guard url.absoluteString.utf8.count <= 2048,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "chimpread", c.host == "paper",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              c.percentEncodedPath == c.path,
              c.path.count == 37, c.path.first == "/",
              let paperID = UUID(uuidString: String(c.path.dropFirst())),
              let items = c.queryItems, items.count <= 5 else { return nil }
        let allowed: Set<String> = ["v", "page", "annotation", "revision", "library"]
        var values: [String: String] = [:]
        for item in items {
            guard allowed.contains(item.name), values[item.name] == nil,
                  let value = item.value, !value.isEmpty else { return nil }
            values[item.name] = value
        }
        guard values["v"] == "1" else { return nil }
        var page: Int?
        if let value = values["page"] {
            guard value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let n = Int(value), (1...maximumPage).contains(n) else { return nil }
            page = n
        }
        var annotation: String?
        if let value = values["annotation"] {
            guard page != nil, let id = UUID(uuidString: value) else { return nil }
            annotation = id.uuidString.lowercased()
        }
        var revision: String?
        if let value = values["revision"] {
            guard page != nil, validRevision(value) else { return nil }
            revision = value.lowercased()
        }
        var libraryID: UUID?
        if let value = values["library"] {
            guard let id = UUID(uuidString: value) else { return nil }; libraryID = id
        }
        return Target(paperID: paperID, page: page, annotationID: annotation, revision: revision, libraryID: libraryID)
    }

    private static func validRevision(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func blockID(annotationID: String) -> String? {
        UUID(uuidString: annotationID).map { "chimp-a-" + $0.uuidString.lowercased() }
    }

    static func copyMarkdown(paper: Paper, annotation: ObsidianAnnotation, revision: String? = nil,
                             libraryID: UUID? = nil, paperNoteLink: String? = nil) -> String {
        var blocks: [String] = []
        if !annotation.quote.isEmpty {
            blocks.append(plain(annotation.quote).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n"))
        }
        if !annotation.note.isEmpty { blocks.append(plain(annotation.note)) }
        if blocks.isEmpty { blocks.append("Annotation text unavailable.") }
        let citation = [paper.authors, paper.year, paper.title].filter { !$0.isEmpty }.map(inline).joined(separator: " · ")
        let source = paperURL(paperID: paper.id, page: annotation.page, annotationID: annotation.id,
                              revision: revision, libraryID: libraryID)
        var links = "[p. \(annotation.page)](\(source.absoluteString))"
        if let paperNoteLink, !paperNoteLink.isEmpty { links += " · " + paperNoteLink }
        blocks.append([citation, links].filter { !$0.isEmpty }.joined(separator: " — "))
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func inline(_ value: String) -> String {
        plain(value.components(separatedBy: .newlines).joined(separator: " "))
    }
    private static func plain(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                ? String(scalar) : "&#\(scalar.value);"
        }.joined()
    }
}
