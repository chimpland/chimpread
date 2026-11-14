# Obsidian next update: acceptance checks

Draft • 2026-10-23. These are planned checks, not results. Use disposable libraries and synthetic vaults. The integration chat is actively changing the app; inspect its final code before implementing these cases.

See [implementation status](obsidian-implementation-status.md) for the completed checks and explicit remaining limits. The checklist below is not a claim that every release scenario has been exercised.

## Required before the next connector release

1. **Coverage regression:** export two annotations, close/switch the paper, change metadata, and export again. Unknown coverage preserves both annotations. Verified complete-empty removes them; unreadable/missing PDF retains the previous snapshot or aborts. A reference without a PDF is distinct from an unread PDF.
2. **Human content preservation:** edits before/after generated regions, YAML aliases, custom properties, Unicode, line endings, and arbitrary headings survive refresh. Malformed or duplicate markers do not authorize replacement.
3. **Repeated operations:** unchanged export is a no-op. Unchanged conflict reuses the pending incoming version. Editing the incoming version protects it from later overwrite. Title changes do not create another note.
4. **Identity:** same-title papers remain distinct. A note moved/renamed in Obsidian resolves through the known bookmark or gives a locate action. Wrong-identity relink is rejected. Existing UUID exports are preserved; multiple collections link to the same paper note.
5. **Stable anchors:** insert, delete, and reorder annotations without changing unrelated anchors. Test multiline groups, identical quotes on different pages, imported highlights, legacy groups, and notes whose stored text already contains quotations. Missing extracted quote is labeled honestly.
6. **Navigation:** valid routes open the intended paper/page; malformed UUID, negative/huge page, unknown library, missing paper and changed PDF yield an understandable result. No route executes commands or reads arbitrary file paths. Obsidian absent still yields a usable Markdown file.
7. **File failures:** unwritable destination, disk-full simulation, interrupted temp write, invalid UTF-8, growing oversized note, missing vault, dangling symlink and replaced directory leave original bytes recoverable and never report success.
8. **Concurrent edits:** inject a writer between initial read and commit. Do not lose the edit; produce a conflict/recovery result. Test actual Obsidian editing as well as injected fixtures before making a broad preservation claim. A recoverable copy alone is not proof that a user-visible lost edit cannot occur.
9. **UI flow:** first use asks for a destination once; reuse opens the same note without routine modal confirmation. Vault selection alone writes nothing. Conflict choices distinguish original and incoming. Cancellation does not display success or switch to the wrong paper.
10. **Receipt recovery:** simulate failure after a note is written but before its receipt commits. Retry adopts the expected note only after identity/hash checks, without duplication or replacing unrelated content.
11. **Source-backed evidence notes:** each saved quotation points to its actual paper/revision; AI text is labeled as such. Missing/stale evidence is exposed before save. Snapshot the exact request sources and generation-time model metadata; test later search/settings changes and more than eight candidate hits. Saving the result makes no extra model request. Saving never automatically marks it reviewed. Private unrelated notes are not included.

## Memory and work measurements

Measure rather than promise a memory number. Record macOS/build, fixture size, peak resident memory, post-idle memory, duration, and cancellation latency. Establish numerical regression thresholds on this Mac from the observed baseline before release; these are not current measurements.

- A vault with 10 versus 10,000 unrelated notes should perform the same connector work for one selected paper. Confirm no vault enumeration, watchers, idle polling, or persistent model process.
- Run repeated exports after warm-up; distinguish bounded allocator/PDFKit caching from a rising retained-memory trend. Inspect retained PDFKit objects after jobs finish and close the reader for the idle comparison.
- Stress at the current 4 MiB note / 10,000 annotation ceilings, plus malformed/growing input. Enforce limits before building an unbounded annotation snapshot, not just after collecting rows.
- In a collection batch, retain one paper snapshot at a time and bounded result summaries. Never collect all PDF documents or all rendered notes before writing.
- Test export during research indexing and reader navigation. The scheduler must prevent unintended simultaneous heavy PDF work and stale snapshot mixing.
- Cancellation must be checked between papers/stages; a single long PDF operation needs an explicit bounded policy. Test closing the window and quitting during a write.

## Native-app verification after implementation

Use a temporary registered Obsidian vault for a manual walkthrough: open a source note, edit My notes/properties, refresh it, follow a source link, rename the note, relink if needed, and create/inspect a conflict. Verify both rendered view and source mode. Do not use Ben's FITdb vault as a test fixture.

For portable mode, separately verify a vault-relative PDF link on another device. A same-Mac file copy is not proof of cloud delivery or mobile behavior.

## Current integration reconciliation

During the planning review, the other chat added complete-or-error annotation capture through the existing reader and a closed-PDF regression fixture. These are observed code changes, not fresh test results from this planning chat. Reconcile final implementation and run the integrated tests there.

## Known checks from the earlier implementation

Before this planning turn, the initial exporter passed focused standalone tests and a full-project typecheck. Those results do not validate the later UI wiring, any proposed link handler, all editor races, a multi-device flow, or the new coverage case. Re-run only the relevant checks after implementation; do not treat historical success as a release gate for new behavior.
