# Chimpread × Obsidian: next update plan

Draft • 2026-10-23 • Ben requested planning first, with Astra reviewers.

Subsequent implementation and measured results are recorded in [Obsidian implementation status](obsidian-implementation-status.md). The proposal below is preserved as the original design record.

This is a proposal, not a list of shipped features. Three Astra subagents reviewed the experience, knowledge structure, and reliability; a second pass challenges prioritization and acceptance criteria. The other active chat owns the current AI update and initial Obsidian UI integration. This planning pass changes documentation only.

## The experience to build

Read a paper in Chimpread, press **Open in Obsidian**, and continue thinking in a clean paper note. Copy a useful quotation into a project note. Click its source link later and return to that passage in Chimpread. A collection can become a useful reading page; a reviewed answer can become a saved evidence note.

The everyday interface needs one primary action and one annotation action. More capabilities should appear where they are useful, rather than filling a settings screen.

**Recommended first slice:** reliable annotation coverage, Open in Obsidian, readable paper notes, durable source links, and Copy for Obsidian. Build collection hubs and reviewed evidence notes next. Automatic refresh and portable PDF copies come later.

## Current baseline and immediate finding

The exporter in `Sources/Obsidian.swift` supports bounded one-paper Markdown export, paper UUID filenames, a checksum-verified generated section, preservation of text outside that section, local PDF links, and separate incoming files when generated content has changed. Focused tests exist. It does not load PDFs or index the vault.

`Sources/ObsidianView.swift` is being integrated concurrently. During this review it gained a remembered vault, a serial export worker, current-reader annotation capture, and success/error dialogs. Missing UI callers in earlier agent snapshots are not a settled implementation finding. Recheck build wiring and behavior when that chat finishes.

**Issue found and sent to the implementation chat:** an unopened paper supplied `annotations: []`, and replacement of the generated region removed annotations previously exported from the open paper. The source PDF remained intact, but the exported note lost content. During this review the other chat added `ObsidianExportController.snapshot`, which opens the selected paper in the existing reader and returns complete annotations or throws; it also added a closed-PDF regression fixture and included the controller in the build. This addresses the omission path in code; this planning chat has not rerun the evolving integrated tests. The future API should still distinguish unknown from complete-empty coverage. Opening the selected paper can change the reader position and extraction remains on the main actor, so bounded extraction and navigation continuity remain next-stage work.

Other planning inputs: annotation IDs are absent from exported values; imported reader IDs can be positional; user-renamed exports are not tracked; repeated conflicts create repeated incoming files. The README predates some AI code now being developed, so current source takes precedence for that work.

## 1. The first release: make reading and writing connect

### Open in Obsidian

Use this as the primary command in the existing share/menu/context surfaces. First use asks for a vault; later uses reuse it. After successful creation/update, open the note directly. Ordinary success uses a quiet status, not a modal dialog. If Obsidian is absent, the Markdown file still exists and Finder is available.

Keep **Change vault**, **Update note**, and **Locate existing note** secondary. A conflict presents both the existing note and incoming version, with wording that identifies which one was kept. Changing the destination does not itself export anything.

Saving must succeed before exporting. Never include unfinished drafts silently. Switching papers while a job runs must not substitute another paper's annotations.

### A paper note worth keeping

Use a recognizable filename at first creation, such as `Author — Year — Short title — shortID.md`. Record its actual location and never rename it merely because metadata changed. UUID remains identity; author/year/title are display. Preserve existing UUID exports in place.

Put a compact citation and source links first, then the user's writing, then generated highlights. Suppress empty generated sections. Keep internal IDs in creation-time properties, not large visible headings. Seed a short title alias and full title alias. A user can delete or change aliases afterward without them being resurrected on refresh.

Proposed new-note shape (illustrative; placeholders are not research evidence):

```markdown
---
aliases: ["Full paper title", "Author Year — Short title"]
chimpread_id: "paper UUID"
chimpread_schema: 2
---
# Full paper title
Authors · Year · Journal
[Read in Chimpread](source-link) · [Publication](doi-link)

## My notes

## Highlights
> Exact quoted passage.

Reader's saved comment, clearly separate from the quotation.

[Page 7](source-link) · [Paper note](note-link)
^chimp-a-stable-id
```

Implementation will place independent managed sections around citation/source material and annotations. **My notes** and other user writing are outside them. Avoid reserializing the whole Markdown file or the user's YAML. Initially, properties are seeded only at creation; mutable citation metadata lives in managed body text. Do not introduce a YAML round-trip dependency just to update a title.

Namespaced metadata should not redefine an existing vault's `status`, `tags`, or project vocabulary. Preserve arbitrary Chimpread tag text rather than interpreting every tag as an Obsidian tag. Optional Questions/Related notes scaffolding belongs to a creation-only template, not a repeated export operation.

Obsidian supports YAML aliases for link suggestions and properties at the top of a note. See [aliases](https://obsidian.md/help/aliases) and [properties](https://obsidian.md/help/properties).

### Return to evidence

Implement and register a versioned `chimpread://` route for a known library/paper, physical page, and optional annotation ID. This is proposed; it is not an existing guaranteed capability. Validate the route, resolve known identities locally, and show a useful missing-source message. Never accept arbitrary filesystem paths or commands as route actions.

A passage anchor includes source revision and a stable annotation identity when available. If the PDF changed, do not present the old page/position as verified. Open the paper with a stale-anchor notice; bounded quote recovery may be a later explicit action. Keep publication/DOI and local PDF fallbacks.

Carry `/ChimpreadGroup` identity where available. For the first slice, imported annotations without persistent IDs get honest page links. A later persistent identity mapping can support exact anchors; page/order and quote hashes alone are insufficient for repeated identical highlights. Do not modify source PDFs merely to manufacture export identifiers. Ambiguous matches remain unresolved instead of silently merging annotations.

### Copy for Obsidian

An annotation action copies a compact Markdown block: exact quote, saved comment, citation, source link, and stable paper-note/block link when connected. It works without vault setup; the Chimpread/source link remains useful before a paper note exists. It does not write to the clipboard or vault until invoked.

Preserve quote/comment distinctions at the data-model boundary. Current `AnnotationRow.text` concatenates member contents and can duplicate a quote already embedded in a saved comment. Imported highlights without text must say text is unavailable, rather than presenting the label “Highlight” as a quotation. Geometry-based extraction needs bounded work and quality checks.

Obsidian supports links to specific blocks and block embeds; retain ordinary quote text and source URLs for portability. See [internal links](https://obsidian.md/help/links).

## 2. Make the connection useful across a project

### Collection reading hub

**Open collection in Obsidian** previews the scope and creates a compact page. Link to existing paper notes; use Chimpread paper links for those without an exported note. Do not materialize an entire collection of notes just to make its hub. A separate explicit action can create selected missing notes sequentially with cancellation and a result count. A paper in three collections still has one source note.

Use existing collections and explicit user selection. Do not create author/topic taxonomies or infer scientific relationships from collection membership. A small generated list can coexist with the user's question, reading order, and conclusions. The connector does not rewrite existing project pages unless the user links one explicitly.

Useful first version: title, why the user saved it if provided, publication year, reading status, and a link. Sorting is deterministic; rereading does not constantly rearrange the hub.

### Save a research note

In the existing research UI, **Save research note…** creates a new note containing the question, selected passages, paper links, source revisions, optional AI draft, and the user’s interpretation. It works without AI too. A preview lets the user add “Why this matters.” Saving alone never marks an answer reviewed or correct. An optional explicit review record is provenance, not a correctness guarantee. This uses the existing provider workflow and makes no extra model request merely to export.

Separate source quotations, AI interpretation, and the user's additions. When a cited passage cannot be verified against its revision, flag it before export. A generated answer is not an additional independent source. After creation, the entire research note belongs to the user. Refreshing a paper never rewrites it. Saving the same result again opens the existing note or explicitly creates a new revision. A later answer is a new explicit revision or a new note.

Prerequisite: capture an immutable `ResearchAnswerSnapshot` at generation with the question/scope, actual bounded request passages, response, source ordering/revisions, requested model and provider-reported model when available. Export from that snapshot, never mutable current search results or changed settings. Current `AIService.context` takes at most eight hits while `answerWithSources` enumerates current hits; current search is limited to five, so this is an architectural mismatch to resolve before expanded sources, not proof that today’s UI lists unsent passages. Keep credentials out of provenance.

This should be the main AI-related improvement: carry verified research work into the place where the user writes, with enough context to inspect it later.

### Open questions

Let the user save a question with chosen source links to a project note. Initially it is ordinary editable Markdown. A future explicit “Find evidence for this question” action can use the existing Chimpread index for selected library papers; no vault-wide indexing or passive monitoring is required. Do not infer questions from all of the user's private notes.

## 3. Later upgrades, after the first loop works

| Capability | Value | Prerequisite / boundary |
|---|---|---|
| Keep linked paper notes current | New highlights appear after a successful save | Opt-in, only already-connected papers, serialized and debounced; conflict/race protections must pass first |
| Attach to an existing paper note | Fits established vault workflows | User selects the note; verify identity, insert an isolated managed section, preserve all other content |
| Portable annotated PDFs | Read exported notes and source pages on another device | Explicit mode, streamed copies, relative vault links, revision-aware conflict handling, disk-use preview |
| Small literature canvas | Arrange a selected set around a question | Optional snapshot, bounded scope, explicit labeled edges and provenance, never overwrite user-arranged canvas |
| Custom note templates | Match a preferred note style | Creation-only, limited substitutions; no executable templates |

These are not all requirements for the next release. In particular, live two-way PDF/Markdown editing, continuous vault indexing, and automatic scientific knowledge graphs need separate designs. Bidirectional navigation does not imply bidirectional editing.

Portable mode should be described honestly: it makes PDF content available through the vault, not a Chimpread mobile app. Obsidian supports a vault PDF embed with a page fragment; copying a PDF into an iCloud-backed vault may cause iCloud upload. See [embeds](https://obsidian.md/help/embeds). The default mode creates no PDF copies.

## Small implementation contracts

1. **Explicit coverage:** `complete(items, sourceRevision)`, `notRead(reason)`, or `failed(reason)`. Only complete-empty can clear prior annotations. Unknown/failed coverage preserves the last good snapshot or aborts with an explanation. An explicit annotation removal is not the same as a failed read.
2. **Immutable export snapshot:** identity, metadata, notes, coverage, quotes/comments, stable anchors. No `PDFDocument`, `PDFPage`, or `PDFAnnotation` enters the writer queue.
3. **Local link receipt:** known library/paper identity, selected vault bookmark/path, note bookmark/relative path, schema, last exported hashes, and pending conflict fingerprint. Use a small per-paper record loaded on demand; do not duplicate the full vault in memory. Commit the note before its receipt, and test recovery from a crash between those writes by checking the known expected file and embedded identity.
4. **Moved-note repair:** attempt the known bookmark, then ask to locate/relink. A missing note does not silently cause a duplicate. Verify its embedded identity before update. No title-based matching or whole-vault search.
5. **Preservation:** checksum each managed region, preserve unrelated bytes, and detect state changes immediately before commit. Keep recoverable prior bytes for updates under an explicit bounded retention policy; do not accumulate unlimited hidden history. File coordination and atomic writes alone do not prove safety against an editor that does not coordinate; test this and avoid unconditional guarantees. Defer unattended refresh until this contract is established.
6. **Conflict deduplication:** one unchanged incoming version is reused. If the user edited that incoming file, preserve it and make a distinguishable new proposal. Never replace a user's conflict copy based only on a predictable filename.
7. **One active job:** serialize extraction and writing across controller instances. Use one temporary PDF at most, and coordinate with the reader/research index so two memory-heavy operations do not overlap unintentionally. Cancel between bounded stages.
8. **Bound actual reads:** an existing file's size check is not a byte limit if the file grows afterward. Use bounded reads and fail without replacing files on malformed/oversized content. Reject managed-path symlinks at access time, not only during initial setup.

## Delivery sequence and ownership

| Stage | Deliverable | Completion evidence |
|---|---|---|
| A — finish current integration | Correct annotation coverage, remembered vault, working UI/build | End-to-end export regression, synthetic vault, integrated self-tests |
| B — compelling daily loop | Open in Obsidian, readable notes, stable mapping, return links, Copy for Obsidian | A first-time user reaches a note after one destination choice; returning user needs one command |
| C — project research | Collection hub and explicit saved evidence notes | Valid note links, no duplicate source notes, source-backed AI export and clear ownership |
| D — convenience after proof | Opt-in refresh, existing-note attachment, portable mode | Concurrency/recovery tests, measured memory, multi-device limits documented |
| Explore separately | Canvas, richer question workflows, editable templates | Demonstrate benefit over normal notes before adding permanent UI |

The current implementation chat owns Stage A and shared app wiring. This chat supplies this plan and the review findings. Future coding should assign file ownership again before concurrent changes to `Obsidian.swift`, `ObsidianView.swift`, `Reader.swift`, `Info.plist`, or shared tests. No live-vault migration or publishing is part of this plan.

See [acceptance checks](obsidian-next-update-checks.md) for tests and resource measurements. Do not claim any proposed feature is implemented merely because this draft was handed off.

## Review synthesis

Three Astra agents completed two passes each. They agree on one-action access, clear human ownership, exact source navigation, explicit coverage, and no new vault index. The UX reviewer favors collection hubs and then refresh; the knowledge reviewer prioritizes saved research notes over Canvas or a second question queue; the reliability reviewer recommends keeping refresh explicit until preservation and recovery are demonstrated. This plan chooses the daily reading loop first, then hubs/research notes, with unattended refresh gated later. No millions-of-agents claim is made.
