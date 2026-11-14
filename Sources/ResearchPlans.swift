import Foundation
import Combine
import CryptoKit
import Darwin

// Only these four reversible organization fields are representable.
enum ResearchValue: Codable, Equatable {
    case strings([String]), integer(Int?), parent(UUID?)
    var display: String {
        switch self {
        case .strings(let values): return values.isEmpty ? "None" : values.joined(separator: ", ")
        case .integer(let value): return value.map(String.init) ?? "None"
        case .parent(let value): return value?.uuidString ?? "None"
        }
    }
}
struct ResearchProposal: Identifiable, Codable, Equatable {
    var id = UUID()
    var paperID: UUID
    var title: String
    var reason: String
    var field: String
    var before: ResearchValue
    var after: ResearchValue
    var beforeDisplay: String { before.display }
    var afterDisplay: String { after.display }
}
struct ResearchTransaction: Codable {
    var id = UUID()
    var proposals: [ResearchProposal]
    var undoOf: UUID?
    var status = "prepared"
}
struct ResearchPlanState: Codable {
    var version = 1
    var pending: [ResearchProposal] = []
    var dismissed: [ResearchProposal] = []
    var transactions: [ResearchTransaction] = []
    var legacyHashes: [String] = []
}

@MainActor final class ResearchPlans: ObservableObject {
    @Published private(set) var pending: [ResearchProposal] = []
    @Published private(set) var loadError: String?
    private unowned let store: ShelfStore
    private var state = ResearchPlanState()
    var url: URL { store.root.appendingPathComponent("research-plans.json") }
    init(store: ShelfStore) {
        self.store = store
        do { try locked { } } catch { loadError = error.localizedDescription }
    }
    func reload() throws { try locked { } }
    private func validateState() throws {
        guard state.version == 1, state.pending.count <= 10_000, state.dismissed.count <= 20_000,
              state.transactions.count <= 10_000, state.legacyHashes.count <= 10_000,
              Set(state.pending.map(\.id)).count == state.pending.count,
              Set(state.dismissed.map(\.id)).count == state.dismissed.count,
              Set(state.transactions.map(\.id)).count == state.transactions.count,
              Set(state.pending.map(\.id)).isDisjoint(with: Set(state.dismissed.map(\.id))),
              state.transactions.allSatisfy({ $0.proposals.count <= 500 && ["prepared", "committed", "aborted", "undone"].contains($0.status) }) else {
            throw ShelfError.message("Research plan history is invalid or at its safety limit. Preserve the file and review it before adding more work.")
        }
    }
    private func save() throws {
        try validateState()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        guard data.count <= 33_554_432 else { throw ShelfError.message("Research plan history exceeds the 32 MiB safety limit") }
        try data.write(to: url, options: .atomic)
    }
    // One sidecar writer across instances/processes; canonical writes also use ShelfStore CAS.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        guard store.writable else { throw ShelfError.message("Library is read-only") }
        let fd = open(store.root.appendingPathComponent("research-plans.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ShelfError.message("Cannot lock research plans") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ShelfError.message("Research plans are busy") }
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 33_554_432 else { throw ShelfError.message("Research plan history exceeds the 32 MiB safety limit") }
            let data = try Data(contentsOf: url)
            guard data.count <= 33_554_432 else { throw ShelfError.message("Research plan history exceeds the safety limit") }
            state = try JSONDecoder().decode(ResearchPlanState.self, from: data)
            try validateState()
        } else { state = ResearchPlanState() }
        // Receipts are written atomically with the actual field changes, never inferred from values.
        let disk = FileManager.default.fileExists(atPath: store.index.path) ? try JSONDecoder().decode(Library.self, from: Data(contentsOf: store.index)) : store.library
        let receipts = Set(disk.researchTransactionIDs ?? [])
        var recovered = false
        for i in state.transactions.indices where state.transactions[i].status == "prepared" {
            let transaction = state.transactions[i]
            state.transactions[i].status = receipts.contains(transaction.id) ? "committed" : "aborted"
            if receipts.contains(transaction.id) { finish(transaction) }
            recovered = true
        }
        if recovered { try save() }
        defer { pending = state.pending }
        let baseline = state
        do {
            let result = try body()
            loadError = nil
            return result
        } catch {
            state = baseline
            loadError = error.localizedDescription
            throw error
        }
    }
    private func finish(_ transaction: ResearchTransaction) {
        if let original = transaction.undoOf {
            if let i = state.transactions.firstIndex(where: { $0.id == original }) { state.transactions[i].status = "undone" }
        } else {
            let ids = Set(transaction.proposals.map(\.id))
            state.pending.removeAll { ids.contains($0.id) }
        }
    }
    private static func value(_ paper: Paper, _ field: String) throws -> ResearchValue {
        switch field {
        case "collections": return .strings(paper.collections)
        case "tags": return .strings(paper.tags)
        case "priority": return .integer(paper.priority)
        case "parentID": return .parent(paper.parentID)
        default: throw ShelfError.message("Unsupported organization field")
        }
    }
    private static func set(_ value: ResearchValue, field: String, paper: inout Paper) throws {
        switch (field, value) {
        case ("collections", .strings(let values)): paper.collections = try names(values)
        case ("tags", .strings(let values)): paper.tags = try names(values)
        case ("priority", .integer(let number)):
            guard number == nil || (-1_000_000...1_000_000).contains(number!) else { throw ShelfError.message("Invalid priority") }
            paper.priority = number
        case ("parentID", .parent(let parent)): paper.parentID = parent
        default: throw ShelfError.message("Invalid organization value")
        }
    }
    private static func names(_ values: [String]) throws -> [String] {
        guard values.count <= 500, Set(values).count == values.count,
              values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }) else { throw ShelfError.message("Invalid collection or tag names") }
        return values
    }
    private func add(_ paperID: UUID, field: String, value: ResearchValue, reason: String) throws {
        guard let paper = store.library.papers.first(where: { $0.id == paperID }), paper.organizationLocked != true else { throw ShelfError.message("Paper missing or manually locked") }
        let before = try Self.value(paper, field)
        guard before != value else { return }
        var candidate = paper; try Self.set(value, field: field, paper: &candidate)
        let proposal = ResearchProposal(paperID: paperID, title: paper.title, reason: String(reason.prefix(4000)), field: field, before: before, after: value)
        // Repeated scans cannot resurrect dismissed suggestions with unchanged evidence/values.
        if (state.pending + state.dismissed).contains(where: { $0.paperID == paperID && $0.field == field && $0.before == before && $0.after == value }) { return }
        state.pending.append(proposal)
    }
    func propose(paperIDs: [UUID], collection: String, reason: String) throws {
        try locked {
            let name = collection.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try Self.names([name])
            guard paperIDs.count <= 10_000 else { throw ShelfError.message("Choose at most 10,000 records per suggestion run") }
            for id in Set(paperIDs) {
                guard let p = store.library.papers.first(where: { $0.id == id }) else { throw ShelfError.message("Paper missing") }
                try add(id, field: "collections", value: .strings(Array(Set(p.collections + [name])).sorted()), reason: reason)
            }
            try save()
        }
    }
    func proposeChange(paperID: UUID, field: String, value: ResearchValue, reason: String) throws {
        try locked { try add(paperID, field: field, value: value, reason: reason); try save() }
    }
    // A transparent deterministic rule: an exact existing tag/collection-name match.
    func suggestFromMetadata() throws {
        try locked {
            guard store.library.papers.count <= 10_000 else { throw ShelfError.message("Metadata suggestions currently support at most 10,000 records") }
            for paper in store.library.papers where paper.organizationLocked != true && paper.archived != true && paper.parentID == nil {
                let matches = store.library.collections.filter { name in paper.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
                if !matches.isEmpty {
                    try add(paper.id, field: "collections", value: .strings(Array(Set(paper.collections + matches)).sorted()), reason: "Existing tags exactly match existing collection names (case-insensitive). Metadata rule; no content inference.")
                }
            }
            try save()
        }
    }
    func dismiss(_ ids: Set<UUID>) throws {
        try locked {
            guard ids.isSubset(of: Set(state.pending.map(\.id))) else { throw ShelfError.message("Suggestions changed; refresh review") }
            state.dismissed += state.pending.filter { ids.contains($0.id) }
            state.pending.removeAll { ids.contains($0.id) }; try save()
        }
    }
    func accept(_ ids: Set<UUID>) throws {
        try locked {
            guard !ids.isEmpty, ids.isSubset(of: Set(state.pending.map(\.id))) else { throw ShelfError.message("Suggestions changed; refresh review") }
            try apply(state.pending.filter { ids.contains($0.id) }, undoOf: nil)
        }
    }
    private func apply(_ proposals: [ResearchProposal], undoOf: UUID?) throws {
        guard !store.importing, !store.syncing else { throw ShelfError.message("Wait for import or sync to finish") }
        guard proposals.count <= 500, state.transactions.count < 10_000,
              (store.library.researchTransactionIDs ?? []).count < 10_000 else {
            throw ShelfError.message("Batch or transaction history safety limit reached. Use batches of at most 500; preserve full history before maintenance.")
        }
        var next = store.library
        var fields = Set<String>()
        for proposal in proposals {
            guard fields.insert("\(proposal.paperID):\(proposal.field)").inserted,
                  let i = next.papers.firstIndex(where: { $0.id == proposal.paperID }), next.papers[i].organizationLocked != true,
                  try Self.value(next.papers[i], proposal.field) == proposal.before else { throw ShelfError.message("A paper changed or is locked; refresh this batch. Nothing was applied.") }
            try Self.set(proposal.after, field: proposal.field, paper: &next.papers[i])
        }
        // Do not remove global collection names on undo: another record may now use them.
        next.collections = Array(Set(next.collections + next.papers.flatMap(\.collections))).sorted()
        try ShelfStore.validate(next)
        var transaction = ResearchTransaction(proposals: proposals, undoOf: undoOf)
        next.researchTransactionIDs = (next.researchTransactionIDs ?? []) + [transaction.id]
        state.transactions.append(transaction)
        try save() // durable prepared journal before the sole canonical writer
        guard store.commit(next) else {
            state.transactions[state.transactions.count - 1].status = "aborted"
            try save(); throw ShelfError.message(store.error ?? "Library save failed")
        }
        transaction.status = "committed"
        state.transactions[state.transactions.count - 1] = transaction
        finish(transaction)
        try save() // if interrupted, the canonical receipt finishes this on reopen
    }
    func undoLast() throws {
        try locked {
            guard let last = state.transactions.last(where: { $0.status == "committed" && $0.undoOf == nil }) else { throw ShelfError.message("No organization change to undo") }
            let inverse = last.proposals.map { p -> ResearchProposal in
                var result = p; result.before = p.after; result.after = p.before; return result
            }
            try apply(inverse, undoOf: last.id)
        }
    }
    @discardableResult func importLegacy() throws -> Bool {
        try locked {
            let input = store.root.appendingPathComponent("organization.json")
            guard FileManager.default.fileExists(atPath: input.path) else { return false }
            let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 4_194_304 else { throw ShelfError.message("Organization file too large") }
            let data = try Data(contentsOf: input)
            guard data.count <= 4_194_304 else { throw ShelfError.message("Organization file too large") }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard !state.legacyHashes.contains(hash) else { return false }
            let legacy = try JSONDecoder().decode(OrganizationUpdate.self, from: data)
            guard legacy.version == 1, Set(legacy.papers.map(\.id)).count == legacy.papers.count else { throw ShelfError.message("Invalid organization file") }
            var preview = store.library
            for entry in legacy.papers {
                guard let i = preview.papers.firstIndex(where: { $0.id == entry.id }), preview.papers[i].organizationLocked != true else { continue }
                if let parent = entry.parentID { preview.papers[i].parentID = parent }
                if let priority = entry.priority { preview.papers[i].priority = priority }
            }
            try ShelfStore.validate(preview)
            for entry in legacy.papers {
                guard let p = store.library.papers.first(where: { $0.id == entry.id }), p.organizationLocked != true else { continue }
                if let parent = entry.parentID { try add(entry.id, field: "parentID", value: .parent(parent), reason: "Legacy organization.json suggestion; external source, requires review.") }
                if let priority = entry.priority { try add(entry.id, field: "priority", value: .integer(priority), reason: "Legacy organization.json suggestion; external source, requires review.") }
            }
            state.legacyHashes.append(hash); try save(); return true
        }
    }
}
