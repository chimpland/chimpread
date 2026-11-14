import Foundation

func runResearchControllerTests() throws {
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ShelfError.message("Research controller: " + message) }
        print("PASS Research controller \(message)")
    }
    let gate = ResearchIndexGate.shared
    try expect(gate.begin(), "first indexing worker admitted")
    try expect(!gate.begin(), "another sheet cannot start overlapping index work")
    // Requesting UI cancellation does not release the gate: only worker exit does.
    try expect(!gate.begin(), "stopping worker keeps admission until exit")
    gate.end()
    try expect(gate.begin(), "worker exit permits next index job")
    gate.end()
    var rejected = false
    do { _ = try ResearchSearch.words(String(repeating: "é", count: 2001)) } catch { rejected = true }
    try expect(rejected, "search limit counts UTF-8 bytes")
    let words = try ResearchSearch.words((0..<100).map { "term\($0)" }.joined(separator: " "))
    try expect(words.count == 32, "at most 32 scoring terms")
    let terms = try ResearchSearch.words("What are papers about immune cells?")
    try expect(terms == ["immune", "cells"], "stop words removed")
    let papers = (0..<10000).map { Paper(title: "immune fixture \($0)", filename: "\($0).pdf", sourceHash: "") }
    let found = ResearchSearch.suggestions(papers: papers, words: terms, cancelled: { false })
    try expect(found.count == 5, "10,000 reference scoring returns bounded suggestions")
    let cancelled = ResearchSearch.suggestions(papers: papers, words: terms, cancelled: { true })
    try expect(cancelled.isEmpty, "metadata scoring honors cancellation")
}
