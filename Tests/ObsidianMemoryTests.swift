import Foundation
import PDFKit

/// Synthetic measurement only, executed on demand; never touches a personal vault.
@MainActor func runObsidianMemoryTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("chimpread-obsidian-memory-\(UUID())")
    let vault = root.appendingPathComponent("vault"), library = root.appendingPathComponent("library")
    try fm.createDirectory(at: vault, withIntermediateDirectories: true)
    try fm.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let pdf = root.appendingPathComponent("fixture.pdf")
    try autoreleasepool { try fixturePDF(at: pdf, title: "Export memory fixture", pages: 10) }
    try autoreleasepool {
        let document = PDFDocument(url: pdf)!
        for page in 0..<10 {
            for index in 0..<30 {
                let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20 + index * 10, width: 20, height: 10), forType: .text, withProperties: nil)
                annotation.contents = "A synthetic annotation \(page)-\(index) " + String(repeating: "evidence ", count: 20)
                annotation.setValue(UUID().uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: "/ChimpreadGroup"))
                document.page(at: page)!.addAnnotation(annotation)
            }
        }
        guard document.write(to: pdf) else { throw ShelfError.message("Cannot write memory fixture") }
    }
    let paper = Paper(title: "Memory fixture", filename: "fixture.pdf", sourceHash: "")
    func rss() throws -> Int {
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]; process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard let kib = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ShelfError.message("RSS unavailable") }
        return kib * 1024
    }
    func cycle() throws {
        let group = DispatchGroup(); group.enter()
        var outcome: Result<Void, Error>!
        DispatchQueue.global(qos: .utility).async {
            outcome = Result { try autoreleasepool {
                let snapshot = try ObsidianSnapshot.read(pdfURL: pdf)
                guard snapshot.annotations.count == 300 else { throw ShelfError.message("Incomplete memory fixture extraction") }
                _ = try ObsidianExporter.export(paper: paper, vault: vault, pdfURL: pdf, libraryRoot: library,
                    coverage: .complete(snapshot.annotations), sourceRevision: snapshot.revision)
            } }; group.leave()
        }
        group.wait(); try outcome.get()
    }
    try cycle(); let baseline = try rss(); var maximum = baseline
    print("OBSIDIAN memory warm baseline \(baseline / 1_048_576) MiB; 10 pages, 300 annotations")
    for number in 1...20 {
        try cycle(); let current = try rss(); maximum = max(maximum, current)
        print("OBSIDIAN cycle \(number): \(current / 1_048_576) MiB retained")
        guard current - baseline < 64 * 1_048_576 else { throw ShelfError.message("Retained memory exceeded 64 MiB smoke-test allowance") }
    }
    print("PASS 20 complete extraction/export cycles; maximum retained growth \((maximum - baseline) / 1_048_576) MiB")
    print("LIMITS: synthetic PDF; RSS sampled after release, not transient PDFKit allocations or real-vault performance. No watcher or vault enumeration.")
}
