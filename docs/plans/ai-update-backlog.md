# AI update: draft implementation backlog

October 23, 2026. Planning only. Nothing below is marked implemented. Companion: [product and architecture draft](ai-library-update-draft.md).

## Release slices

**First useful slice:** organize a chosen collection, explain every suggestion, accept a batch, undo it, and find source-backed connections. It must work incrementally across a large library and remain useful without paid inference.

**Second slice:** deeper project relevance, reading assistance, comparison tables, and robust Hermes proposal submission.

**Later slices:** optional OCR/vision/hybrid retrieval/local inference, synchronized accepted research artifacts, and explicitly enabled maintenance. A later capability is not a prerequisite for shipping the first slice.

The backlog is grouped by dependency rather than by apparent UI size. “Done” always means a meaningful behavior test, not just a new view or protocol stub.

## A. Baseline and contracts

| ID | Task | Acceptance |
|---|---|---|
| A01 | Capture reader baseline on representative disposable libraries | Startup, open/close, scrolling, annotation save, peak/RSS and UI responsiveness recorded with hardware/build versions |
| A02 | Define library revision and document/text revision contracts | Annotation-only save, PDF replacement, imported duplicate and sync replacement produce documented invalidation behavior |
| A03 | Define project scope and access grants | Metadata, full text, notes, images, provider destination and proposal submission can be granted independently |
| A04 | Define evidence/relationship schemas | Evidence distinguishes physical page, printed label, normalized text, original quote, extraction method and revision |
| A05 | Define organization operation schema | `set`, `clear`, `add`, `remove` are explicit; invalid fields/types/IDs and attachment cycles are rejected |
| A06 | Build versioned public/synthetic evaluation fixtures | Each task has expected evidence, relevant documents, ambiguity notes and documented licensing/provenance |

## B. Reliable organization changes

| ID | Task | Depends on | Acceptance |
|---|---|---|---|
| B01 | Single-writer transaction service | A02,A05 | GUI, MCP proposals, imports and sync cannot bypass validation through alternate paths |
| B02 | Prepared/committed transaction journal | B01 | Crash injection before/after each write recovers to an explainable committed or unapplied state without duplicate application |
| B03 | Per-field ownership and locks | B01 | Explicitly user-controlled fields are not overwritten by derived rules or regenerated plans |
| B04 | Proposal inbox and batch diff | A05,B01 | User sees exact before/after values, reasons, source links and partial selection before application |
| B05 | Conflict-aware undo | B02 | Undo preserves later user/sync edits, reports conflicts, and survives application restart |
| B06 | Rejection memory | B04 | Rejected suggestions do not recur until their evidence, rule or explicit user request changes |
| B07 | Sidecar compatibility migration | B04 | Legacy `organization.json` cannot bypass the configured review/authorization model; no silent widening of accepted operations |
| B08 | Identity/edition review | A02,A04,B04 | Preprint/final/supplement/correction fixtures remain distinguishable; no annotation loss or hidden PDF replacement |

## C. Bounded local intelligence

| ID | Task | Depends on | Acceptance |
|---|---|---|---|
| C01 | Durable incremental job queue | A02,A03 | Pause, restart, cancel, duplicate scheduling and stale revisions preserve progress without repeated completed work |
| C02 | PDF extraction worker | C01 | Processes bounded page batches; no reader PDF objects leak into history or cross actor/process boundaries |
| C03 | Page/chunk evidence store | A04,C02 | Quote lookup survives normalization; changed/missing sources are visibly invalidated |
| C04 | SQLite FTS retrieval | C03 | Exact identifiers/acronyms and project filters work; query/result sizes are bounded |
| C05 | Coverage reporting | C01,C03 | Missing files, metadata-only references, unprocessed pages, scans, truncation and errors remain distinguishable |
| C06 | Candidate generation | C04 | Uses bounded neighborhoods rather than exhaustive pairwise model comparisons; evaluated recall is reported |
| C07 | Resource arbiter | C01,C02 | Memory pressure pauses background work; interactive reading stays available; child processes counted |
| C08 | Cache lifecycle and purge | C03 | Eviction removes derived data without deleting accepted notes or breaking known evidence state; paper removal purges relevant derived entries |

## D. Library agent and native UI

| ID | Task | Depends on | Acceptance |
|---|---|---|---|
| D01 | Organize-library inventory sheet | C05,B04 | Useful metadata-first inventory before any remote request; scope/coverage visible |
| D02 | Editable project brief | A03 | Project inclusion/exclusion priorities are user-controlled; documents cannot rewrite them |
| D03 | Taxonomy-aware organization proposals | D02,C06,B04 | Existing collection/tag vocabulary reused; suggestions explain evidence and abstain when ambiguous |
| D04 | Evidence-backed connections list | A04,C06 | Each relationship exposes type, origin, source passages and current/unverified status |
| D05 | Reading priority suggestions | D02,D04 | Explains ranking, respects pins/dismissals, avoids constant reshuffling and recency-only feedback loops |
| D06 | Quiet suggestions indicator | B04 | No forced chat or startup interruption; keyboard/VoiceOver can inspect, accept or reject a change |
| D07 | Project evidence question | C04,C05,D02 | Answer reports searched scope/coverage and links each factual claim to allowed evidence |
| D08 | Exportable organization report | B02,D01 | Human-readable report distinguishes proposed, accepted, rejected, conflicted and unresolved items |

## E. Models, evidence, and notes

| ID | Task | Depends on | Acceptance |
|---|---|---|---|
| E01 | Provider capability interface | A03 | Explicit supported context, image, structured-output, usage and cancellation behavior; no silent fallback |
| E02 | First remote adapter and Keychain storage | E01 | Credential never enters synced artifacts, prompts or diagnostic logs; provider failure leaves reader usable |
| E03 | Dispatch budget/reservations | E01,C01 | Input/output/retries/steps bounded; concurrent jobs reserve against the same budget before dispatch |
| E04 | Claim/evidence validation | A04,C03 | Unknown references, altered quotations and out-of-range pages rejected; no false “verified science” label |
| E05 | Source-linked answer view | E04,D07 | Opens exact source, preserves current note draft/reading position, marks stale evidence |
| E06 | Selection-to-note assistance | E05 | One multi-line selection remains one note; saving explicit; generated origin and later user edits preserved |
| E07 | Comparison matrix | E04,D07 | Each populated factual cell has evidence; missing material and differing experimental conditions exposed |
| E08 | Citation-for-sentence workflow | E04 | Model suggests source support; deterministic citation engine formats only actual chosen records |

## F. Hermes and external workflow boundaries

| ID | Task | Depends on | Acceptance |
|---|---|---|---|
| F01 | Bounded MCP framing/output | A03 | Oversized input rejected before unbounded allocation; response-wide caps and pagination bound actual work |
| F02 | MCP cancellation and protocol tests | F01,C01 | Receives cancellation while work runs, serializes output safely, does not claim unsupported protocol capabilities |
| F03 | Scoped evidence tools | C03,C04,F01 | Scope enforced for search and direct IDs, including attachments/archived references and source revalidation |
| F04 | Proposal-only write capability | B04,F03 | Client can submit a reviewed proposal with explicit grant but cannot apply canonical mutations |
| F05 | Verified Hermes setup guide | F03,F04 | Tested against declared Hermes version; distinguishes client config from nonexistent embedded-agent transport |
| F06 | Revocation and outbound audit | A03,E02,F03 | Rechecks grant immediately before dispatch/apply; queued work cannot use revoked permissions |
| F07 | Docs/export preview | E07,E08 | Exact content and destination shown before send; no claim of live citation fields from plain text export |
| F08 | Opted-in recurring maintenance | C01,D03,F06 | Explicit cadence/scope/budget, single run per trigger, quiet when unchanged, stops upon disable |

## G. Optional expansion and release

| ID | Task | Depends on | Acceptance |
|---|---|---|---|
| G01 | Targeted OCR | C02,C03 | Bounded page resolution; OCR provenance/quality warnings; sparse figure page not automatically misclassified |
| G02 | Image/figure analysis | E01,G01 | Image disclosure explicitly in scope; no confident table values from unreadable content |
| G03 | Embedding adapter and hybrid retrieval | C04,A06 | Demonstrated recall benefit over FTS; disk/memory capped; remote embeddings treated as disclosure |
| G04 | Optional local model adapter | E01,A01 | Capability/hardware check, no automatic model download, lifecycle/unload verified across process tree |
| G05 | Accepted-artifact sync format | A04,B02 | No live SQLite sync; conflicts/tombstones tested on local replicas and real two-device delivery |
| G06 | Upgrade/rollback and recovery | B02,C08,G05 | Disposable legacy libraries upgrade safely; rollback limitations explicit; originals and user notes preserved |
| G07 | Security/scientific release evaluation | A06,E04,F06 | Per-category denominators, critical error review and model/prompt/extractor version recorded |
| G08 | Distribution and documentation | G06,G07 | Signing/notarization status accurate, free-core/offline behavior tested, provider costs and limits explained |

## Proposed acceptance thresholds

These are evaluation targets to approve and measure, not proven performance.

- All mechanically invalid citations in the release suite blocked.
- No unauthorized read, mutation, outbound request or credential exposure in adversarial fixtures.
- No annotation loss, silent edition replacement or duplicate transaction application in migration/undo/crash fixtures.
- No critical scientific reversal (control/perturbation, effect direction, species, unit or significance definition) in curated release tasks.
- At least 95% appropriate abstention in the deliberately unanswerable set and at least 95% materially supported claims in a human-reviewed set; report sample sizes and category distributions so averages cannot hide critical errors.
- Candidate retrieval recall, organization precision and rejection recurrence measured separately; set numeric organization thresholds only after representative labeled data exists.
- Reader stays responsive during all agent failure modes. Resource tests include whole process tree and return-to-idle behavior; fixed public RAM promises require measured hardware results.

## Not in the initial release

Autonomous destructive merges, automatic annotation transfer between editions, guaranteed contradiction detection, automatic systematic reviews, unattended external publishing, a public remote MCP endpoint, a mandatory bundled model, a mandatory graph UI, and silent cloud fallback.

These exclusions limit initial risk and dependencies. They do not remove library organization or evidence connections from the first release.
