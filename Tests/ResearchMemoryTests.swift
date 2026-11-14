import Foundation

/// Optional, synthetic retained-memory smoke test, not a PDFKit peak-memory guarantee.
@MainActor func runResearchMemoryTests() throws {
    func rssBytes() throws -> Int64 {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
        task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let kib = Int64(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ShelfError.message("Could not measure test process RSS using ps")
        }
        return kib * 1024
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("chimpread-memory-\(UUID())")
    let files = root.appendingPathComponent("PDFs", isDirectory: true)
    try fm.createDirectory(at: files, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let pdf = files.appendingPathComponent("synthetic.pdf")
    try autoreleasepool { try fixturePDF(at: pdf, title: "Synthetic memory demonstration", pages: 3) }
    let hash = try Importer.hash(pdf)
    let papers = (0..<100).map { Paper(title: "Synthetic record \($0)", filename: "synthetic.pdf", sourceHash: hash) }
    func cycle(rebuild: Bool) throws {
        try autoreleasepool {
            let index = try ResearchIndex(root: root)
            if rebuild { try index.clear() }
            try index.index(papers: papers, files: files, cancelled: { false }, progress: { _, _ in })
            let coverage = try index.coverage(papers: papers)
            guard coverage.indexed == 100, coverage.pages == 300, coverage.failed == 0 else {
                throw ShelfError.message("Memory test did not index all 100 synthetic records / 300 page references")
            }
            for query in ["demonstration", "collections", "annotations"] {
                let hits = try index.search(query, limit: 10)
                guard !hits.isEmpty, hits.count <= 10, hits.allSatisfy({ $0.page > 0 }) else {
                    throw ShelfError.message("Memory-test search is empty or exceeds its bound")
                }
            }
            // index is released here on every cycle; no retained hits or PDF objects.
        }
    }
    try cycle(rebuild: false)
    let baseline = try rssBytes()
    var maximum = baseline
    print("MEMORY warm baseline RSS: \(baseline / 1_048_576) MiB")
    for number in 1...10 {
        // Alternate actual re-extraction with cache reuse, rather than only no-op reindexing.
        try cycle(rebuild: number % 2 == 1)
        let rss = try rssBytes(); maximum = max(maximum, rss)
        print("MEMORY cycle \(number) retained RSS: \(rss / 1_048_576) MiB")
        guard rss - baseline <= 80 * 1_048_576 else {
            throw ShelfError.message("Synthetic retained RSS grew more than the generous 80 MiB smoke-test allowance")
        }
    }
    let indexFolder = root.appendingPathComponent("ResearchIndex")
    let artifacts = try fm.contentsOfDirectory(at: indexFolder, includingPropertiesForKeys: [.fileSizeKey])
    guard !artifacts.contains(where: { $0.lastPathComponent.hasPrefix("snapshot-") }) else {
        throw ShelfError.message("Index extraction leaked PDF snapshot files")
    }
    let diskBytes = try artifacts.reduce(Int64(0)) { total, file in
        total + Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    guard diskBytes <= 256 * 1_048_576 else { throw ShelfError.message("Synthetic index exceeds database plus journal disk allowance") }
    print("PASS synthetic memory smoke test: 100 records share one 3-page fixture; 10 cycles, maximum retained growth \((maximum - baseline) / 1_048_576) MiB; index disk \(diskBytes) bytes")
    print("LIMITS: ps samples this process after autoreleasepool/connection release, not peak allocations, swap, energy, UI responsiveness, or external model memory. Shared fixture tests repeated extraction, not heterogeneous/huge PDFs or a real 100-paper corpus. No private library accessed.")
}
