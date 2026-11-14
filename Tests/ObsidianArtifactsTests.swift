import Foundation

enum ObsidianArtifactsTests {
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chimpread-artifacts-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw ShelfError.message("Obsidian artifact test: " + message) }
        }
        func rejects(_ operation: () throws -> Void) throws {
            do { try operation() } catch { return }
            throw ShelfError.message("Obsidian artifact test: expected rejection")
        }
        let paper = Paper(title: "Evidence [one]", filename: "paper.pdf", sourceHash: "")
        let source = ObsidianResearchSource(id: "source-1", paperID: paper.id, title: paper.title,
            page: 7, excerpt: "Exact first line.\nExact second line.", revision: "captured-sha256", sourceURL: nil)
        let snapshot = ObsidianResearchNote(title: "A question", question: "What was measured?", sources: [source],
            response: "An AI draft [1].", provenance: ObsidianAIProvenance(provider: "Test provider", requestedModel: "test-model", generatedAt: Date(timeIntervalSince1970: 1)))
        let first = try ObsidianArtifactExporter.saveResearchNote(snapshot, vault: root)
        try require(first.status == .created, "research note creation")
        let content = try String(contentsOf: first.url, encoding: .utf8)
        try require(content.contains("unreviewed") && content.contains("AI draft") && content.contains("test-model"), "review and AI provenance")
        try require(content.contains("> Exact first line.\n> Exact second line.") && content.contains("captured-sha256"), "exact ordered source and revision")
        try require(content.contains("Revision was not verified") && content.contains("page=7"), "unknown coverage and physical page")
        let userContent = content + "\nMy edited interpretation.\n"
        try userContent.write(to: first.url, atomically: true, encoding: .utf8)
        let again = try ObsidianArtifactExporter.saveResearchNote(snapshot, vault: root)
        try require(again.url == first.url && again.status == .unchanged, "same snapshot opens existing note")
        try require(String(contentsOf: first.url, encoding: .utf8) == userContent, "user edits untouched")
        let noAI = ObsidianResearchNote(title: "My own reading", question: "What next?", sources: [source], interpretation: "My reasoning.")
        let own = try ObsidianArtifactExporter.saveResearchNote(noAI, vault: root)
        try require(!String(contentsOf: own.url, encoding: .utf8).contains("## AI draft"), "works without AI")
        let missingProvenance = ObsidianResearchNote(title: "Invalid", question: "Q", sources: [source], response: "Draft")
        try rejects { _ = try ObsidianArtifactExporter.saveResearchNote(missingProvenance, vault: root) }
        let invalidSource = ObsidianResearchSource(id: "bad", paperID: paper.id, title: "Metadata", page: 0, excerpt: "metadata", revision: "", sourceURL: nil)
        try rejects { _ = try ObsidianArtifactExporter.saveResearchNote(ObsidianResearchNote(title: "Invalid", question: "Q", sources: [invalidSource]), vault: root) }

        let existing = root.appendingPathComponent("Known paper.md")
        try "Existing paper".write(to: existing, atomically: true, encoding: .utf8)
        let hubID = UUID()
        let hub = try ObsidianArtifactExporter.collectionHub(id: hubID, title: "Reading", papers: [paper], vault: root,
            noteURLs: [paper.id: existing], introduction: "My purpose.")
        let hubText = try String(contentsOf: hub.url, encoding: .utf8)
        try require(hubText.contains("../Known%20paper.md") && hubText.contains("My purpose."), "hub uses real note links")
        try (hubText + "\nUser conclusion.\n").write(to: hub.url, atomically: true, encoding: .utf8)
        let second = Paper(title: "Another paper", filename: "second.pdf", sourceHash: "")
        _ = try ObsidianArtifactExporter.collectionHub(id: hubID, title: "Reading", papers: [paper, second], vault: root, noteURLs: [paper.id: existing])
        let refreshed = try String(contentsOf: hub.url, encoding: .utf8)
        try require(refreshed.contains("Another paper") && refreshed.contains("User conclusion.") && refreshed.contains("My purpose."), "hub refresh preserves user text")
        try require(!fm.fileExists(atPath: root.appendingPathComponent("chimpread/" + second.id.uuidString.lowercased() + ".md").path), "hub never exports referenced papers")

        let questions = try ObsidianArtifactExporter.openQuestions(id: UUID(), title: "Questions", questions: [.init(text: "What remains unknown?")], vault: root)
        try require(String(contentsOf: questions.url, encoding: .utf8).contains("- [ ] What remains unknown?"), "questions remain ordinary Markdown")
        let canvasID = UUID()
        let canvas = try ObsidianArtifactExporter.canvas(id: canvasID, title: "Compare", papers: [paper, second],
            edges: [.init(from: paper.id, to: second.id, label: "Compare methods")], vault: root, noteURLs: [paper.id: existing])
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: canvas.url)) as! [String: Any]
        let nodes = json["nodes"] as! [[String: Any]], edges = json["edges"] as! [[String: Any]]
        try require(nodes.count == 3 && edges.count == 1 && edges[0]["label"] as? String == "Compare methods", "only selected nodes and explicit edge")
        try require(nodes.contains { $0["file"] as? String == "Known paper.md" }, "Canvas uses vault-relative file node")
        json["user_edit"] = "kept"
        let editedCanvas = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try editedCanvas.write(to: canvas.url)
        let canvasAgain = try ObsidianArtifactExporter.canvas(id: canvasID, title: "Compare", papers: [paper, second], edges: [], vault: root)
        try require(canvasAgain.status == .unchanged && Data(contentsOf: canvas.url) == editedCanvas, "Canvas preserves user arrangement")
        try rejects { _ = try ObsidianArtifactExporter.canvas(id: UUID(), title: "Too big", papers: Array(repeating: paper, count: 21), edges: [], vault: root) }
        try rejects { _ = try ObsidianArtifactExporter.canvas(id: UUID(), title: "Invalid edge", papers: [paper], edges: [.init(from: paper.id, to: UUID(), label: "Compare")], vault: root) }

        let collision = ObsidianResearchNote(title: "Collision", question: "Q", sources: [])
        let collisionURL = root.appendingPathComponent("chimpread/research-\(collision.id.uuidString.lowercased()).md")
        try "Unrelated user note".write(to: collisionURL, atomically: true, encoding: .utf8)
        try rejects { _ = try ObsidianArtifactExporter.saveResearchNote(collision, vault: root) }
        try require(String(contentsOf: collisionURL, encoding: .utf8) == "Unrelated user note", "unrelated note preserved")
        let symlinked = ObsidianResearchNote(title: "Symlink", question: "Q", sources: [])
        let symlinkURL = root.appendingPathComponent("chimpread/research-\(symlinked.id.uuidString.lowercased()).md")
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: existing)
        try rejects { _ = try ObsidianArtifactExporter.saveResearchNote(symlinked, vault: root) }
        try require(String(contentsOf: existing, encoding: .utf8) == "Existing paper", "symlink target untouched")
        let hostileVault = root.appendingPathComponent("hostile")
        try fm.createDirectory(at: hostileVault, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: hostileVault.appendingPathComponent("chimpread"), withDestinationURL: root)
        try rejects { _ = try ObsidianArtifactExporter.saveResearchNote(noAI, vault: hostileVault) }
        let oversized = ObsidianResearchNote(title: "Too large", question: String(repeating: "a", count: 1_048_577), sources: [])
        try rejects { _ = try ObsidianArtifactExporter.saveResearchNote(oversized, vault: root) }
        print("PASS Obsidian research snapshots, user ownership, collection hubs, questions, bounded Canvas and safe paths")
    }
}
