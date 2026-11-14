# chimpread: an agent for your paper library

Draft • October 23, 2026 • Not an implementation or release commitment

## Direction

Make chimpread a library that helps Ben find, connect, and use his papers. The first priority is an agent that organizes the whole library and connects evidence across papers. Reading assistance, notes, writing, and Hermes support belong to the same system, rather than separate chat features.

The agent should answer three practical questions: **What do I have? How does it fit together? What should I read next for the thing I am working on?** A conversation is one way to ask; a well-organized library should remain useful without starting one.

This is a draft only. No library contents were inspected, no models were connected to personal papers, and no app, website, Hermes configuration, or scheduled task was changed for this research. References to FITdb, DUETqc, and paper editions are use cases from the conversation, not new classifications of actual documents.

## Product constraints

- Preserve a small, native macOS application. Reading, searching metadata, annotations, imports, and bibliography remain available without an AI account.
- Do not make a local model or a library-wide indexing job part of startup. Models, OCR, embeddings, and external services are optional, bounded work.
- Default to keeping original documents and human notes intact. A preprint and final article are related editions, not interchangeable duplicates.
- Every proposed organization change has a reason, a source, and a reversible result. Existing manual organization locks take precedence.
- Use the existing reader, notes pane, library sidebar, and native sheets. Avoid a second application embedded inside the reader.
- Keep new shortcuts to Command plus a single key where possible; audit existing bindings before assigning them. Preserve normal Undo/Redo and Enter-to-save note behavior.
- Whole-library intelligence means progressively maintained coverage, not sending the entire library to a model on every question.

## What exists today

The public source checkout was inspected; these are source observations, not performance measurements.

| Area | Existing implementation | Consequence for the update |
|---|---|---|
| Library | `Sources/Library.swift`: UUID records, collections, tags, parent attachment IDs, reading position, recency, priority, archive state, manual organization lock | Reuse identities and user choices; introduce explicit edition and evidence relationships separately from attachments |
| Persistence | `ShelfStore.commit` validates and atomically saves a full JSON index, checking whether the file changed | Keep one authority for writes; do not let independent agents mutate JSON |
| Organization | `refreshOrganization` ingests a version-1 `organization.json` sidecar with parent and priority updates | Existing sidecar applies changes directly; it is not a general proposal inbox or transaction journal |
| Reader | `Sources/Reader.swift`: one active PDF, selection bounds, grouped annotations, local note drafts, current-document undo | AI should consume immutable evidence snapshots and reuse source navigation; do not retain reader objects in agent jobs |
| MCP | `Sources/MCP.swift`: stdio read-only tools for metadata, pages, and saved notes; access toggles | Good initial Hermes bridge; needs richer provenance, scope, cancellation, and tighter output limits |
| Bibliography | `Sources/Citations.swift`: deterministic citeproc formatting and structured exports | Keep citation formatting outside the model |
| Sync | `Sources/CloudSync.swift`: immutable revisions and content-addressed PDFs; experimental conflict handling | Separate rebuildable local intelligence caches from accepted user artifacts; do not sync a live SQLite file |
| Browser | Native messaging and an optional Google Docs integration | Use existing import/proposal boundaries; do not make arbitrary websites trusted agent instructions |

### Foundations to address first

1. A library operation needs a durable transaction record, per-record preconditions, validation, and conflict-aware reversal. A single previous JSON snapshot is not durable batch undo.
2. Content evidence needs a revision identity. `Paper.sourceHash` records import provenance and cannot be assumed to describe a PDF after annotation edits.
3. Whole-library retrieval needs an on-disk, rebuildable index. Existing MCP search is metadata search; it is not semantic full-text retrieval.
4. MCP bounds must limit bytes/work across an entire response, not only each page or annotation. `read_notes` currently constructs all annotation rows before pagination.
5. MCP's blocking request loop and PDF operations need cancellation and bounded input framing before long agent jobs are introduced.

## The everyday experience

### First run: “Organize my library”

The first useful screen should answer the research question before asking the user to clean up metadata: **Start here** with up to three relevant papers, **Useful connections** with a few explained relationships, and optional **Improve this view** for coverage gaps. Inventory and cleanup must not become a prerequisite for finding something useful.

Open a native sheet showing the chosen scope, document count, and what the agent can inspect. Start with metadata and existing collections. Full text, notes, external metadata lookup, and remote-model processing are separate choices. Show the selected provider and a cost ceiling before remote processing.

Run a local inventory first. Count records, PDFs, missing files, exact file duplicates, candidate editions, attachments, and extraction coverage. Produce a useful result even when no model is configured.

The agent drafts a small number of useful collections and suggestions within the existing taxonomy. It does not generate hundreds of new tags. The review sheet groups proposals by purpose: fix metadata, group supporting files, connect editions, suggest collection membership, and suggest reading priority. Each group supports select, inspect, accept, reject, and undo after application.

Example: “These 8 papers may fit FITdb because their methods describe functional screens.” Opening the suggestion reveals the specific excerpts and existing collection precedents. This is an example of desired behavior, not a claim about Ben's library.

### Daily use: “What matters for my project?”

Give a collection an optional project brief: a few sentences describing the question, inclusion rules, exclusions, and what matters now. A paper can serve multiple projects. Project rules are explicit user-authored context, not instructions inferred from arbitrary document text.

Start with one sentence. Optional fields are **Question**, **Include**, **Exclude**, and **Right now**. A collection can back a project initially; no task-management dashboard is necessary.

The library shows a restrained **For this project** view: continue reading, newly relevant papers, unresolved questions, and a short list of suggested connections. Every rank can be explained. Reading history is one signal, not proof of importance; new papers should not be buried solely because they have never been opened.

Pin, dismiss, and manual ordering override the agent. Avoid constant reshuffling while the user is browsing. Refresh suggestions on explicit request or after an enabled, bounded maintenance run.

Keep the initial queue to three to five distinct works, selected for useful roles such as continue reading, foundation, direct evidence, or check an assumption. Do not fill mandatory slots with weak recommendations. Explain each role in a sentence rather than showing an invented relevance percentage.

### While reading: “Connect this to my library”

Select a passage and choose **Find related evidence**. The existing right pane presents a few source passages, with paper, edition, page, and relationship type. Clicking one opens the exact source. Returning restores the reading position and unsaved note draft.

Related results explain their connection: same experimental system, same measurement, different method, follow-up study, or a possible disagreement. Similar wording alone is not enough to label a contradiction or replication.

The same pane can explain the passage, define a term, compare methods, or draft a note. AI output is clearly distinct from the user's own note until saved. Saving as a note is explicit and retains evidence references and generated provenance.

### A single place for pending work

Use a **Suggestions** sidebar item with a quiet count. It contains proposed changes and unresolved identification questions, not a stream of agent narration. Show completed work and a compact job status only when useful. No animated assistant, floating chat bubble, or forced conversation on launch.

Separate **Discoveries** (derived relevance and suggested relationships, immediately viewable), **Suggestions** (changes requiring review), and **Saved research** (artifacts the user elects to retain). Looking at a suggested connection should not require approving a database mutation. The number of suggestions created is not a success metric; time to find a useful paper and reduced review work are.

### Feedback that means what the user intended

Dismiss suppresses that suggestion fingerprint. Optional reasons provide narrower signals: **Not relevant to this project**, **Wrong connection**, **Already know this**, **Not now**, or **Keep my organization**. Snoozing is not a negative scientific judgment; project rejection must not hide a paper everywhere. Store inspectable/resettable preferences. A provider change or model paraphrase is not sufficient new evidence to resurface a rejected result. Repeated acceptance can motivate a proposed rule but cannot silently grant broader autonomy.

## Organization model

### Keep these concepts separate

| Concept | Example | Rule |
|---|---|---|
| Library record | A user's saved reference | Stable UUID remains the user-facing identity |
| Work | An underlying research contribution | Can have several versions; inferred links remain reviewable |
| Edition | Preprint, accepted manuscript, version of record, correction | Preserve version and publication status; never silently swap PDFs |
| File | Main PDF, supplement, annotated copy | Byte identity is not intellectual-work identity |
| Attachment | Supplement belonging to a paper | Existing `parentID` is for this relationship, not all related works |
| Project | FITdb, DUETqc, a writing task | Many-to-many membership; no duplicated PDF required |
| Evidence | A quote/table region with source coordinates | Bound to the source revision from which it was extracted |
| Interpretation | A summary, relation, or proposed conclusion | Carries model/run provenance and support; never masquerades as a source quote |

### Duplicate and edition handling

- Exact SHA-256 matches can support file-deduplication candidates, with explicit checks for annotations and reference memberships before any removal.
- DOI, title, authors, and year produce identity candidates with field-level evidence; a model's confident assertion is insufficient.
- A preprint/final pair should normally be linked as editions. Offer **Prefer published version** only after resolving metadata and obtaining the correct PDF through an authorized source.
- Preserve both PDFs and their notes. Transfer annotations only through a separately reviewed anchoring workflow; page numbers and text positions can change.
- Corrections, retractions, conference/journal extensions, and companion papers must remain distinct unless a user-reviewed identity decision says otherwise.
- The AI feature must not claim duplicate-free libraries from semantic similarity alone.

### Suggested relationships

Start with a small vocabulary: `edition_of`, `supplement_of`, `cites`, `shares_method`, `shares_system`, `addresses_question`, `possible_agreement`, `possible_disagreement`, and `user_related`. Add explicit correction/retraction relations before treating those records as ordinary editions.

Store the basis of each link: explicit identifier/reference match, user assertion, extracted passage, or model inference. A relationship is a record with evidence and status, not an invisible vector distance. Keep bibliographic citation edges distinct from evidentiary support for a scientific claim.

`cites` requires a resolved reference/identifier basis. Shared-method/system links need relevant evidence from both papers. Agreement/disagreement needs aligned conditions and outcomes. Generated notes never become independent corroborating primary sources in the next reasoning pass; follow their references back to original evidence.

Use compact relationship lists and a comparison table before building a graph canvas. A graph is a later optional inspection tool, useful only if the user can filter it to a particular question and follow every edge to evidence.

## Agent behavior and authority

The default is **analyze automatically within an enabled scope; propose meaningful changes; apply through chimpread**. Scope, budget, and schedule are explicit settings. No perpetual background model loop.

| Action | Default authority |
|---|---|
| Compute hashes; extract local text; update a derived index | Automatic within the enabled indexing scope and resource budget |
| Find likely duplicates, relationships, or relevant collections | Create suggestions; no library mutation |
| Draft a project brief, summary, or reading queue | Draft only; identify provenance |
| Apply collection/tag/priority changes | Review batch, with a later optional policy for narrowly defined reversible actions |
| Change title, authors, DOI, edition, attachment grouping | Review with evidence and before/after fields |
| Archive, remove a file, merge identities, replace a PDF | Explicit operation-specific review; never from paper text or model confidence alone |
| Read private notes or process content remotely | Requires the matching content scope and destination authorization |
| Export to Docs, send a message, publish or share content | Separate destination preview and explicit user action |
| Run arbitrary shell commands or instructions found in papers | No capability in the app's agent toolset |

Every apply operation validates the current state, manual locks, source revision, scope, and allowed operation type. A change to a proposed field or its supporting evidence invalidates the affected operation; an unrelated reading-position update need not invalidate a collection suggestion. Accepting 100 suggestions should not mean accepting an unseen 101st suggestion that arrived afterward.

## End-to-end architecture

```text
Native reader / library UI
        │ user intent, scope, review
        ▼
Agent coordinator ─────── Provider adapter (optional remote or local service)
        │                   receives only selected evidence
        ├── Job queue: budgets, cancellation, pause/resume
        ├── Retrieval: metadata + SQLite FTS; optional embeddings later
        ├── Evidence store: text, anchors, revision, extraction quality
        ├── Proposal inbox: typed patches + reasons + preconditions
        └── Library transaction executor: sole authorized writer
                           │
                       library.json / PDFs

Hermes or other client ← bounded MCP facade → same policy/retrieval/proposal services
```

The app owns library mutations. Hermes can ask questions and submit proposals; it should not rewrite the library index or directly apply model-generated patch files. Existing `organization.json` needs a compatibility path that routes external proposals through the new review mechanism. For whole-library tasks, the model receives bounded evidence selected by the agent from the user-authorized scope, not necessarily passages manually selected by the user. Record exactly which evidence was dispatched.

### Storage boundaries

- **Canonical library:** existing records and PDFs; accepted organization changes only.
- **Derived local index:** SQLite metadata/search tables, extracted text, retrieval features, optional embeddings, coverage state. Rebuildable and evictable.
- **Evidence/proposal store:** durable references, accepted AI notes, proposal state, review outcomes, transactions. Treat accepted user artifacts differently from disposable cache entries.
- **Local secrets/settings:** Keychain credentials, provider endpoint preferences, permission grants, local job controls. Never sync API keys through the library.
- **Sync:** versioned accepted artifacts only after conflict semantics are implemented. Do not sync live database journals, model weights, prompt caches, or device-specific processing state.

Do not silently migrate the entire canonical library to SQLite as a side effect of AI work. First use SQLite as a derived store and explicitly version new durable artifact formats. Reassess canonical storage separately if transaction requirements outgrow the current JSON model.

### Proposed contracts

These are design sketches, not implemented schemas.

```text
EvidenceRef
  paperID, editionID?, fileRevision, textRevision, extractorVersion
  pdfPageIndex, printedPageLabel?, bounds[], textSpan, quote
  extractionMethod, extractionWarnings, evidenceKind

Relation
  id, sourcePaperID, targetPaperID, relationType
  basis: identifier | user | passage | inference
  evidenceRefs[], explanation, status, runID?

OrganizationProposal
  id, scopeID, baseLibraryRevision, sourceRevisions[]
  operations[] { recordID, field, expectedValue, proposedValue }
  reasons[], evidenceRefs[], conflicts[], runID, expiresAt?

AppliedTransaction
  id, acceptedProposalIDs[], beforeValues, afterValues
  appliedAt, resultingRevision, inversePreconditions

AgentRun
  id, task, scope, permissionSnapshot, provider, modelVersion?
  promptTemplateVersion, evidenceRefs[], usage, budget, status
```

A verified quote match proves where a quote came from; it does not prove that a generated conclusion follows from it. Structural citation validation and scientific support review are separate checks.

## Retrieval and indexing

1. Enumerate metadata and files without opening every PDF at once.
2. Detect changed items using file metadata as a cheap hint, then compute trustworthy revision identity when needed. Retain both raw file and normalized text revisions so annotation-only saves need not force all semantic processing to repeat.
3. Extract one bounded document/page batch at a time in an isolated worker; return immutable text/anchor records. Release PDFKit objects between jobs.
4. Record extraction coverage and failures explicitly. A blank scanned page is an extraction problem, not evidence that the paper contains no relevant result.
5. Build FTS search first. Combine it with project/metadata filters and citation-aware ranking.
6. Add embeddings only if an evaluation shows enough retrieval gain to justify memory, disk, privacy, and maintenance costs. Treat embedding services as content recipients too.
7. Retrieve a bounded candidate set, diversify across works/editions, and build an evidence packet sized to the task. Do not mistake a long context window for a retrieval strategy.
8. Preserve supplements and tables as discoverable sources while exposing extraction limitations. Add OCR and visual region analysis on demand, not a default full-library pass.

Answers must report the searched scope and useful coverage limits: “Searched 64 indexed papers in this collection; 9 scanned PDFs are not indexed.” Do not claim exhaustive absence based on a partial index or top-k retrieval.

## Resource and cost policy

All numeric budgets below are proposed starting points for benchmarking, not measurements of today's app.

- One extraction worker and one interactive model request by default. Interactive reading preempts maintenance work.
- Pause background indexing during memory pressure, import, conflicting sync work, or an explicit pause. Expose a resume action and progress that survives restart.
- Use a hard maximum evidence/output byte budget and a maximum number of agent steps per run. A model cannot raise its own limits.
- Before a library-wide remote run, estimate coverage, requests, and cost using the configured model's current published rates; conservatively reserve against a user-approved dispatch budget before each call and stop authorizing work when it is exhausted. This bounds app-authorized requests, not a guaranteed provider account bill: unknown timeout outcomes, changed rates and separate Hermes activity require reconciliation. Do not invent fixed dollar estimates before measuring the library.
- Make model retention visible. A local backend may keep weights resident after chimpread disconnects; never promise a memory cap for an external process the app does not control.
- Benchmark 100, 1,000, and 10,000-reference libraries, long papers, huge scanned PDFs, annotation-heavy files, and malformed documents. Record app and child-process RSS, peak working set, UI responsiveness, energy, disk growth, cancellation latency, and return-to-idle behavior.
- With AI off, aim for no persistent model/indexing worker and no unsolicited remote requests. Opening the reader must not wait on index completion or provider availability.

## Provider strategy

Keep provider-neutral task and evidence interfaces. The core library agent can inventory, search, expose candidate duplicates, and manage review without a generative model. Models enhance inference and prose; they do not become the database.

Support one remote provider and one optional local-service adapter first, chosen against the same test corpus. Add other providers only through explicit adapter contracts and tests. Do not bundle model weights or require a new subscription to use the reader.

Explain costs honestly: the app can remain free while a chosen remote model charges usage. A user's chat subscription is not automatically an API entitlement. Local inference has hardware, memory, and energy costs even without a per-call bill.

An operating-system model may later help with small structured tasks on supported machines. It must remain a capability-detected enhancement, not a reason to abandon the current macOS 14 baseline or to claim every Mac has a suitable model.

## Hermes and MCP

Keep the current stdio route for read access, but expose the same bounded services used internally. Do not add a publicly reachable server merely to enable an agent.

Potential tools, introduced in stages:

- `library_status`: scope, index coverage, extraction failures, revision.
- `search_evidence`: bounded keyword/semantic results with evidence IDs and coverage.
- `get_evidence`: exact cited spans, revision checks, adjacent context within bounds.
- `get_related_papers`: typed relationships and their reasons.
- `list_projects` and `get_project_brief`: authorized project context.
- `propose_organization`: submit typed changes to the review inbox, not direct mutation.
- `propose_note`: save a generated draft for user review, without replacing existing notes.
- `job_status` and `cancel_job`: bounded work management.

Tools should return structured errors for scope denial, stale revisions, missing PDFs, extraction failure, budget exhaustion, and cancellation. Pagination must bound computation as well as response size.

Do not imply that a stdio client name proves identity. Design per-client/per-scope access deliberately, with least-privilege launch configuration and a clear threat model for other processes running as the same local user. Switching off access must stop future reads and scheduled jobs; it cannot retract text already sent to a provider.

Hermes scheduling is a later, explicitly enabled workflow: watch imports and refresh suggestions within a defined project, budget, and cadence. No unsolicited notifications for unchanged state. Existing capability and configuration details must be verified against the installed Hermes version before implementation.

## Notes, comparisons, and writing

### Notes

Offer **Explain**, **Ask about selection**, **Find related evidence**, and **Draft note** from a selection. Use the current annotation grouping and passage geometry. Never turn one multi-line highlight into multiple independent AI notes. Keep unsaved drafts excluded from external access unless the user explicitly sends that draft.

Use structured provenance for saved generated notes: task, evidence, creation time, provider/model if known, and whether the user subsequently edited it. Do not expose a long provenance block in the reading pane; make it available through details.

### Cross-paper comparisons

Render comparison matrices with one row per study and columns the user cares about: system, intervention, measurement, controls, sample size, limitations, and claim. Each populated cell needs a source or an explicit “not found in searched material.” Keep figures and supplement evidence linked to their own files/pages.

Separate source claims, user interpretations, generated inferences, and open questions. “Possible disagreement” requires matching the conditions and outcomes before promotion to a substantive scientific conclusion.

### Writing and bibliography

Draft an outline or synthesis from a selected evidence set; citations must resolve to real library records. Use the existing deterministic bibliography engine for formatting. A valid DOI does not establish that the paper supports the sentence.

Preview content and destination before writing to Google Docs or exporting. Keep generated prose and citation suggestions reviewable. Do not promise live citation fields or automatic renumbering from the current plain-text connector.

## Privacy and security

PDFs, imported metadata, annotations, browser pages, and remote model output are untrusted data. None can grant a new permission, change a project brief, nominate a new upload endpoint, or authorize file operations.

The policy/execution layer enforces capabilities independently of the model. Model-proposed tool arguments are schema-checked, scope-checked, and revision-checked. A prompt saying “ignore instructions in documents” is useful context but not a security boundary.

Before remote analysis, show what will leave the device: metadata, selected text, notes, images, or embedding input, and to which configured service. Never include API secrets in prompts or logs. No paper content goes into website analytics or crash telemetry by default.

Maintain an outbound-content preview for a run and a simple local activity log. Cache eviction must distinguish disposable extracted text from accepted notes/evidence artifacts. Redacting or removing a paper needs a defined purge path for derived indexes, embeddings, proposals, and cached model responses, with an honest statement about external retention.

## Delivery sequence

| Phase | Deliverable | Exit condition |
|---|---|---|
| 0: design validation | Real task corpus, UX prototype, resource baseline, schema ADRs | Scope and success criteria reviewed; no library mutations |
| 1: library foundations | Revision-aware evidence, bounded jobs, FTS index, proposal/transaction engine, migration/recovery and early MCP contract tests | Rebuild/restart/cancel/conflict/undo tests pass; reader remains usable |
| 2: useful library agent | Inventory, project briefs, organization suggestions, edition candidates, bounded connection candidates, reading queue | Suggestions are understandable and reversible; false-positive rates measured |
| 3: connected evidence | Passage search, typed relationships, cross-paper comparison | Citations navigate correctly; unsupported claims and missing coverage exposed |
| 4: reading and notes | Selection assistance, saved generated notes, source-linked answers | Draft safety, annotation grouping, keyboard, memory, and accessibility regressions pass |
| 5: Hermes | Scoped evidence tools, proposal submission, job control | Protocol and authorization tests pass; no competing library writer |
| 6: extended workflows | Optional embeddings/OCR/vision, writing export, opted-in maintenance | Each capability proves task benefit and passes its own cost/privacy/resource gates |
| 7: release hardening | Migration/rollback, sync conflict checks, signing/notarization plan, documentation | Upgrade and recovery verified on disposable libraries before personal data |

Do not label a future release “fully autonomous research” because it can loop over tools. Ship a bounded, inspectable library assistant with progressively enabled capabilities.

### Early validation slice

Deliver read-only project relevance and a short explained queue while the transaction foundation is being developed. Then add source-backed connections and selection-to-library search. Canonical changes wait for reviewed transactions and undo. This gives useful library-first feedback early without weakening the mutation gates. Exercise MCP read/proposal contracts as each service appears; a polished Hermes workflow can follow later.

## Open decisions

1. How much autonomy should be allowed after a user has repeatedly accepted a particular collection rule?
2. Should project briefs be shared with Hermes by default within a project grant, or selected per run?
3. Which provider/backend should be the first supported adapter? Decide with task evaluation and hardware measurements, not brand preference.
4. Which accepted AI artifacts should sync across Macs, and how should concurrent edits merge?
5. What is the minimum useful relationship vocabulary for actual research tasks?
6. How much organization can deterministic metadata rules accomplish before any model call?
7. Should trusted “published version” resolution be included in the first library-agent release or a separate import improvement?

## Research review status

Three Astra review tracks completed research and a second pass against the user's whole-library priority: product/UX; architecture/Hermes; and risk/evaluation. No claim is made that hundreds of independent agents were run. The companion [implementation backlog](ai-update-backlog.md) converts the proposal into dependency-ordered tickets.

### Where the reviewers differed

The product and risk reviewers initially recommended passage assistance before a whole-library agent. That would reduce initial scope, but it does not match the user's chosen priority. The architecture reviewer recommended a library-first MVP with evidence and transaction foundations. This draft follows that direction while adopting the other reviews' provenance and permission safeguards. “Library first” does not require destructive autonomy or an unbounded full-text model scan.

### Additional engineering findings

- MCP metadata search repeatedly scans for parents within its filter; an ID map would avoid quadratic work. The full JSON library is also decoded for each tool request.
- The annotation synchronization timer inspects annotation state across pages every second. Profile this existing work before adding indexing; do not attribute all future memory/CPU issues to the model.
- The current organization sidecar has no explicit `clear` operation for a parent assignment. New plans must distinguish “leave unchanged” from “clear this value.”
- A prepared/committed transaction journal is needed around metadata application. An atomic JSON write alone does not atomically update an independent history file. Recovery must identify whether an operation committed before replaying or reversing it.
- A helper process offers a termination boundary for pathological PDF parsing; cancelling a Swift task cannot guarantee interruption of a synchronous PDFKit call.
- The app being an MCP server does not make Hermes an in-app streaming agent API. Reverse invocation requires a separately supported and verified integration.
- Archive visibility is not currently a confidentiality boundary. Authorization scopes must be enforced on direct-ID reads as well as search.

## Proposed decisions after architecture review

These choices make the draft concrete enough to review. They are not implemented migrations.

1. **A paper record represents a saved reference/edition, not an abstract work.** Introduce a separate optional `WorkRecord` with its own ID. An edition references that work ID; uncertain matches remain proposals. A work does not need a PDF. Preserve existing paper UUIDs and annotate identity decisions rather than collapsing them.
2. **`parentID` remains the attachment authority.** Expose `supplement_of` as a computed relation from the accepted attachment structure, not a second independently writable field. Define symmetric relation types with canonical endpoint ordering to avoid duplicate reversed edges.
3. **Add canonical commit identity through an explicit library schema upgrade.** Stage immutable artifacts, durably write a prepared journal record, atomically write the library containing the resulting commit ID, then finalize journal status. Recovery reconciles by commit identity, not coincidental equality of values. The implementation must specify durability/fsync boundaries and test power-loss/disk-full behavior.
4. **Enforce a real single-writer ownership mechanism.** Existing read-compare-write protection is useful but not an interprocess lock. Helpers and Hermes submit intents; all accepted UI/import/sync/organization changes enter the same executor. A process that loses writer ownership cannot commit.
5. **Define three storage classes.** Derived caches can be deleted/rebuilt. Accepted evidence/notes/relations are durable user artifacts. Job checkpoints, transaction journals and review decisions are durable operational state. They need independent retention and backup rules.
6. **Pin accepted evidence excerpts and provenance.** Retaining every old PDF forever is not the default. If its revision is no longer available, show the saved excerpt and mark exact-document navigation unavailable; never jump silently to a changed page. Offer optional revision retention with a visible storage cost. A paper purge explicitly explains its effect on pinned evidence.
7. **Keep new AI artifacts local initially.** Future sync requires a versioned envelope, tombstones, conflict rules and old-client behavior. Do not put fields into a v1 record that an old client could silently drop on save. A migration must fail safely in an old build; cross-device upgrade requirements are surfaced before enabling new synced state.
8. **Use immutable run scope plus live authorization checks.** Capture selected IDs and allowed data classes at start, but recheck the current grant immediately before reads, dispatches and commits. New project members do not silently expand an existing run. Revocation cancels queued sends and stops new work.
9. **Do not claim exactly-once remote inference.** A timeout may have an unknown billed outcome. Persist request identity and outcome uncertainty; do not automatically repeat potentially paid work after restart. Local stages and accepted patches can be idempotent even when an external service cannot guarantee that property.
10. **Connect papers with bounded neighborhoods.** Use hash/identifier maps and top-k lexical/metadata neighbors, then optional embeddings. Limit evaluations per paper/run and invalidate only affected neighborhoods after updates. Measure candidate recall separately from the model's relationship-label accuracy. No all-pairs library comparison.
11. **Retire the sidecar review bypass.** Import legacy organization suggestions into the proposal inbox, preserving locks and compatibility explanations. Do not leave an auto-apply route for new agents just because the old format was trusted locally.
12. **Scope job control precisely.** MCP cancellation controls chimpread-owned jobs. It cannot promise to stop an unrelated Hermes run or retract a request already received by a provider.

## Evidence and reference notes

External links below were consulted by the Astra research tracks. Implementation must recheck version-specific capabilities and the installed Hermes version. Provider prices and hardware performance were deliberately not estimated without measurements.

- [Hermes MCP documentation](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/mcp.md): existing client connection/configuration behavior; not evidence for an embedded Hermes API.
- [MCP cancellation specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation): protocol cancellation distinct from terminating a synchronous parser.
- [MCP security guidance](https://modelcontextprotocol.io/docs/draft/tutorials/security/security_best_practices): capability, credential, and external-service boundaries; draft documentation may evolve.
- [SQLite WAL](https://www.sqlite.org/wal.html): same-host coordination requirements; do not use file synchronization as a live-database protocol.
- [Apple Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest): OCR capabilities and controls, not a guarantee of scientific table interpretation.
- [Apple Foundation Models](https://developer.apple.com/documentation/FoundationModels/), [system model availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel): availability-gated optional integrations; verify execution backend rather than assuming every framework feature is local.
- [Ollama chat API](https://docs.ollama.com/api/chat), [FAQ](https://docs.ollama.com/faq): optional local service configuration and retention controls; test memory/unloading rather than assuming it.
- [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data): endpoint/account-specific retention distinctions; training policy is not the same as zero retention.
- [Anthropic agent security guidance](https://platform.claude.com/docs/en/managed-agents/secure-deployment-risks): model instructions are not an authorization boundary.
- [U.S. Copyright Office fair-use FAQ](https://www.copyright.gov/help/faq/faq-fairuse.html): no universal safe quotation word count. This draft proposes minimizing disclosure, not a legal safe harbor.
