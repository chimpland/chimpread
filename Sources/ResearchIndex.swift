import Foundation
import PDFKit
import SQLite3

struct ResearchHit: Identifiable, Codable, Sendable {
    var id: String
    var paperID: UUID
    var title: String
    /// One-based PDF page; zero means metadata only, not a source passage.
    var page: Int
    var text: String
    var revision: String
    var score: Double
}
struct ResearchCoverage: Sendable {
    var indexed: Int
    var total: Int
    var pages: Int
    /// Includes partial extraction and unavailable/over-budget documents.
    var failed: Int
}

/// Rebuildable, device-local cache. Call indexing off the main actor.
/// Connection access is serialized. No PDF objects escape the extraction scope.
final class ResearchIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let maxFileBytes = 128 * 1024 * 1024
    private let maxTextBytes = 2 * 1024 * 1024
    private let maxPages = 500

    init(root: URL) throws {
        directory = root.appendingPathComponent("ResearchIndex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("evidence-v1.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw ShelfError.message("Could not open the research index")
        }
        do {
            sqlite3_busy_timeout(db, 2000)
            // SQLite file capped at 128 MiB; rollback journal can temporarily double that.
            try execute("PRAGMA journal_mode=DELETE; PRAGMA page_size=4096; PRAGMA max_page_count=32768; PRAGMA cache_size=-4096; PRAGMA mmap_size=0; PRAGMA temp_store=FILE;")
            try execute("CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,title TEXT NOT NULL,revision TEXT NOT NULL,status TEXT NOT NULL,pages INTEGER NOT NULL); CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(paper UNINDEXED,title,text,page UNINDEXED,revision UNINDEXED,tokenize='unicode61');")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }

    private func error() -> Error { ShelfError.message("Research index: " + String(cString: sqlite3_errmsg(db))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw error() }
        for (i, value) in values.enumerated() {
            if sqlite3_bind_text(result, Int32(i + 1), value, -1, transient) != SQLITE_OK {
                sqlite3_finalize(result); throw error()
            }
        }
        return result
    }
    private func write(_ sql: String, _ values: [String] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
    }
    private func string(_ s: OpaquePointer, _ column: Int32) -> String {
        guard let p = sqlite3_column_text(s, column) else { return "" }
        return String(cString: p)
    }
    private func storedRevision(_ id: String) throws -> String? {
        let s = try statement("SELECT revision FROM documents WHERE id=? AND status='complete'", [id])
        defer { sqlite3_finalize(s) }
        let code = sqlite3_step(s)
        if code == SQLITE_ROW { return string(s, 0) }
        guard code == SQLITE_DONE else { throw error() }; return nil
    }
    private func check(_ cancelled: () -> Bool) throws { if cancelled() { throw CancellationError() } }

    func index(papers: [Paper], files: URL, cancelled: @escaping () -> Bool, progress: @escaping (Int, Int) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default, base = files.resolvingSymlinksInPath()
        // Temp membership table avoids SQLite parameter limits on large libraries.
        try execute("CREATE TEMP TABLE IF NOT EXISTS active_ids(id TEXT PRIMARY KEY); DELETE FROM active_ids;")
        for paper in papers { try check(cancelled); try write("INSERT OR IGNORE INTO active_ids VALUES(?)", [paper.id.uuidString]) }
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("DELETE FROM passages WHERE paper NOT IN (SELECT id FROM active_ids); DELETE FROM documents WHERE id NOT IN (SELECT id FROM active_ids); COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
        progress(0, papers.count)
        for (offset, paper) in papers.enumerated() {
            try check(cancelled)
            let id = paper.id.uuidString
            if !paper.hasPDF {
                try replaceMetadata(paper, status: "metadata")
                progress(offset + 1, papers.count); continue
            }
            let source = base.appendingPathComponent(paper.filename).resolvingSymlinksInPath()
            let snapshot = directory.appendingPathComponent("snapshot-\(UUID()).pdf")
            defer { try? fm.removeItem(at: snapshot) }
            var revision = ""
            do {
                guard source.deletingLastPathComponent() == base else { throw ShelfError.message("PDF outside managed directory") }
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= maxFileBytes else { throw ShelfError.message("PDF exceeds indexing budget") }
                revision = try Importer.hash(source)
                try check(cancelled)
                if try storedRevision(id) == revision {
                    try write("UPDATE documents SET title=? WHERE id=?", [paper.title, id])
                    // Titles are indexed too; keep FTS in agreement after metadata edits.
                    try write("UPDATE passages SET title=? WHERE paper=? AND title<>?", [paper.title, id, paper.title])
                    progress(offset + 1, papers.count); continue
                }
                try fm.copyItem(at: source, to: snapshot)
                guard try Importer.hash(snapshot) == revision else { throw ShelfError.message("PDF changed while snapshotting") }
                try autoreleasepool {
                    guard let document = PDFDocument(url: snapshot), !document.isLocked, document.pageCount > 0,
                          document.pageCount <= maxPages else { throw ShelfError.message("PDF unavailable or exceeds page budget") }
                    try execute("BEGIN IMMEDIATE;")
                    do {
                        try write("DELETE FROM passages WHERE paper=?", [id])
                        var bytes = 0, extracted = 0, partial = false, exhausted = false
                        for page in 0..<document.pageCount {
                            try check(cancelled)
                            try autoreleasepool {
                                let raw = document.page(at: page)?.string ?? ""
                                let text = String(raw.prefix(30000))
                                if raw.count > 30000 { partial = true }
                                if bytes + text.utf8.count > maxTextBytes { partial = true; exhausted = true; return }
                                bytes += text.utf8.count
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    try write("INSERT INTO passages(paper,title,text,page,revision) VALUES(?,?,?,?,?)", [id, paper.title, text, String(page + 1), revision])
                                    extracted += 1
                                }
                            }
                            if exhausted { break }
                        }
                        try check(cancelled)
                        guard try Importer.hash(source) == revision else { throw ShelfError.message("PDF changed during extraction") }
                        let status = partial || extracted == 0 ? "partial" : "complete"
                        try write("INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?)", [id, paper.title, revision, status, String(extracted)])
                        try execute("COMMIT;")
                    } catch { try? execute("ROLLBACK;"); throw error }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Do not retain stale passages when the current file cannot be verified.
                // Storage errors still propagate if recording this failure cannot succeed.
                try replaceMetadata(paper, status: "failed", revision: revision)
            }
            try? fm.removeItem(at: snapshot)
            progress(offset + 1, papers.count)
        }
    }
    private func replaceMetadata(_ paper: Paper, status: String, revision: String = "") throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try write("DELETE FROM passages WHERE paper=?", [paper.id.uuidString])
            try write("INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?)", [paper.id.uuidString, paper.title, revision, status, "0"])
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    func search(_ query: String, paperIDs: [UUID]? = nil, limit: Int = 20) throws -> [ResearchHit] {
        lock.lock(); defer { lock.unlock() }
        let bounded = max(0, min(limit, 50)); guard bounded > 0 else { return [] }
        let tokens = String(query.prefix(1024)).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(16)
        guard !tokens.isEmpty else { return [] }
        try execute("CREATE TEMP TABLE IF NOT EXISTS search_ids(id TEXT PRIMARY KEY); DELETE FROM search_ids;")
        if let paperIDs {
            guard !paperIDs.isEmpty else { return [] }
            for id in paperIDs { try write("INSERT OR IGNORE INTO search_ids VALUES(?)", [id.uuidString]) }
        }
        let scope = paperIDs == nil ? "" : " AND paper IN (SELECT id FROM search_ids)"
        let match = tokens.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
        let s = try statement("SELECT paper,title,page,snippet(passages,2,'','',' … ',48),revision,bm25(passages,0,2,1,0,0) FROM passages WHERE passages MATCH ?\(scope) ORDER BY bm25(passages,0,2,1,0,0) LIMIT ?", [match, String(bounded)])
        defer { sqlite3_finalize(s) }
        var hits: [ResearchHit] = []
        while true {
            let code = sqlite3_step(s); if code == SQLITE_DONE { break }; guard code == SQLITE_ROW else { throw error() }
            guard let id = UUID(uuidString: string(s, 0)) else { continue }
            let page = Int(sqlite3_column_int(s, 2)), revision = string(s, 4)
            hits.append(ResearchHit(id: "\(id)-\(revision)-\(page)", paperID: id, title: string(s, 1), page: page, text: String(string(s, 3).prefix(2000)), revision: revision, score: -sqlite3_column_double(s, 5)))
        }
        if hits.count < bounded {
            let filter = paperIDs == nil ? "" : " AND id IN (SELECT id FROM search_ids)"
            let clauses = tokens.map { _ in "title LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            let t = try statement("SELECT id,title,revision FROM documents WHERE (\(clauses))\(filter) ORDER BY title,id LIMIT ?", tokens.map { "%" + $0 + "%" } + [String(bounded)])
            defer { sqlite3_finalize(t) }
            var present = Set(hits.map(\.paperID))
            while hits.count < bounded {
                let code = sqlite3_step(t); if code == SQLITE_DONE { break }; guard code == SQLITE_ROW else { throw error() }
                guard let id = UUID(uuidString: string(t, 0)), present.insert(id).inserted else { continue }
                hits.append(ResearchHit(id: "\(id)-metadata", paperID: id, title: string(t, 1), page: 0, text: "Metadata match; no source passage retrieved.", revision: string(t, 2), score: 0))
            }
        }
        return hits
    }
    func coverage(papers: [Paper]) throws -> ResearchCoverage {
        lock.lock(); defer { lock.unlock() }
        var result = ResearchCoverage(indexed: 0, total: papers.count, pages: 0, failed: 0)
        for paper in papers {
            let s = try statement("SELECT status,pages FROM documents WHERE id=?", [paper.id.uuidString]); defer { sqlite3_finalize(s) }
            let code = sqlite3_step(s)
            if code == SQLITE_ROW {
                let status = string(s, 0)
                if status == "complete" { result.indexed += 1 }
                if status == "failed" || status == "partial" { result.failed += 1 }
                result.pages += Int(sqlite3_column_int(s, 1))
            } else if code != SQLITE_DONE { throw error() }
        }
        return result
    }
    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do { try execute("DELETE FROM passages; DELETE FROM documents; COMMIT;") }
        catch { try? execute("ROLLBACK;"); throw error }
        try execute("VACUUM;")
    }
}
