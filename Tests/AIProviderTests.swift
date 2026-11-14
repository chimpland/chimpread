import Foundation

func runAIProviderTests() throws {
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws { guard condition() else { throw ShelfError.message(name) }; print("PASS AI \(name)") }
    let hit = ResearchHit(id: "test", paperID: UUID(), title: "Fixture", page: 1, text: "Control increased in this fixture.", revision: "abc", score: 1)
    for kind in AIKind.allCases {
        var c = AIConfiguration(); c.kind = kind; c.endpoint = kind.endpoint; c.model = "test-model"; c.enabled = true
        let request = try AIService.request(config: c, key: "fixture-key", question: "What changed?", hits: [hit])
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try expect(request.httpMethod == "POST", "\(kind.rawValue) POST")
        try expect(!request.url!.absoluteString.contains("fixture-key"), "\(kind.rawValue) no credential in URL")
        try expect(request.httpBody!.count < 64000, "\(kind.rawValue) bounded context")
        if kind == .ollama { try expect(body["keep_alive"] as? Int == 0, "Ollama unload requested"); try expect(body["stream"] as? Bool == false, "Ollama bounded nonstream payload") }
        if kind == .anthropic { try expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key", "Claude key header") }
        if kind == .gemini { try expect(request.url!.path.hasSuffix("models/test-model:generateContent"), "Gemini endpoint"); try expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-key", "Gemini key header") }
    }
    for endpoint in ["http://example.com/chat", "file:///tmp/key", "https://user:secret@example.com/chat", "https://example.com/chat?key=secret"] {
        var c = AIConfiguration(); c.endpoint = endpoint
        do { _ = try c.validatedURL(); throw ShelfError.message("Unsafe endpoint accepted") } catch let e as ShelfError { if e.localizedDescription == "Unsafe endpoint accepted" { throw e } }
    }
    print("PASS AI rejects insecure endpoints and URL credentials")
    let fixtures: [(AIKind, String)] = [(.openAI, "{\"choices\":[{\"message\":{\"content\":\"Supported [1]\"}}]}"), (.anthropic, "{\"content\":[{\"type\":\"text\",\"text\":\"Supported [1]\"}]}"), (.gemini, "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Supported [1]\"}]}}]}"), (.ollama, "{\"message\":{\"content\":\"Supported [1]\"}}")]
    for (kind, json) in fixtures { let result = try AIService.parse(Data(json.utf8), kind: kind, sourceCount: 1); try expect(result == "Supported [1]", "\(kind.rawValue) response parsing") }
    do { _ = try AIService.parse(Data("{\"choices\":[{\"message\":{\"content\":\"Wrong [99]\"}}]}".utf8), kind: .openAI, sourceCount: 1); throw ShelfError.message("Invented source accepted") } catch let e as ShelfError { if e.localizedDescription == "Invented source accepted" { throw e } }
    print("PASS AI rejects invented citation numbers")
    do { _ = try AIService.context(question: String(repeating: "x", count: 4001), hits: [hit]); throw ShelfError.message("Oversized question accepted") } catch let e as ShelfError { if e.localizedDescription == "Oversized question accepted" { throw e } }
    print("PASS AI request context bounded")
    let hugeCitation = "[" + String(repeating: "9", count: 80) + "]"
    let hugeData = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": hugeCitation]]]])
    var rejected = false
    do { _ = try AIService.parse(hugeData, kind: .openAI, sourceCount: 1) } catch { rejected = true }
    try expect(rejected, "rejects overflowing citation integer")
    var longHit = hit; longHit.text = String(repeating: "z", count: 1999) + "Q"
    let exactContext = try AIService.context(question: "What?", hits: [longHit])
    try expect(exactContext.contains(longHit.text), "sends exact displayed excerpt including its end")
    longHit.text += "x"
    rejected = false
    do { _ = try AIService.context(question: "What?", hits: [longHit]) } catch { rejected = true }
    try expect(rejected, "rejects rather than silently shortens oversized displayed excerpt")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chimpread-ai-validation-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var config = AIConfiguration(); config.enabled = true; config.model = ""
    var keyWrites = 0
    rejected = false
    do { try config.saveSettings(root, key: "replacement", writeKey: { _, _ in keyWrites += 1 }) } catch { rejected = true }
    try expect(rejected && keyWrites == 0, "invalid configuration never mutates credentials")
    try expect(!FileManager.default.fileExists(atPath: AIConfiguration.url(root).path), "invalid settings not persisted")
    config.model = "fixture"
    try config.saveSettings(root, key: "replacement", writeKey: { _, _ in keyWrites += 1 })
    try expect(keyWrites == 1 && AIConfiguration.read(root).model == "fixture", "validated settings reach credential writer")
    let paper = Paper(id: hit.paperID, title: "Fixture", filename: "fixture.pdf", sourceHash: "import")
    var library = Library(); library.papers = [paper]
    let fixtureFiles = root.appendingPathComponent("PDFs", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureFiles, withIntermediateDirectories: true)
    try fixturePDF(at: fixtureFiles.appendingPathComponent("fixture.pdf"), title: "AI verification fixture", pages: 1)
    let files = fixtureFiles.resolvingSymlinksInPath()
    var otherRevision = hit; otherRevision.id = "second"; otherRevision.page = 2; otherRevision.revision = "stale"
    var hashes = 0
    rejected = false
    do { try AIService.verifyEvidence([hit, otherRevision], library: library, files: files, hash: { _ in hashes += 1; return "abc" }) } catch { rejected = true }
    try expect(rejected && hashes == 1, "mixed revisions rejected without network and one hash per file")
    otherRevision.revision = "abc"; hashes = 0
    try AIService.verifyEvidence([hit, otherRevision], library: library, files: files, hash: { _ in hashes += 1; return "abc" })
    try expect(hashes == 1, "matching evidence revisions share verified file hash")

    var organizationPaper = paper
    organizationPaper.title = "Immune screen"; organizationPaper.authors = "A. Researcher"; organizationPaper.year = "2026"
    organizationPaper.tags = ["immune"]; organizationPaper.collections = ["Existing"]
    organizationPaper.notes = "PRIVATE_NOTE_SENTINEL"
    organizationPaper.sourceURL = "PRIVATE_URL_SENTINEL"
    let preview = try AIService.organizationPreview(papers: [organizationPaper], collections: ["Existing"])
    let again = try AIService.organizationPreview(papers: [organizationPaper], collections: ["Existing"])
    try expect(preview == again && preview.utf8.count <= 64000, "organization preview deterministic and bounded")
    try expect(!preview.contains("PRIVATE_NOTE_SENTINEL") && !preview.contains("PRIVATE_URL_SENTINEL"), "organization excludes notes and URLs")
    let previewObject = try JSONSerialization.jsonObject(with: Data(preview.utf8)) as! [String: Any]
    let previewPaper = (previewObject["papers"] as! [[String: Any]])[0]
    try expect(Set(previewPaper.keys) == ["paper_id", "title", "authors", "year", "tags", "collections"], "organization metadata allowlist")
    func organizationJSON(_ rows: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["assignments": rows]), as: UTF8.self)
    }
    let assignment: [String: Any] = ["paper_id": paper.id.uuidString, "collection": "New topic", "reason": "Title and tags suggest this topic."]
    let valid = try AIService.parseOrganization(organizationJSON([assignment]), paperIDs: [paper.id])
    try expect(valid.count == 1 && valid[0].collection == "New topic", "organization allows reviewed new names")
    let abstain = try AIService.parseOrganization("{\"assignments\":[]}", paperIDs: [paper.id])
    try expect(abstain.isEmpty, "organization can abstain")
    var unknown = assignment; unknown["paper_id"] = UUID().uuidString
    var longName = assignment; longName["collection"] = String(repeating: "n", count: 81)
    var longReason = assignment; longReason["reason"] = String(repeating: "n", count: 401)
    var blank = assignment; blank["collection"] = "   "
    var extra = assignment; extra["apply"] = true
    var second = assignment; second["collection"] = "Second"
    var third = assignment; third["collection"] = "Third"
    for rows in [[unknown], [longName], [longReason], [blank], [extra], [assignment, assignment], [assignment, second, third], Array(repeating: assignment, count: 81)] {
        rejected = false
        do { _ = try AIService.parseOrganization(organizationJSON(rows), paperIDs: [paper.id]) } catch { rejected = true }
        try expect(rejected, "organization rejects invalid/duplicate/out-of-scope assignments")
    }
    for text in ["not JSON", "[]", "{\"assignments\":[],\"apply\":true}", "```json\n{\"assignments\":[]}\n```"] {
        rejected = false
        do { _ = try AIService.parseOrganization(text, paperIDs: [paper.id]) } catch { rejected = true }
        try expect(rejected, "organization requires strict JSON object")
    }
    let two = try AIService.parseOrganization(organizationJSON([assignment, second]), paperIDs: [paper.id])
    try expect(two.count == 2, "organization permits at most two suggestions per paper")
    var orgLibrary = Library(); orgLibrary.papers = [organizationPaper]; orgLibrary.collections = ["Existing"]
    try AIService.verifyOrganizationSnapshot(papers: [organizationPaper], collections: ["Existing"], library: orgLibrary)
    orgLibrary.papers[0].notes = "Another private note"
    try AIService.verifyOrganizationSnapshot(papers: [organizationPaper], collections: ["Existing"], library: orgLibrary)
    orgLibrary.papers[0].title = "Changed title"
    rejected = false
    do { try AIService.verifyOrganizationSnapshot(papers: [organizationPaper], collections: ["Existing"], library: orgLibrary) } catch { rejected = true }
    try expect(rejected, "organization rejects stale metadata without network")
    rejected = false
    do { _ = try AIService.organizationPreview(papers: Array(repeating: organizationPaper, count: 41), collections: []) } catch { rejected = true }
    try expect(rejected, "organization rejects oversized batch without truncating papers")

    var snapshotConfig = AIConfiguration(); snapshotConfig.model = "requested-at-dispatch"
    snapshotConfig.endpoint = "https://api.example.com/private/api/path"
    var snapshotHits = (0..<10).map { n -> ResearchHit in
        var value = hit; value.id = "ordered-\(n)"; value.page = n + 1
        value.text = String(repeating: "x", count: 1999) + String(n)
        value.title = String(repeating: "T", count: 350); return value
    }
    let dispatchDate = Date(timeIntervalSince1970: 1234567)
    let snapshotResponse = try JSONSerialization.data(withJSONObject: ["model": "reported-version", "choices": [["message": ["content": "Evidence [8]"]]]])
    let snapshot = try AIService.makeAnswerSnapshot(question: "Snapshot question", hits: snapshotHits, scope: "Selected collection", config: snapshotConfig, response: snapshotResponse, createdAt: dispatchDate)
    snapshotConfig.model = "later-setting"; snapshotHits[0].text = "later mutation"
    try expect(snapshot.sources.count == 8 && snapshot.sources.map(\.id) == (0..<8).map { "ordered-\($0)" }, "snapshot preserves exact transmitted source count and order")
    try expect(snapshot.sources[0].text.count == 2000 && snapshot.sources[0].text.hasSuffix("0") && snapshot.sources[0].title.count == 300, "snapshot retains exact transmitted excerpt and bounded title")
    try expect(snapshot.requestedModel == "requested-at-dispatch" && snapshot.reportedModel == "reported-version" && snapshot.createdAt == dispatchDate, "snapshot preserves dispatch provenance after settings change")
    try expect(snapshot.endpoint == "api.example.com" && snapshot.scope == "Selected collection", "snapshot endpoint retains host only")
    let decodedSnapshot = try JSONDecoder().decode(ResearchAnswerSnapshot.self, from: JSONEncoder().encode(snapshot))
    try expect(decodedSnapshot.id == snapshot.id && decodedSnapshot.sources.count == 8, "snapshot Codable round trip")
    snapshotConfig.kind = .gemini
    let geminiResponse = try JSONSerialization.data(withJSONObject: ["modelVersion": "gemini-reported", "candidates": [["content": ["parts": [["text": "Evidence [1]"]]]]]])
    let geminiSnapshot = try AIService.makeAnswerSnapshot(question: "Question", hits: [hit], scope: "All", config: snapshotConfig, response: geminiResponse, createdAt: dispatchDate)
    try expect(geminiSnapshot.reportedModel == "gemini-reported", "snapshot captures Gemini modelVersion")

}
