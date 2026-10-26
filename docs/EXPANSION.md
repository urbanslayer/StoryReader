# Expansion plan

> **Status (2026-10-26, branch `feat/stable-chapter-identity`):** M1, minimal M2 (read marks),
> M3 (EPUB export) implemented, 131 hermetic tests green, release APK builds. Also done: ScribbleHub
> chapters fetched through an Android WebView (Cloudflare now challenges every non-browser
> client), own applicationId `io.github.urbanslayer.storyreader` ("StoryReader+"), import of an
> upstream v10 library over the network share. Pending on-device verification. RoyalRoad deferred
> (Anubis bot wall).

Two features: (1) stable chapter identity so an author deleting a chapter does not shuffle the
library or lose reading position, and (2) EPUB export of the next N unread chapters.

---

## M1 — Stable chapter identity, retained deleted chapters

### Root cause

`lib/db.dart`:

```dart
class Chapters extends Table {
  IntColumn get site …; TextColumn get id …;      // the *series* id
  IntColumn get number …;                          // 0-based TOC position
  TextColumn get chapterID …;                      // site chapter id (stable!)
  @override Set<Column> get primaryKey => {site, id, number};
}
```

`number` is the **position in the table of contents at download time**, not the book's own
chapter number. Both sites' client code builds it from the TOC index
(`series_net_page.dart`: `for (var (i, c) in chapters!.indexed) indexes.add(i)`), and
`Series.lastRead` is a `number`. So when an author deletes one chapter, every later chapter's
primary key shifts down by one: reading position moves, `Previous`/`Next` and
`chapterStatus(site, id, i)` all point at the wrong content, and downloaded content can be
attached to the wrong slot.

ScribbleHub's own chapter id is stable and is already stored in `chapterID` — it is the id in the
chapter URL, e.g. `…/chapter/2640407/` for *On Astral Tides* chapter "Seven Hundred And
Twenty-Three". Confirmed against the live series page: its TOC entries carry an
`order="448"` position attribute while the title says 723 — the site's own position counter
disagrees with the book's chapter numbering, which is exactly the deletion the app cannot model.

### Actual data corruption already in user DBs

The shift does not just mislabel: `queueChapters()` (called by *Download all* on every TOC
refresh) inserts/updates rows keyed by the shifted index while carrying the correct
`chapterID`, and the download isolate's `saveChapter` then writes the fetched content into that
row **only when a queued row exists**. Two rows for the same `chapterID` can therefore exist
(old shifted slot, new correct slot) and some slots keep content that does not match their `name`.
So the migration must deduplicate by `chapterID`, keeping the row whose `name` matches the live
TOC entry (content and name are always written together by `saveChapter`, so name is the
reliable discriminator).

### Schema (drift, schemaVersion 10 → 11)

```
chapters
  site          int      ┐
  seriesId      text     ├ primary key (rename of `id`; drift needs a table rebuild, do it in
  chapterId     text     ┘   the v11 migration: create new table, copy, drop, rename)
  position      int?       current TOC index (null = not currently published)
  number        int?       book's own chapter number, parsed from the title
                           ("Five Hundred and Seventy-Eight" / "Chapter 578" / "578:"), else null
  name, content, scrollPosition, queued   (unchanged)
  isRead        bool default false
  updatedAt     datetime
  upstreamState int enum   upstream | missingUpstream | renamed
series
  lastReadChapterId text?   replaces lastRead (keep lastRead during transition)
```

Ordering everywhere becomes `ORDER BY (position ?? <big>), (number ?? <big>), name` — retained
deleted chapters keep their place relative to neighbours without stealing a live slot.

Index: `CREATE UNIQUE INDEX chapters_chapter_key ON chapters(site, seriesId, chapterId)`.

### Reconciliation algorithm (`reconcileChapters(site, seriesId, tocList)`)

Called after every `sh.chapters()` / `rr.series()` fetch, before the UI renders a list.

1. Load local rows keyed by `chapterId`.
2. For each live TOC entry in order: upsert `(position = index, number = parseChapterNumber(name))`.
   If `name` changed → `upstreamState = renamed`. A chapter that was `missingUpstream` and is
   back (author re-uploaded) → `upstreamState = upstream`; re-download only if content is absent.
3. Every local row whose `chapterId` is **not** in the TOC → `upstreamState = missingUpstream`,
   `position = null`, **content and scroll position kept** (this is the retention requirement),
   `queued = false`.
4. If the surviving set changed such that `lastReadChapterId`'s neighbours moved, do nothing to
   the marker: it is a `chapterId`, so it cannot drift.
5. Rows whose `name` no longer matches are *not* re-downloaded automatically (an edit is not a
   deletion); surface "N chapters changed upstream, re-download?" per series instead.

`lastRead` → `lastReadChapterId` in `read_page.dart` (`setLastRead`) and
`library_page.dart` / `series_page.dart` (`firstWhere((c) => c.number == lastRead)` — replace
both with a `chapterId` lookup).

### Call sites that must change together (checklist)

- `lib/db.dart`: table def, v11 migration + dedupe, `chapterStatus`, `queueChapter(s)`,
  `dequeueChapter`, `saveChapter`, `deleteChapter`, `setLastRead`, `_chaptersFor` ordering,
  `replaceDB`, `chapterContents`.
- `lib/pages/series_net_page.dart`: stop using TOC `i` as identity; run `reconcileChapters` and
  render from DB rows (marking `missingUpstream` entries with a "removed upstream" badge).
- `lib/pages/series_page.dart`, `lib/pages/read_page.dart`, `lib/pages/library_page.dart`:
  `number`-based lookups and the `${c.number + 1} -` labels (a bare index is misleading; prefer
  the parsed book number, fall back to the name).
- `lib/download_manager.dart`: fetch by `chapterId` (already does) but must handle
  `missingUpstream` rows and 404s without re-queueing forever.
- `lib/pages/share_network_page.dart` + `load_network_page.dart`: they hard-fail on schema
  mismatch; either bump in lockstep on both devices or make the receiver accept the v10 payload
  shape and remap it (recommended — it is also the migration path from an existing install).

### Site parsing robustness (found while probing)

**Done (merged, `lib/sh_toc.dart`, `test/sh_toc_test.dart`).** Findings:

- The Cloudflare 403 on `wi_gettocchp` is triggered by a **spoofed browser User-Agent**, not by the
  endpoint: a Firefox UA → 403 "Just a moment…", an honest `Dart/…` UA → 200 with all 448
  chapters of *On Astral Tides* (re-verified with curl). Never set a browser UA on site clients;
  `lib/client.dart` documents this and both chopper clients now share `httpClient()`.
- `SHAPI.chapters()` falls back to the series page + `?toc=N` pages (needs the series page as
  `Referer`), never returns a partial TOC, and throws a typed `SiteBlocked` on an interstitial.
  It still returns **newest-first**; `parseScribbleHubToc()` returns ascending.

### Acceptance checks

- `flutter test test/reconcile_test.dart` with recorded TOC fixtures: a 3-chapter TOC losing the
  middle chapter must leave positions/`lastReadChapterId`/content untouched for chapters 1 and 3.
- Drift migration test on an in-memory DB seeded with the duplicate/shifted shape above
  (`NativeDatabase.memory()`): after v10→v11, one row per `chapterId`, no content lost, no
  duplicate keys.
- Manual: download *On Astral Tides*, delete one middle chapter, re-open the online view, check
  that the "Continue" target and every chapter's content still match their titles.

---

## M2 — Reading history (state per chapter)

Required by M3's "next unread" selection and useful on its own:

- `isRead` set when a chapter is opened past X% or explicitly (settings toggle).
- "Unread" = `content IS NOT NULL AND NOT isRead AND upstreamState == upstream`
  (deleted-but-retained chapters are *not* unread if they were read; that is the whole point).
- Library badge "N unread", "Mark all before here as read", and the existing
  `lastRead` marker become independent of read state.

---

## M3 — EPUB export of the next 100 unread chapters

### Format gap that must be fixed first

Chapter content is stored as the **lossy** `RichTextDocument` (`lib/rich_text_tree.dart`):
headings become plain paragraphs, `h2`/`h3` and `s`/`u`/`sup` collapse, table cells lose
`rowspan`/`colspan` position data beyond row/col/span counts, list numbering is flattened into
`"●"` / `"0."` text (note: `ol` uses `"$i."` — off-by-one, starts at 0), and CSS classes/alignment
are dropped. Exporting straight from it produces valid but degraded EPUBs.

Fix: store the **sanitized source HTML** alongside the RichText blob
(`chapters.rawHtml` gzip blob, filled by the API layer where the DOM is already parsed —
`sh.chapterContents` (`#chp_raw`) and `rr.chapterContents` (`.chapter-content`)). Older chapters
have no `rawHtml`; export should (a) re-fetch them on demand, or (b) fall back to
`RichTextDocument → XHTML` (needs a `toHtml()` writer, ~150 L, also useful for the roadmap's
"convert RichText back to HTML" item). Recommend (a) with a progress dialog, capped by the same
100-chapter limit.

HTML sanitisation for EPUB (e-book readers are strict XHTML): strip scripts/iframes/forms, drop
`display:none` style blocks (RoyalRoad already removes one), rewrite `<img src>` to local
manifest paths, force well-formed XHTML (`<br/>`, entity escaping), inline `width`/`height`,
keep `<table>`/`<tr>`/`<td>` with `rowspan`/`colspan` attributes.

### Packaging

Write the EPUB 3 container directly with `archive` (one new dependency; avoids the heavier
`epub`/`ebook_launcher` plugins and their transitive platform code):

```
mimetype (stored uncompressed, first entry, "application/epub+zip")
META-INF/container.xml
OEBPS/content.opf        metadata, spine (one item per chapter), manifest with all images
OEBPS/nav.xhtml          EPUB3 nav (landmarks + per-chapter TOC)
OEBPS/toc.ncx            NCX for legacy readers
OEBPS/style.css          body/p/table/td/blockquote/pre/img rules (mirrors read_page styling)
OEBPS/text/ch-001.xhtml …
OEBPS/images/<imageId>.<ext>   from db chapterImages.image (BLOB), mime sniffed from magic bytes
```

Images come from `chapterImages` by id (`RichTextImage.image` is that global id; `url` is kept
as `srcdoc`/alt). Skip images the user opted out of (`shouldDownload == false && image == null`)
but keep a link to the URL. Author notes / announcements / footnotes map to
`<aside epub:type="author-note">`, `<aside epub:type="epigraph">`, `<sup><a epub:type="noteref">`
+ an end-of-chapter `<section epub:type="footnotes">` — the RichText tree already distinguishes
them, so emit them from the DOM by class (`wi_authornotes`, `wi_news`) in the `rawHtml` path.

### Selection & UX

- `db.nextUnreadChapters(site, seriesId, limit)` → ordered by the M1 ordering,
  `queued`/unread/downloaded filter (offline-only, or "download missing first" option).
- Series page button "Export EPUB (next 100 unread)"; settings for the default count.
- Output: Android SAF — `file_selector`'s `getSaveLocation` (or `share_plus` to hand it to an
  e-reader app). `share_network_page` shows the app already does plain-socket transfer, so a
  "send over network" option is cheap later.
- Writing 100 chapters + images must not block the UI: run in an isolate (`compute`/own isolate,
  like `download_manager.dart`) with progress, and open the DB through
  `appDB.serializableConnection()`.
- Validate output with `epubcheck` in CI/locally before calling it done.

### Acceptance checks

- Export from *On Astral Tides* (has status tables + images) and a RoyalRoad story; open in
  Readium/Calibre: tables keep columns and merged cells, images render, TOC navigates.
- `epubcheck --strict` clean.
- Export twice: second run contains the *next* 100 (read state advanced), not the same ones.

---

## Order of work (each step = one delegate_task with its own acceptance check)

1. Build baseline: Flutter pinned at `3.35.7` (see `BUILD.md`) — upgrade deps + codegen
   (`flutter pub upgrade --major-versions`, analyzer → 14.6) and take Flutter stable ≥ 3.47 with
   Gradle 9.1 / AGP 9 / Kotlin 2.2 (`android/**/*.gradle` new-DSL migration). Keep or pin back
   `flutter_riverpod` 3 / `go_router` 18; fix the deprecations the upgrade surfaced; add real tests
   (`test/` is effectively empty).
2. M1 schema v11 + dedupe migration + `reconcileChapters` + call-site sweep + fixtures tests.
3. M1 UI: removed-chapter badge, `chapterId` navigation, ordering by live position.
4. M2 read state.
5. M3a `rawHtml` capture at scrape time + `toHtml()` fallback writer + sanitiser, with tests.
6. M3b EPUB writer + isolate + SAF save + epubcheck.
7. Fork hygiene: own `applicationId`, own signing key, CI job for `flutter build apk`,
   update `README`/roadmap.
