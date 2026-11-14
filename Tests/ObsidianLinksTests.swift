import Foundation

enum ObsidianLinksTests {
    static func run() throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw ShelfError.message("Obsidian links test: " + message) }
        }
        let paperID = UUID(), annotationID = UUID(), libraryID = UUID()
        let revision = String(repeating: "ab", count: 32)
        let link = ObsidianLinks.paperURL(paperID: paperID, page: 7, annotationID: annotationID.uuidString, revision: revision, libraryID: libraryID)
        let parsed = ObsidianLinks.parse(link)
        try require(parsed?.paperID == paperID && parsed?.page == 7 && parsed?.annotationID == annotationID.uuidString.lowercased() && parsed?.revision == revision && parsed?.libraryID == libraryID, "complete link round-trip")
        try require(ObsidianLinks.parse(ObsidianLinks.paperURL(paperID: paperID))?.page == nil, "paper-only link")
        let base = "chimpread://paper/\(paperID.uuidString)?v=1"
        let malformed = [
            base + "&page=0", base + "&page=-1", base + "&page=1000001", base + "&page=999999999999999999999999999",
            base + "&page=1.5", base + "&page=%2B1", base + "&page=", base + "&page=1&page=2", base + "&v=1",
            base + "&path=%2Ftmp%2Fsecret", base + "&annotation=0-3&page=2", base + "&annotation=\(annotationID)",
            base + "&revision=\(revision)", base + "&page=2&revision=abc", base + "&library=../../file", base + "#fragment",
            "chimpread://paper/\(paperID)?v=2", "chimpread://paper/\(paperID)", "chimpread://command/\(paperID)?v=1",
            "chimpread://user@paper/\(paperID)?v=1", "chimpread://paper:123/\(paperID)?v=1", "file:///tmp/paper?v=1",
            "chimpread://paper/\(paperID)/extra?v=1", "chimpread://paper/%2F\(paperID)?v=1"
        ]
        for raw in malformed {
            if let url = URL(string: raw) { try require(ObsidianLinks.parse(url) == nil, "reject " + raw) }
        }
        let encoded = URL(string: base + "&page=%37&annotation=" + annotationID.uuidString.replacingOccurrences(of: "-", with: "%2D"))!
        try require(ObsidianLinks.parse(encoded)?.annotationID == annotationID.uuidString.lowercased(), "safe percent-encoded query decoding")
        let fallback = ObsidianLinks.paperURL(paperID: paperID, page: 2, annotationID: "positional-1-3")
        try require(ObsidianLinks.parse(fallback)?.page == 2 && ObsidianLinks.parse(fallback)?.annotationID == nil, "imported annotation falls back to page")
        try require(ObsidianLinks.blockID(annotationID: "1-3") == nil, "no invented imported block ID")
        try require(ObsidianLinks.blockID(annotationID: annotationID.uuidString) == "chimp-a-" + annotationID.uuidString.lowercased(), "stable block ID")
        let paper = Paper(title: "Test paper", filename: "test.pdf", sourceHash: "")
        let annotation = ObsidianAnnotation(page: 7, quote: "First line\nSecond line", note: "My comment", id: annotationID.uuidString)
        let markdown = ObsidianLinks.copyMarkdown(paper: paper, annotation: annotation, revision: revision)
        try require(markdown.contains("> First line\n> Second line\n\nMy comment") && markdown.contains("chimpread://paper/"), "quote, comment and source")
        let hostile = ObsidianAnnotation(page: 1, quote: "![[embed]]\n<img src='x'>", note: "```dataviewjs\nrun()\n```")
        let inert = ObsidianLinks.copyMarkdown(paper: paper, annotation: hostile)
        try require(!inert.contains("![[") && !inert.contains("<img") && !inert.contains("```"), "source content cannot activate embeds or plugin code")
        print("PASS versioned Obsidian links, route validation, stable anchors and clipboard Markdown")
    }
}
