/// M3b: EPUB export of the next N unread chapters.
///
/// [exportNextUnread] is the service entry point the UI calls. It (1)
/// refreshes the live table of contents when reachable so content-less
/// placeholders exist, (2) selects the next `limit` unread chapters in
/// canonical order (including placeholders), (3) optionally downloads the
/// missing ones into the library through the same save path as the download
/// manager, (4) resolves chapter images from the `chapterImages` store
/// (downloading missing blobs over plain HTTP), and (5) sanitizes each
/// chapter body from its stored `rawHtml` when present (lossless tables,
/// spans, formatting) or from the lossy RichText tree otherwise, then packs
/// the EPUB **in a background isolate** so 100 chapters never freeze the UI.
///
/// The service deliberately does NOT write read state or files: the caller
/// saves the bytes (SAF via `file_picker`) and only then calls
/// [ExportResult.markExportedChaptersRead] — a cancelled save must not mark
/// anything as read.
///
/// Site-generic: ScribbleHub is the wired site; RoyalRoad chapters already
/// downloaded (with `rawHtml` captured by `rr.chapterContents`) export
/// through the identical path.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'package:story_reader/browser_fetch.dart';
import 'package:story_reader/client.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/epub/epub_builder.dart';
import 'package:story_reader/epub/html_to_xhtml.dart';
import 'package:story_reader/epub/rich_text_to_xhtml.dart';
import 'package:story_reader/rich_text_tree.dart';
import 'package:story_reader/rr.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart';
import 'package:story_reader/sh_browser.dart';
import 'package:story_reader/sh_toc.dart' show SiteBlocked;

/// Stage of the export the UI should display.
enum ExportPhase { refreshingToc, fetching, images, building }

final class ExportProgress {
  final ExportPhase phase;

  /// Worked item (1-based) within [total]; both 0 when unbounded.
  final int current;
  final int total;

  const ExportProgress(this.phase, [this.current = 0, this.total = 0]);

  String get label => switch (phase) {
        ExportPhase.refreshingToc => "Refreshing table of contents…",
        ExportPhase.fetching => "Fetching chapter $current of $total…",
        ExportPhase.images => "Preparing images ($current of $total)…",
        ExportPhase.building => "Building EPUB…",
      };
}

/// A fatal export error with a user-presentable message.
final class ExportException implements Exception {
  final String message;
  const ExportException(this.message);
  @override
  String toString() => message;
}

/// The finished book plus everything the UI needs after the file save.
final class ExportResult {
  final Uint8List bytes;

  /// Suggested filesystem-safe name, e.g.
  /// `on-astral-tides_449-548.epub`.
  final String fileName;

  /// Site chapter ids of every chapter included in the book.
  final List<String> exportedChapterIDs;

  /// Titles of selected chapters that could not be exported (missing
  /// content with fetching off, or an unfetchable chapter).
  final List<String> skippedUnavailable;

  final int imagesEmbedded;
  final int imagesMissing;

  /// Echo of the caller's `markAsRead` intent (see
  /// [markExportedChaptersRead]).
  final bool markAsRead;

  const ExportResult({
    required this.bytes,
    required this.fileName,
    required this.exportedChapterIDs,
    required this.skippedUnavailable,
    required this.imagesEmbedded,
    required this.imagesMissing,
    required this.markAsRead,
  });

  /// Applies the read marks for the exported chapters. Call this only after
  /// the user actually saved the file — the service never touches read
  /// state itself.
  Future<void> markExportedChaptersRead(AppDB db, Site site, String seriesId) async {
    if (!markAsRead) return;
    for (final id in exportedChapterIDs) {
      await db.setRead(site, seriesId, id, true);
    }
  }
}

/// Exports up to [limit] unread chapters of a stored series as an EPUB.
///
/// * Refreshes the TOC first when online (ScribbleHub `wi_gettocchp`,
///   RoyalRoad series page) so not-yet-downloaded chapters exist as
///   placeholders; any failure (blocked site, no network) continues with
///   what is stored.
/// * Selects the next [limit] unread chapters in canonical order
///   ([AppDB.nextUnreadChaptersForExport]): unread, not removed upstream,
///   including content-less placeholders.
/// * With [fetchMissing], content-less chapters are downloaded (default
///   fetcher: ScribbleHub through the WebView on platforms that have one,
///   else plain HTTP; RoyalRoad plain HTTP) and saved through
///   `saveChapter`, so the library gains them too. A chapter that cannot be
///   fetched is skipped and reported in [ExportResult.skippedUnavailable];
///   only zero exportable chapters is fatal ([ExportException]).
/// * [fetchToc] and [fetchChapter] are injectable for tests; production
///   leaves them null.
Future<ExportResult> exportNextUnread(
  AppDB db,
  Site site,
  String seriesId, {
  int limit = 100,
  bool fetchMissing = true,
  bool markAsRead = true,
  void Function(ExportProgress)? onProgress,
  Future<ChapterData> Function(Chapter)? fetchChapter,
  Future<List<ChapterData>?> Function()? fetchToc,
}) async {
  final series = (await db.series()).where((s) => s.site == site && s.id == seriesId).firstOrNull;
  if (series == null) {
    throw const ExportException("This series is not in the downloaded library.");
  }

  // 1. Refresh the TOC best-effort so placeholders for undownloaded
  //    chapters exist. A failed/blocked fetch must not corrupt state:
  //    reconcileChapters itself ignores an empty TOC, and every throw here
  //    is swallowed so the stored rows are used instead.
  onProgress?.call(const ExportProgress(ExportPhase.refreshingToc));
  try {
    final toc = await (fetchToc ?? (() => _defaultFetchToc(site, seriesId, series.name)))();
    if (toc != null && toc.isNotEmpty) {
      await db.reconcileChapters(site, seriesId, toc);
    }
  } catch (_) {
    // Offline or bot-walled: continue with what is stored.
  }

  // 2. Selection: next `limit` unread in canonical order.
  final selected = await db.nextUnreadChaptersForExport(site, seriesId, limit);
  if (selected.isEmpty) {
    throw ExportException("No unread chapters to export for “${series.name}”.");
  }

  // 3. Fetch chapters whose content is missing (so the export also
  //    downloads them into the library).
  final skipped = <String>[];
  final contentLess = selected.where((c) => c.content == null).toList();
  if (contentLess.isNotEmpty) {
    if (!fetchMissing) {
      skipped.addAll(contentLess.map((c) => c.name));
    } else {
      final fetcher = fetchChapter ?? (c) => _defaultFetchChapter(series, c);
      var blocked = false;
      var done = 0;
      for (final c in contentLess) {
        if (blocked) {
          skipped.add(c.name); // rest would hit the same wall
          continue;
        }
        onProgress?.call(ExportProgress(ExportPhase.fetching, ++done, contentLess.length));
        try {
          // saveChapter only writes queued rows — queue this one first
          // (a no-op for rows that already have content).
          await db.queueChapter(site, c.name, seriesId, c.number, c.chapterID);
          final data = await fetcher(c);
          final content = data.content;
          if (content == null) {
            throw const ExportException("fetched chapter has no content");
          }
          await db.saveChapter(site, seriesId, c.number, c.chapterID, content,
              data.name.trim().isEmpty ? c.name : data.name,
              rawHtml: data.rawHtml);
        } on SiteBlocked {
          blocked = true; // site wall: don't hammer it with the rest
          await db.dequeueChapterByID(site, seriesId, c.chapterID);
          skipped.add(c.name);
        } catch (_) {
          await db.dequeueChapterByID(site, seriesId, c.chapterID);
          skipped.add(c.name);
        }
      }
    }
  }

  // Re-read: fetched chapters now carry content. Keep only the selected,
  // content-bearing rows (canonical order preserved by the query).
  final selectedIDs = selected.map((c) => c.chapterID).toSet();
  final usable = (await db.nextUnreadChaptersForExport(site, seriesId, limit))
      .where((c) => selectedIDs.contains(c.chapterID) && c.content != null)
      .toList();
  if (usable.isEmpty) {
    throw ExportException(
        "None of the ${selected.length} selected chapters could be exported (${skipped.length} unavailable).");
  }

  // 4. Images: ids referenced by the chapters (RichText ids or rawHtml
  //    <img> srcs mapped through chapterImages), blobs from the DB with a
  //    plain-HTTP top-up for missing ones.
  onProgress?.call(const ExportProgress(ExportPhase.images));
  final rawHtmlByChapter = <String, String?>{
    for (final c in usable) c.chapterID: db.chapterRawHtml(c),
  };
  final refs = <int, String>{}; // chapterImages.id -> url
  for (final c in usable) {
    final raw = rawHtmlByChapter[c.chapterID];
    if (raw != null) {
      for (final src in _htmlImageSources(raw)) {
        final existing = await db.imageByUrl(src);
        refs[existing?.id ?? await db.addImage(src)] = src;
      }
    } else {
      final doc = db.chapterContents(c);
      doc?.visit((e) {
        if (e is RichTextImage) refs[e.image] = e.url;
      });
    }
  }

  final hrefById = <int, String>{};
  final hrefByUrl = <String, String>{};
  final images = <EpubImage>[];
  var imagesMissing = 0;
  if (refs.isNotEmpty) {
    final client = httpClient();
    try {
      var done = 0;
      for (final entry in refs.entries) {
        final id = entry.key;
        final url = entry.value;
        onProgress?.call(ExportProgress(ExportPhase.images, ++done, refs.length));
        var bytes = await db.chapterImage(id);
        if (bytes == null) {
          bytes = await _downloadImage(client, url);
          if (bytes != null) {
            await db.setImageData(id, bytes);
          }
        }
        final media = bytes == null ? null : imageMediaType(bytes);
        // SVG is skipped (epubcheck demands fallbacks) and undetectable
        // types would be dropped by the builder: both become placeholders.
        final ext = media == null || media == 'image/svg+xml' ? null : imageFileExtension(media);
        if (bytes == null || ext == null) {
          imagesMissing++;
          continue;
        }
        final href = '../images/img-$id.$ext';
        hrefById[id] = href;
        hrefByUrl[url] = href;
        images.add(EpubImage('img-$id', bytes));
      }
    } finally {
      client.close();
    }
  }

  // 5. Build in a background isolate: sanitizing + zipping 100 chapters is
  //    CPU work that must not run on the UI thread.
  onProgress?.call(const ExportProgress(ExportPhase.building));
  final chapters = <_ExportBuildChapter>[];
  for (final c in usable) {
    final raw = rawHtmlByChapter[c.chapterID];
    final contentJson = raw == null ? jsonEncode(db.chapterContents(c)!.toJson()) : null;
    final urlMap = <String, String>{};
    if (raw != null) {
      for (final src in _htmlImageSources(raw)) {
        final href = hrefByUrl[src];
        if (href != null) urlMap[src] = href;
      }
    }
    chapters.add(_ExportBuildChapter(
      title: c.name,
      rawHtml: raw,
      contentJson: contentJson,
      hrefByUrl: urlMap,
      hrefById: Map.unmodifiable(hrefById),
    ));
  }
  final first = usable.first;
  final last = usable.last;
  final input = _ExportBuildInput(
    title: exportBookTitle(series.name, first.name, last.name),
    author: 'Unknown', // no author column in the DB; export adds none
    identifier: 'urn:storyreader:${switch (site) {
      Site.scribbleHub => 'scribblehub',
      Site.royalRoad => 'royalroad',
    }}:$seriesId:${first.chapterID}-${last.chapterID}',
    description: series.description,
    cover: _coverBytes(series),
    modified: DateTime.timestamp(),
    chapters: chapters,
    images: images,
  );
  final bytes = await compute(_exportBuildTask, input);

  return ExportResult(
    bytes: bytes,
    fileName: exportFileName(series.name, _indexLabel(first), _indexLabel(last)),
    exportedChapterIDs: usable.map((c) => c.chapterID).toList(),
    skippedUnavailable: skipped,
    imagesEmbedded: images.length,
    imagesMissing: imagesMissing,
    markAsRead: markAsRead,
  );
}

// ---- defaults for the injectable fetchers ----------------------------------

Future<List<ChapterData>?> _defaultFetchToc(Site site, String seriesId, String seriesName) async {
  switch (site) {
    case Site.scribbleHub:
      final resp = await SHAPI.create().chapters(seriesId);
      final toc = resp.body;
      if (toc == null) return null;
      // SHAPI.chapters is newest-first; reconcileChapters wants ascending.
      return toc.reversed.toList();
    case Site.royalRoad:
      final resp = await RRAPI.create().series(seriesId, seriesName);
      return resp.body?.$2;
  }
}

Future<ChapterData> _defaultFetchChapter(Series series, Chapter c) async {
  final data = SeriesData(site: series.site, id: series.id, name: series.name);
  switch (series.site) {
    case Site.scribbleHub:
      if (BrowserFetcher.isSupported) {
        // Cloudflare: the WebView path is the only one that passes there.
        return fetchScribbleHubChapterViaBrowser(series.id, series.name, c.chapterID);
      }
      final resp = await SHAPI.create().chapterContents(data, c.chapterID);
      final body = resp.body;
      if (body == null || body.content == null) {
        throw ExportException("chapter ${c.chapterID} returned no content");
      }
      return body;
    case Site.royalRoad:
      final resp = await RRAPI.create().chapterContents(data, c.chapterID, c.name);
      final body = resp.body;
      if (body == null || body.content == null) {
        throw ExportException("chapter ${c.chapterID} returned no content");
      }
      return body;
  }
}

// ---- image helpers ----------------------------------------------------------

/// Distinct `http(s)` `src` values of `<img>` elements in an HTML fragment,
/// in document order (trimmed).
List<String> _htmlImageSources(String html) {
  final out = <String>[];
  final seen = <String>{};
  for (final el in html_parser.parseFragment(html).querySelectorAll('img')) {
    final src = (el.attributes['src'] ?? '').trim();
    if (src.isEmpty || !seen.add(src)) continue;
    final uri = Uri.tryParse(src);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) continue;
    out.add(src);
  }
  return out;
}

Future<Uint8List?> _downloadImage(http.Client client, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
  try {
    final req = http.Request('GET', uri)
      ..headers.addAll({
        'Sec-Fetch-Dest': 'image',
        'Sec-Fetch-Mode': 'no-cors',
        'Sec-Fetch-Site': 'cross-site',
      });
    final resp = await http.Response.fromStream(await client.send(req))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    return resp.bodyBytes;
  } catch (_) {
    return null;
  }
}

// ---- naming helpers (pure, unit-tested) -------------------------------------

/// Live TOC index for a chapter, falling back to the legacy slot.
int _indexLabel(Chapter c) => c.position == kNoPosition ? c.number : c.position;

/// Book title `“Series — First … Last”`, shortened sensibly when long.
String exportBookTitle(String seriesName, String firstName, String lastName) {
  String cut(String s, int max) => s.length <= max ? s : '${s.substring(0, max - 1)}…';
  if (firstName == lastName) {
    return '$seriesName — $firstName';
  }
  final full = '$seriesName — $firstName … $lastName';
  if (full.length <= 160) return full;
  return '${cut(seriesName, 60)} — ${cut(firstName, 40)} … ${cut(lastName, 40)}';
}

/// Filesystem-safe suggested file name `<slug>_<first>-<last>.epub`
/// (first/last are 1-based chapter indexes).
String exportFileName(String seriesName, int firstIndex, int lastIndex) {
  var slug = slugify(seriesName).replaceAll(RegExp(r'[^a-z0-9-]'), '-');
  slug = slug.replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isEmpty) slug = 'story';
  return '${slug}_${firstIndex + 1}-${lastIndex + 1}.epub';
}

/// Series thumbnail as a cover, but only when its media type is jpeg/png
/// (everything else epubcheck or readers would reject as `cover-image`).
Uint8List? _coverBytes(Series s) {
  final thumb = s.thumbnail;
  if (thumb == null || thumb.isEmpty) return null;
  final media = imageMediaType(thumb);
  return (media == 'image/jpeg' || media == 'image/png') ? thumb : null;
}

// ---- background build task ---------------------------------------------------

/// One chapter for the isolate build task. Exactly one of [rawHtml] /
/// [contentJson] is set.
final class _ExportBuildChapter {
  final String title;
  final String? rawHtml;

  /// Pre-encoded `RichTextDocument.toJson()` — decoded inside the isolate.
  final String? contentJson;

  /// rawHtml path: `img src` -> in-book href (missing key = placeholder).
  final Map<String, String> hrefByUrl;

  /// RichText path: stored image id -> in-book href.
  final Map<int, String> hrefById;

  const _ExportBuildChapter({
    required this.title,
    required this.rawHtml,
    required this.contentJson,
    required this.hrefByUrl,
    required this.hrefById,
  });
}

/// Everything the build isolate needs — only sendable plain data.
final class _ExportBuildInput {
  final String title;
  final String author;
  final String identifier;
  final String description;
  final Uint8List? cover;
  final DateTime modified;
  final List<_ExportBuildChapter> chapters;
  final List<EpubImage> images;

  const _ExportBuildInput({
    required this.title,
    required this.author,
    required this.identifier,
    required this.description,
    required this.cover,
    required this.modified,
    required this.chapters,
    required this.images,
  });
}

/// Top-level so [compute] can run it in a background isolate: sanitize every
/// chapter body and pack the EPUB off the UI thread.
Uint8List _exportBuildTask(_ExportBuildInput input) {
  final chapters = <EpubChapter>[];
  for (final c in input.chapters) {
    final body = c.rawHtml != null
        ? sanitizeHtmlToXhtml(c.rawHtml!, resolveImage: (src) => c.hrefByUrl[src.trim()])
        : richTextToXhtml(RichTextDocument.fromJson(jsonDecode(c.contentJson!)),
            resolveImage: (id, url) => c.hrefById[id]);
    chapters.add(EpubChapter(c.title, body));
  }
  return buildEpub(EpubBook(
    title: input.title,
    author: input.author,
    identifier: input.identifier,
    description: input.description,
    cover: input.cover,
    modified: input.modified,
    chapters: chapters,
    images: input.images,
  ));
}
