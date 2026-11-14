# Obsidian implementation and verification

October 23, 2026. Implemented in the local working checkout and packaged at `build/chimpread.app`. No commit, public release, or live-vault migration was performed. The earlier [plan](obsidian-next-update-plan.md) and [acceptance checklist](obsidian-next-update-checks.md) remain dated design records; this document distinguishes implemented behavior from measured results and outstanding release checks.

## Available now

| Workflow | Implemented behavior |
|---|---|
| Read → write | **Open in Obsidian (⇧⌘O)** chooses a vault once, exports saved content, then opens the same note. Ordinary success uses a status message. Finder is the fallback when Obsidian is unavailable. The reader retains its current paper and position. |
| Paper notes | Stable readable filenames, creation-only aliases and optional Markdown templates. Independently checked metadata/annotation sections preserve surrounding user prose and properties. Unknown annotation coverage does not clear earlier highlights. |
| Return to evidence | Versioned paper/page links, native annotation IDs and block anchors, revision-aware navigation. Invalid routes and stale revisions are rejected or explained. Imported annotations without persistent identity use page navigation. |
| Copy for Obsidian | Copies actual annotation contents, distinct quote/comment text where available, citation and return link. An empty annotation is labeled unavailable; the reader's “Highlight” display label is never treated as a quotation. Legacy combined comments remain comments rather than inferred quotations. |
| Existing workflows | Locate/relink moved notes, file bookmarks, explicit attachment to an existing note, and creation-only templates. Missing linked notes are not silently duplicated. |
| Collections | A reading page links already-exported notes or Chimpread sources. Question notes are ordinary editable Markdown. Canvas snapshots support up to 20 papers; users arrange/connect them in Obsidian, and no relationships are inferred. |
| Research notes | Explicit **Save research note…** saves the immutable answer, question, exact dispatched source order/text, requested/reported model information and optional interpretation. **Save passages…** needs no AI. Current source revisions are checked before writing. Saving makes no extra model request and does not mark claims verified. |
| Portable sources | Explicit PDF inclusion streams a revision-named copy into the vault and uses relative links. Existing modified copies are protected. Default exports make no PDF copies. |
| Refresh | Optional, off by default, debounced after successful reader saves and restricted to already-linked papers. Manual paper/collection refresh is available. Busy work may require a later manual retry. |
| Conflicts/recovery | Managed-region checksums, bounded descriptor-based file operations, symlink rejection, a final byte comparison, deduplicated incoming versions and one prior recovery version per identity. Receipts identify known notes without enumerating the vault. |

The AI chat owned provider/search/organization code; the connector chat owned these Obsidian modules and the final shared app wiring. The combined build contains both sets of changes. See [AI implementation status](ai-update-implementation-status.md) for that feature set and its separate limitations.

## Final automated checks

Environment: macOS 27.0.1 (26A434), arm64, 32 GiB RAM; optimized Swift build targeting macOS 14.0. The final source hashes, binary hash, commands and log hashes are recorded in `build/obsidian-validation-manifest.json`.

```sh
./build.sh > build/obsidian-build.log 2>&1
build/chimpread.app/Contents/MacOS/chimpread --self-test > build/obsidian-self-test.log 2>&1
/usr/bin/time -l build/chimpread.app/Contents/MacOS/chimpread --obsidian-memory-test > build/obsidian-memory.log 2>&1
git diff --check
plutil -lint Info.plist
```

All commands passed. The integrated regression log contains **205 PASS records**, including existing app tests, AI/search/review tests and the new Obsidian suites. A PASS record can summarize multiple assertions; it is not a count of every assertion. Connector coverage includes complete versus unknown annotations, user prose/properties, conflicts, concurrent injected edits, relinking/attachment, inert source Markdown, portable relative links, bounded PDF snapshots, strict routes, clipboard content, research snapshot ownership, collection hubs, questions and Canvas paths.

The final two native findings have regression coverage: Obsidian needs the physical macOS file path when a vault was registered through `/private/tmp`; clipboard export must use stored annotation content instead of a display fallback or a combined reader row.

## Native app walkthrough

Used a disposable three-paper/nine-page demonstration library and a newly registered temporary Obsidian 1.14.4 vault under `/tmp/chimpread-obsidian-ui-UYabkv`. No personal library or vault content was edited. The AI request used the other chat's deterministic HTTP fixture on loopback, with synthetic text and no credential.

- First use requested the vault; repeat use opened the existing note without another chooser or success dialog.
- Paper/page links opened the expected source. An actual source-link click in the rendered Obsidian research note returned to **Questions worth keeping**, page 1, in Chimpread.
- The research note opened in Obsidian and rendered the question, interpretation, clearly labeled AI draft, unreviewed state, exact source order and requested `fixture` / reported `fixture-reported` model values.
- A sentence entered through Obsidian remained after adding a saved annotation in Chimpread and refreshing the paper note. The new annotation appeared with its page and stable block anchor.
- AI Settings reopened with the saved model/endpoint. The organization request preview contained exactly the three scoped papers; apply and undo controls completed. Retained global collection names after undo are intentional behavior of the organization feature.

Native research/handoff/preservation checks ran after the physical-path fix. The final clipboard-content refinement was subsequently compiled and covered by the full regression run.

## Memory measurement

The final optional test extracted and exported a synthetic **10-page PDF with 300 annotations**, warmed once, then repeated the entire extraction/export cycle 20 times. Retained RSS was **63 MiB after warm-up and 64 MiB after each measured cycle**; reported maximum retained growth was **1 MiB**. `/usr/bin/time -l` reported **69,206,016 bytes (~66 MiB) maximum resident set size** and **2.06 seconds** elapsed for the process. Values printed in MiB are integer-truncated. These measurements cover the synthetic test process, not total desktop memory or arbitrary PDFKit workloads. The 64 MiB growth failure allowance is a coarse smoke-test threshold, not a demonstrated release budget.

Production work uses one serialized export worker and coordinates PDF extraction with the research-index gate. It loads no vault index, installs no watcher, polls nothing at idle, and starts no model process. It retains one PDF snapshot at a time, with 128 MiB input, 2,000 pages, 20,000 raw annotations / 10,000 groups, 2 MiB extracted annotation text and 4 MiB note/output limits. PDFKit can allocate above these input/text limits while reading complex files.

## Limits still requiring broader release validation

Local tests do not establish two-device sync delivery, authenticated AI interoperability, representative large/complex PDF memory use, cancellation latency inside a blocked PDFKit call, all disk-full/power-loss cases, or every concurrent save from an uncoordinated editor. File coordination and final comparisons reduce races; the recovery copy does not make writes cross-process compare-and-swap transactions. Automatic refresh is therefore opt-in, and incoming conflicts remain explicit.

This is one-way export with two-way navigation. It does not edit PDF annotations from Markdown, scan private vault notes, infer scientific relationships, or provide a mobile Chimpread app. The broader AI backlog remains separate from this connector implementation.
