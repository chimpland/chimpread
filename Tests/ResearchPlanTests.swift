import Foundation

@MainActor func runResearchPlanTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw ShelfError.message(name) }; print("PASS \(name)")
    }
    func rejects(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { print("PASS \(name)"); return }
        throw ShelfError.message(name)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chimpread-plans-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ShelfStore(root: root)
    let a = Paper(title: "One", tags: ["Screens"], filename: "one.pdf", sourceHash: "fixture")
    let b = Paper(title: "Two", filename: "two.pdf", sourceHash: "fixture-two")
    try check(store.commit(Library(papers: [a,b], collections: ["Screens"])), "Research fixture created")
    let plans = ResearchPlans(store: store)
    try plans.suggestFromMetadata()
    try check(plans.pending.count == 1 && store.library.papers[0].collections.isEmpty, "Metadata suggestions never auto-apply")
    try plans.accept(Set(plans.pending.map(\.id)))
    try check(store.library.papers[0].collections == ["Screens"], "Reviewed collection transaction applies")
    var edited = store.library.papers[0]; edited.notes = "Human note"; store.update(edited)
    try plans.undoLast()
    try check(store.library.papers[0].collections.isEmpty && store.library.papers[0].notes == "Human note", "Undo preserves unrelated human changes")
    try plans.propose(paperIDs: [a.id], collection: "Screens", reason: "Review")
    edited = store.library.papers[0]; edited.collections = ["Human"]; store.update(edited)
    try rejects("Stale field preconditions block entire apply") { try plans.accept(Set(plans.pending.map(\.id))) }
    try plans.dismiss(Set(plans.pending.map(\.id)))
    try plans.proposeChange(paperID: a.id, field: "priority", value: .integer(5), reason: "Review")
    try plans.accept(Set(plans.pending.map(\.id)))
    edited = store.library.papers[0]; edited.priority = 7; store.update(edited)
    try rejects("Undo cannot overwrite newer human priority") { try plans.undoLast() }
    try rejects("Unsupported destructive field rejected") { try plans.proposeChange(paperID: a.id, field: "filename", value: .strings(["replacement.pdf"]), reason: "Bad") }
    store.setParent(b.id, to: nil)
    try rejects("Manual locks enforced") { try plans.propose(paperIDs: [b.id], collection: "Screens", reason: "Locked") }
    let legacy = OrganizationUpdate(version: 1, papers: [.init(id: a.id, priority: 9)])
    try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("organization.json"))
    try check(store.refreshOrganization() && store.library.papers[0].priority == 7, "Legacy sidecar becomes pending without mutation")
    try check(!store.refreshOrganization(), "Legacy sidecar replay does not duplicate proposals")
    let refreshed = ResearchPlans(store: store)
    try check(refreshed.pending.count == 1, "Pending proposals survive reopening")
    // Simulate a crash after canonical commit but before sidecar finalization.
    var state = try JSONDecoder().decode(ResearchPlanState.self, from: Data(contentsOf: refreshed.url))
    let proposal = state.pending[0]
    let tx = ResearchTransaction(proposals: [proposal])
    state.transactions.append(tx)
    try JSONEncoder().encode(state).write(to: refreshed.url, options: .atomic)
    var next = store.library; next.papers[0].priority = 9
    next.researchTransactionIDs = (next.researchTransactionIDs ?? []) + [tx.id]
    try check(store.commit(next), "Prepared transaction fixture canonical commit")
    let recovered = ResearchPlans(store: store)
    try check(recovered.pending.isEmpty, "Crash recovery finalizes receipt-backed transaction once")
    try recovered.undoLast()
    try check(store.library.papers[0].priority == 7, "Recovered transaction retains conditional undo")
    // A prepared record without a receipt must never replay automatically.
    state = try JSONDecoder().decode(ResearchPlanState.self, from: Data(contentsOf: recovered.url))
    state.pending.append(proposal); state.transactions.append(ResearchTransaction(proposals: [proposal]))
    try JSONEncoder().encode(state).write(to: recovered.url, options: .atomic)
    let aborted = ResearchPlans(store: store)
    try check(aborted.pending.count == 1 && store.library.papers[0].priority == 7, "Uncommitted prepared transaction never auto-applies")
    try aborted.dismiss(Set(aborted.pending.map(\.id)))
    try aborted.proposeChange(paperID: a.id, field: "priority", value: .integer(11), reason: "First")
    let frozen = Set(aborted.pending.map(\.id))
    try aborted.proposeChange(paperID: a.id, field: "tags", value: .strings(["New"]), reason: "Later arrival")
    try aborted.accept(frozen)
    try check(aborted.pending.count == 1 && store.library.papers[0].tags == ["Screens"], "Frozen batch excludes later suggestions")
    edited = store.library.papers[0]; edited.organizationLocked = true; store.update(edited)
    try rejects("Lock added after proposal blocks acceptance") { try aborted.accept(Set(aborted.pending.map(\.id))) }
    edited.organizationLocked = false; store.update(edited)
    let otherStore = ShelfStore(root: root)
    var human = store.library.papers[0]; human.notes = "Newer human note"; store.update(human)
    var stale = otherStore.library; stale.papers[0].notes = "Stale overwrite"
    try check(!otherStore.commit(stale) && store.library.papers[0].notes == "Newer human note", "Multiple stores cannot overwrite a newer canonical save")
    // Duplicate inbox IDs are malformed, not an invitation to apply twice.
    state = try JSONDecoder().decode(ResearchPlanState.self, from: Data(contentsOf: aborted.url))
    state.pending.append(state.pending[0])
    let duplicateData = try JSONEncoder().encode(state)
    try duplicateData.write(to: aborted.url)
    let duplicate = ResearchPlans(store: store)
    try check(duplicate.loadError != nil, "Duplicate proposal IDs fail closed")
    try rejects("Duplicate state cannot be applied") { try duplicate.accept(Set(state.pending.map(\.id))) }
    let preservedDuplicate = try Data(contentsOf: aborted.url)
    try check(preservedDuplicate == duplicateData, "Invalid proposal state remains byte-for-byte preserved")
    // Corruption must not be replaced by an empty inbox.
    try Data("broken".utf8).write(to: aborted.url)
    let broken = ResearchPlans(store: store)
    try check(broken.loadError != nil, "Malformed proposal state fails closed")
    try rejects("Malformed proposal state cannot be overwritten") { try broken.dismiss([]) }
}
