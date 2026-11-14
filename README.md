# chimpread

A minimal native macOS app for reading, annotating, organizing, and citing research papers.
SwiftUI and AppKit provide the interface; PDFKit provides PDF reading and standard
PDF annotations. No Electron, web server, required account, telemetry, or third-party app runtime. Citation formatting uses bundled JavaScript in macOS JavaScriptCore. Optional MCP access uses the same native executable over stdio.

## Download

Visit the [landing page](https://chimpread.com) or download the
[Apple Silicon installer](https://github.com/chimpland/chimpread/releases/latest).
Open the DMG and drag chimpread into Applications. Requires macOS 14 or later.
The early release is ad-hoc signed, **not Apple-notarized**. If macOS blocks it,
review [Apple’s guidance](https://support.apple.com/102445) before approving the app.

## Use

Open `chimpread.app`. Import PDFs or a Zotero RIS export with **File → Import Papers**
(⌘O), the toolbar import button, or drag PDF files into the paper list.

- Create collections with the sidebar +. Use Details or the paper's context menu to
  assign collections. A paper can belong to multiple collections without extra copies.
- Right-click a paper for tags/details, starred/unread status, and Show in Finder.
- Select PDF text, then use the highlighter button (⌘L). Press ⌘N to write a note
  beside the paper, with the selected quote and page attached. Enter saves it and
  highlights the selected passage; Shift+Enter adds a new line. ⌘Return also saves.
- Unfinished note drafts save locally and return when you reopen the paper.
- Show annotations with the right-sidebar button. Search notes, click a page to jump
  to its passage, or use Edit, Copy, and Delete. ⌘Z restores deleted annotations.
- Annotations made with chimpread controls save immediately into the managed PDF.
  Native PDFKit edits are checked every second, on ⌘S, switching papers, exporting, and quitting.
- Close the PDF with × to release the active document. The app remembers its page.
- Export a PDF with embedded annotations using the share button or ⌘E.
- Print the current PDF with the printer button or ⌘P. The native dialog supports page ranges.
- Continue Reading shows previously opened papers. All Papers retains the full active library.
- Tags are collapsed initially and case-only variants share one sidebar entry.
- Right-click a collection to rename it, or a paper to remove its collection membership.
- In Details, choose “Supporting file of” to group or ungroup a document. Manual grouping
  automatically locks that record against Hermes organization updates.
- Archive hides a paper and its attachments without deleting PDFs or notes. Restore them
  from Archive. An independently archived attachment retains its own archive status.
- Sorting by Recent, Title, Author, Newest, or Year persists between launches. Author sort
  uses the stored author string, not an inferred surname.

The panes are resizable. Colors and type follow macOS. The reader retains one active
PDFDocument and imports run sequentially off the UI thread. Optional indexing extracts
one PDF at a time on a background queue; it stores bounded text on disk, not a library
of open PDFs or thumbnails. No model is bundled or started by the app.

Reading starts in Page by Page mode. Use the Reading Layout menu beside the zoom
controls to choose Continuous Scroll; your choice is remembered across launches.
Use Left/Right arrow keys while the paper has focus, or the arrows beside the page
number, to turn pages. In text fields, arrow keys still move the cursor.
⌘Z undoes and ⌘⇧Z redoes typing or annotation actions. Annotation undo history is
limited to the current open paper. A highlighted passage appears as one sidebar
entry even when it spans several lines.

## Your files

Default library: `~/Library/Application Support/PaperShelf/`

- `library.json`: titles, authors, tags, collections, notes, reading position.
- `PDFs/`: independent copies, named with UUIDs to avoid filename collisions.
- `NoteDrafts/`: unfinished note drafts, one small JSON file per paper.
- `library.previous.json`: the metadata state before the latest successful save.
- `ResearchIndex/`: optional, rebuildable local keyword index.
- `research-plans.json`: local pending suggestions and undo journal.
- `ai-settings.json`: optional provider/model settings; API keys stay in Keychain.

Original PDFs and Zotero data are never modified by importing. Identical input PDFs
are detected by SHA-256 streamed in 1 MiB chunks. Back up the whole library folder
while the app is closed; the previous JSON file alone is not a complete backup.
A malformed library index is protected against overwrite and produces an error.

## Zotero migration (0.3.0)

Open **File → Migrate from Zotero…**. In Zotero, export **Zotero RDF** with Export Notes,
Export Files, and Include Annotations enabled. Keep the RDF beside its files folder.
Choose the RDF in chimpread, review the reference/PDF/collection counts and warnings,
then start migration. The full report is saved in `Migration Reports/` in your library.

- Collection hierarchy becomes names such as `Research / Reading`.
- Authors, dates, DOI, journal, volume, issue, pages, source URLs, tags, and note text import.
- References without PDFs remain searchable and citable. Select one to attach a PDF later.
- Main PDFs and supporting attachments stay grouped; embedded PDF annotations are preserved byte-for-byte.
- Existing source identifiers or DOI merge references. Matching title/authors/year provides
  a fallback when a DOI is absent. PDF hashes deduplicate files, including current annotated copies.
- Different PDFs for a matched reference remain supporting files. Existing annotations are
  never replaced. Repeat migration is tested for both single and multiple attachments.
- Existing metadata wins; missing citation metadata fills in. Collections/tags union and notes
  append without duplicating identical imported text. Manual grouping is preserved.
- Original Zotero exports are untouched. Non-PDF, missing, external-linked, or locked attachments
  appear in the report. Download cloud files and export linked attachments first.
- Notes import as plain text; rich layout, Zotero annotation tags/deep links, saved searches,
  sync state, and Zotero-specific attachment types are not reproduced.

This is **export-based migration**, not direct access to a running Zotero database. Zotero
keeps native annotations in its database until exported; use Include Annotations.
[Zotero's annotation explanation](https://www.zotero.org/support/kb/annotations_in_database).
Legacy RIS/PDF import remains available with ⌘O; RDF is the complete migration route.

A read-only preview is also available:

```sh
chimpread --preview-zotero /path/to/library.rdf
```

## Bibliography

**File → Bibliography… (⌘B)** opens a searchable reference picker with collection filtering.
Select papers and generate **APA 7**, **Nature**, **BibTeX**, or **CSL-JSON**. Copy preserves
rich HTML formatting for APA/Nature with a plain-text fallback; export saves text/BibTeX/JSON.
Right-click a paper to copy an APA inline citation. Paper Details includes journal, volume,
issue, and pages. Missing author/year metadata is flagged before use.

Formatting uses bundled citeproc-js and official CSL styles in a temporary JavaScriptCore
context; no model, Node service, or web process is kept running. CSL exports retain structured
authors when available. BibTeX uses stable UUID keys and escapes special characters.
Supplementary attachments are excluded from the bibliography picker.

## Chrome and Google Docs

Open **Integrations (⌘,)** → **Show Extension** and follow the included
[connector setup guide](ChromeExtension/README.md). The Chrome extension saves publisher
metadata or downloads PDFs, searches local references, and copies citations. The optional
native bridge is disabled until enabled and opens no network listener.

Google Docs insertion is implemented in the Chrome extension through Google's API.
It requires a Google Cloud Chrome Extension OAuth client and user authorization; credentials
are not bundled. The connector previews the target document/tab and text, replaces a unique
citation marker, or appends a bibliography. Entries are plain text, without automatic updating
or document-wide citation numbering. Live account insertion remains unverified until configured.

## Build and run

Requires an Apple Silicon Mac with macOS 14+ and Xcode Command Line Tools.

```sh
git clone https://github.com/chimpland/chimpread.git
cd chimpread
./build.sh
open build/chimpread.app
```

The app is ad-hoc signed locally, not notarized. No package installation is needed
for the app. Node.js and Python are only used for optional development tests.

```sh
./build/chimpread.app/Contents/MacOS/chimpread --self-test
./build/chimpread.app/Contents/MacOS/chimpread --research-memory-test
./build/chimpread.app/Contents/MacOS/chimpread --memory-test
python3 Tests/test_native_host.py
node --test Tests/extension.test.mjs
# Optional: install the official Python mcp SDK in a virtual environment first.
python3 Tests/test_mcp.py
```

Tests generate disposable documents; no personal papers or library exports are included.
To create an isolated demo library:

```sh
./build/chimpread.app/Contents/MacOS/chimpread --make-demo /tmp/chimpread-demo
open -n build/chimpread.app --args --library /tmp/chimpread-demo
```

Use one GUI instance per library. Back up your library before migration. The JSON
index has stale-write protection but is not a transactional multi-process database.

## iCloud Drive sync (experimental)

Open **chimpread → iCloud Sync…** and choose a dedicated folder inside iCloud Drive.
Choose that same folder on your other Mac (start with an empty chimpread library
there to avoid independently imported reference IDs). Click **Sync Now** on each Mac.
Your working library remains local; nothing is uploaded until you opt in.

- Sync Now saves and closes the open paper. Automatic checks run every minute while
  the reader is closed. A failed sync reports its reason and can be retried.
- PDFs, embedded annotations, saved notes, tags, collection memberships, and reading
  positions transfer. Drafts, MCP/Chrome permissions, and account settings stay local.
- Immutable per-paper revisions and SHA-256 addressed PDFs avoid overwriting cloud
  versions. Concurrent note text is retained; competing PDF versions become supporting
  files. Other metadata conflicts use the latest synced revision (device clock order).
- iCloud delivery is asynchronous. “Checked” means the local exchange finished, not
  that Apple has delivered every file to your other Mac. Wait for Finder uploads.
  Missing or corrupt remote PDFs pause the local merge. Retry when downloaded.
- Sync retains cloud history and local replaced PDFs under `Sync Recovery`; storage
  grows with edits. There is no automatic history pruning. Disconnect leaves both copies.
- Collection names are unioned: old empty names may remain after a rename on another Mac.
  Independently imported references with different IDs are not merged by this sync layer.
- This first version is tested with local replicas, conflicts, and missing/corrupt delivery;
  **real delivery between two iCloud devices remains unverified**. Back up your library.
  No iOS/iPad app, CloudKit account service, or shared-library collaboration is included.

## Ask your library (0.5.0)

Click **Ask your library** in the sidebar. Search titles, authors, DOI, and tags immediately.
Choose **Build Library Search Index** once to search passages across your PDFs. Indexing
is explicit, incremental, cancelable between pages, and local. Search can be scoped to a
collection; each passage opens its physical PDF page after checking the source revision.
Scans without embedded text need OCR elsewhere. Keyword results are not an exhaustive review.

**Organization suggestions** shows proposed changes, their reasons, and exact before/after
values. **Find Suggestions** matches tags to existing collection names. Select suggestions
and apply or dismiss them; **Undo Last Apply** reverses the last batch if its fields have not
changed since. Older Hermes `organization.json` suggestions now enter this review flow.
The app never automatically merges papers, replaces editions, or deletes PDFs.

**Suggest with AI** previews metadata for up to 40 papers in the chosen scope, then sends
only that preview after you click Send Metadata. Suggestions become reviewable collection
changes. Successive passes advance through the scope; Cancel stops further work. New names
are permitted, but nothing is applied automatically. Titles and tags alone cannot establish
scientific relationships.

Optional **AI Settings** supports OpenAI, Claude, Gemini, Ollama, and OpenAI-compatible
endpoints. Supply a model ID and your API key; keys stay in this Mac's Keychain. A chat
subscription is not necessarily API access. **Ask AI** sends only your question and the
passages displayed above it. Answers are drafts, with source numbers to check yourself;
a valid citation number does not prove a claim. **Append to Notes** is explicit and keeps
existing notes and unfinished annotation drafts. **Save research note…** passes an immutable
answer/source/model snapshot to the Obsidian connector without another model request.
**Save passages…** works without AI.

Use **Copy Evidence** with any assistant that accepts pasted text, or connect a compatible
MCP client below. Provider protocols differ; this is not a promise that every AI/model works.
No paid provider is required for search, manual organization, or reading.

Resource limits include one index job and one AI request per app process, five displayed
passages, a 128 MiB index database, a 4 MiB SQLite cache target, and bounded PDF/text input.
AI output requests are capped at 1,800 tokens for answers or 4,096 for organization, with no automatic retry. Ollama is asked to unload after each request;
its actual resource use depends on that server. PDFKit can still allocate substantial memory
for complex PDFs. See the [implementation status](docs/plans/ai-update-implementation-status.md)
for exact limits, testing, and deferred parts of the larger design.

## Obsidian

Choose **File → Open in Obsidian (⇧⌘O)** or the reader’s share menu. Choose a vault once;
subsequent use updates and opens the same note. Without Obsidian, Finder reveals the Markdown.
Your reader stays on its current paper while saved annotations are extracted on a serial worker.

- New notes have readable, stable filenames, creation-only aliases, and space for your writing.
  Existing UUID exports stay in place. Metadata and annotations have separately checked sections;
  user text and properties outside them are preserved. Unknown annotation coverage never clears highlights.
- **Copy for Obsidian** in an annotation’s context menu copies its text, citation and return link.
  `chimpread://` links open the paper/page; native annotation IDs provide exact targets when available.
  Exported source revisions detect changed PDFs. Imported annotations without durable IDs use page links.
- Changed generated text creates an incoming version; identical conflicts reuse it. One local prior
  version per identity is retained under `ObsidianRecovery/`. Coordinated writes and final byte checks
  detect competing saves, but cannot guarantee every race with an uncoordinated editor.
- **Locate moved note…** relinks a renamed note; file bookmarks can also resolve moves. Missing notes
  are not silently replaced. **Connect existing note…** adds a managed section without rewriting its prose.
- Right-click a collection for a reading page, an ordinary question note, or a Canvas snapshot (up to
  20 papers). Reading pages link existing notes or Chimpread directly; they do not duplicate every paper.
  Canvas files remain yours to arrange and connect; the connector invents no scientific relationships.
- **Save research note…** in Ask your library saves the captured question, AI draft and exact supplied
  passages with generation-time model information. **Save passages…** works without AI. PDF revisions
  are checked before export. Saved research notes are user-owned, and saving does not mark them verified.
- Optional **Include PDF for other devices…** copies a saved PDF with relative links. A synced vault
  may upload that copy. Copies use content-derived names; edited copies are never replaced. Real
  two-device delivery is not validated by local tests, and this does not provide a Chimpread mobile app.
- **Keep linked notes current** is off by default. When enabled, successful saved annotation/note changes
  trigger a debounced refresh of an already-connected paper. There is no vault watcher or startup sweep.
  Busy work can defer a refresh; **Update without opening** or **Refresh linked notes** retries explicitly.
- A plain Markdown template can seed new notes; reset it from Obsidian options. Existing notes are not
  reformatted. Templates are not executed by Chimpread.

The normal flow copies no PDFs and starts no model or background vault index. Extraction is limited
to one temporary PDF at a time, 128 MiB input, 2,000 pages, 20,000 raw annotations / 10,000 groups,
and 2 MiB annotation text. Notes/artifacts have a 4 MiB output cap. These are input limits, not a
promise about PDFKit’s peak memory. Drafts are excluded. Imported source text is escaped rather than
executed as Markdown, HTML, or plugin code. This remains one-way export with two-way navigation,
not automatic editing of PDF annotations from Obsidian.

## MCP and Hermes

Open **Integrations (⌘,)** and enable MCP access. PDF text and saved notes require a separate
content-access toggle. Collection suggestions require their own permission. Use **Copy Generic
MCP Config** or **Copy Hermes Config**, then merge the entry into your client's configuration.
For Hermes, merge into `~/.hermes/config.yaml` and reload MCP. No client configuration is
changed automatically. A connected client can send tool results to its selected model.

The native executable supports `--mcp` over stdio, with no listening network port:

- `search_papers`, `get_paper`, `read_pages`, `read_notes`: bounded metadata/content reads.
- `search_passages`, `get_index_status`: query an existing local index; never start indexing.
- `propose_collection`: submit suggestions for review; cannot apply canonical changes.

Disable access to revoke it on the next request. Permissions cover the library globally;
archive visibility is not an access boundary. Drafts are excluded. Requests are synchronous
and bounded; in-flight cancellation is not implemented. Real Hermes integration remains
unverified; interoperability is tested with the official Python MCP SDK.

## Status and limitations

Version 0.5.0 adds the first AI/library implementation slice. The broader design remains
partly deferred: no semantic relationship graph, OCR, edition resolution, autonomous
maintenance, comparison matrix, or synchronized research journal. Local keyword matching
and metadata suggestions do not establish scientific relationships.

Migration, bibliography, reader behavior, Chrome native messaging, local research/indexing,
review/undo, provider request formats, and Obsidian exports have synthetic regression tests.
Authenticated provider calls, live Google Docs insertion, and real two-device iCloud delivery
still need configured-account verification. The Chrome extension remains unpacked source.

The index, provider settings, permissions, and proposal journal stay local. Accepted collection
metadata uses the existing sync path. Use one GUI per library, and do not run older/newer app
versions on the same library: older versions do not preserve the new transaction receipts.
Different scans/editions may remain separate despite byte-level deduplication. Bibliographies
depend on imported metadata; live citation fields are not included.

## License and credits

chimpread source is licensed under AGPL-3.0-or-later; see [LICENSE](LICENSE).
Copyright 2026 Ben Nguyen. Third-party components retain their own notices:

- citeproc-js 2.4.63 by Frank Bennett, used under AGPL-3.0-or-later.
- APA and Nature CSL styles and the en-US locale by the Citation Style Language
  contributors; license information is embedded in the files.
- See [citation notices](Resources/Citations/NOTICE.txt) and
  [source provenance](Resources/Citations/PROVENANCE.json).

The chimp reading icon adapts the Chimprace face with glasses and a book, created
using OpenAI image generation at the author's request.

## Releasing

Run `./scripts/package-release.sh` to build and verify a DMG, ZIP, and SHA-256 checksums
under `build/release/<version>/`. No signing credentials are bundled. Public distribution
currently uses an ad-hoc signature; Developer ID signing and notarization remain future work.
The static landing page source lives in `website/dist/`; website deployment is separate from the native app build.
