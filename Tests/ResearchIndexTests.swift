import Foundation

func runResearchIndexTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chimpread-index-tests-\(UUID())")
    let files = root.appendingPathComponent("PDFs")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ShelfError.message("Research index test: " + message) }
    }
    let url = files.appendingPathComponent("fixture.pdf")
    try fixturePDF(at: url, title: "Immune zebrafish", pages: 3)
    var paper = Paper(title: "Immune zebrafish", filename: "fixture.pdf", sourceHash: "import-only")
    var metadata = Paper(title: "Metadata-only axolotl", filename: "", sourceHash: "")
    metadata.metadataOnly = true
    let index = try ResearchIndex(root: root)
    var progress: [(Int, Int)] = []
    try index.index(papers: [paper, metadata], files: files, cancelled: { false }, progress: { progress.append(($0, $1)) })
    try require(progress.last?.0 == 2, "progress completes")
    let coverage = try index.coverage(papers: [paper, metadata])
    try require(coverage.indexed == 1 && coverage.total == 2 && coverage.pages == 3 && coverage.failed == 0, "coverage distinguishes metadata")
    let hits = try index.search("demonstration")
    try require(hits.count == 3 && hits.allSatisfy { $0.page > 0 && $0.paperID == paper.id }, "page-linked FTS results")
    let revision = try Importer.hash(url)
    try require(hits.allSatisfy { $0.revision == revision }, "current PDF hash, not import hash")
    try require(try index.search("demonstration", paperIDs: [metadata.id]).isEmpty, "scope excludes other paper")
    try require(try index.search("demonstration", paperIDs: []).isEmpty, "empty scope")
    try require(try index.search("axolotl").first?.page == 0, "metadata match is not a PDF citation")
    try require(try index.search("\" OR NOT : * ( )").count <= 20, "FTS operators treated as tokens")
    try require(try index.search("demonstration", limit: 1).count == 1, "result limit")
    try require(try index.search("demonstration", limit: -1).isEmpty, "negative limit")
    paper.title = "Renamed quokka"
    try index.index(papers: [paper, metadata], files: files, cancelled: { false }, progress: { _, _ in })
    try require(try index.search("quokka").first?.title == paper.title, "metadata refresh without PDF revision change")
    let reopened = try ResearchIndex(root: root)
    try require(try reopened.search("demonstration").count == 3, "persistent index survives reopening")
    do {
        try index.index(papers: [paper], files: files, cancelled: { true }, progress: { _, _ in })
        throw ShelfError.message("Cancellation was ignored")
    } catch is CancellationError {}
    try require(try index.search("demonstration").count == 3, "cancel preserves committed evidence")
    try fixturePDF(at: url, title: "Replacement platypus", pages: 2)
    var checks = 0
    do {
        try index.index(papers: [paper, metadata], files: files, cancelled: {
            checks += 1; return checks >= 6
        }, progress: { _, _ in })
        throw ShelfError.message("Mid-document cancellation was ignored")
    } catch is CancellationError {}
    try require(try index.search("demonstration").allSatisfy { $0.revision == revision }, "mid-document cancellation rolls back replacement")
    try index.index(papers: [paper], files: files, cancelled: { false }, progress: { _, _ in })
    let changed = try index.search("platypus")
    try require(changed.count == 2 && changed.allSatisfy { $0.revision != revision }, "changed PDF replaces prior revision")
    try require(try index.search("axolotl").isEmpty, "removed record purged")
    try FileManager.default.removeItem(at: url)
    try index.index(papers: [paper], files: files, cancelled: { false }, progress: { _, _ in })
    try require(try index.search("demonstration").isEmpty, "missing PDF cannot return stale passages")
    try require(try index.coverage(papers: [paper]).failed == 1, "missing PDF recorded as failed")
    try index.clear()
    try require(try index.search("quokka").isEmpty, "clear removes metadata and text")
    print("PASS persistent research index, scoped search, revisions, cancellation and missing files")
}
