// Main-isolate download loop for ScribbleHub chapters.
//
// Why this exists: ScribbleHub chapter pages now sit behind a Cloudflare
// managed challenge that no non-browser client can pass (HTTP 403 "Just a
// moment..." for dart:io, curl, and even headless desktop browsers), so the
// old HTTP path in the download isolate always failed and the queue never
// drained. The fix (same approach reader apps like Mihon use) is to fetch
// chapter pages through a real WebView — which only exists on the main (UI)
// isolate on Android — while the background isolate keeps handling images
// and RoyalRoad (see `lib/download_manager.dart`, whose isolate *skips*
// ScribbleHub chapters while this loop is active, so the two loops can
// never take the same chapter).
//
// This file is deliberately pure Dart (no `package:flutter/...` and no
// WebView plugin imports): the loop is tested with an injected [HtmlFetcher]
// and [BrowserChapterStore]; the real implementations live in
// `lib/browser_fetch.dart` (WebView-backed) and `lib/download_manager.dart`
// (AppDB-backed).

import 'dart:async';

import 'package:story_reader/db.dart';
import 'package:story_reader/download_outcome.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart';
import 'package:story_reader/sh_toc.dart';

/// One chapter page fetcher, injectable for tests.
///
/// Contract (mirrored by `BrowserFetcher`): return the final document HTML —
/// normally once [isReady] accepts it, but a loaded page that never becomes
/// ready and is *not* an anti-bot challenge is returned as-is so the caller
/// can parse/classify it. Throw [SiteBlocked] when the site kept serving a
/// challenge and the user cancelled (or verification timed out), and any
/// other error for a transient failure (timeout, navigation error) — errors
/// keep the chapter queued.
abstract class HtmlFetcher {
  Future<String> fetchHtml(Uri url, {required bool Function(String html) isReady});
}

/// A queued chapter as seen by the loop. Deliberately a plain record type
/// (not a drift row) so tests can build fake queues without a database.
final class BrowserQueuedChapter {
  /// Legacy numeric slot, forwarded untouched to `saveChapter`.
  final int number;

  /// Site-stable chapter id (URL `/chapter/<id>/` segment).
  final String chapterID;

  /// Queued chapter title / row name.
  final String name;

  /// Series id (ScribbleHub numeric id).
  final String seriesId;

  /// Series title as stored locally (needed for the chapter URL slug).
  final String seriesName;

  const BrowserQueuedChapter({
    required this.number,
    required this.chapterID,
    required this.name,
    required this.seriesId,
    required this.seriesName,
  });
}

/// Queue storage the loop drives. Production wraps `AppDB`
/// (`AppDBBrowserStore` in `lib/download_manager.dart`).
abstract class BrowserChapterStore {
  /// Queued, still-downloadable chapters in canonical order (oldest first),
  /// already filtered to the site this loop handles.
  Future<List<BrowserQueuedChapter>> queuedChapters();

  Future<void> saveChapter(BrowserQueuedChapter chapter, ChapterData data);

  Future<void> dequeueChapter(BrowserQueuedChapter chapter);
}

/// What one chapter attempt resulted in.
enum BrowserChapterAction {
  /// Parsed and stored.
  saved,

  /// Page parsed as impossible (real page without chapter markup): removed
  /// from the queue.
  dequeued,

  /// Anti-bot challenge the user did not resolve (cancelled / timed out):
  /// stays queued.
  blocked,

  /// Transient failure (timeout, navigation error, DB hiccup): stays
  /// queued.
  failed,
}

/// Parses chapter HTML into a [ChapterData]; may run off-isolate in
/// production. Throws (never returns null) when the page cannot parse.
typedef ChapterParser = Future<ChapterData> Function(String html, String chapterId);

/// In-process parser (default; also what the unit tests use).
Future<ChapterData> directChapterParser(String html, String chapterId) async =>
    parseScribbleHubChapter(html, chapterId);

/// Decides one fetched-page outcome with the same table the download isolate
/// uses ([classifyChapterFetch]); the WebView has no HTTP status, so a page
/// that loaded at all is classified as a 200.
BrowserChapterAction classifyBrowserChapterFetch(String html, bool parsed) {
  final outcome = classifyChapterFetch(200, html, parsed);
  return switch (outcome) {
    DownloadOutcome.save => BrowserChapterAction.saved,
    DownloadOutcome.dequeue => BrowserChapterAction.dequeued,
    // Challenge (or anything the table treats as blocked): keep queued.
    DownloadOutcome.retrySlow => BrowserChapterAction.blocked,
    DownloadOutcome.retrySoon => BrowserChapterAction.failed,
  };
}

/// Whether the background download isolate must skip a chapter because the
/// browser loop owns that site (true only for ScribbleHub while
/// [skipScribbleHub] is set). Pure so the hand-off rule is unit-testable.
bool isolateSkipsChapter(bool skipScribbleHub, Site site) =>
    skipScribbleHub && site == Site.scribbleHub;

/// Drains queued ScribbleHub chapters through [HtmlFetcher] on the main
/// isolate. Started by `startDownloadManager()` when the platform supports
/// WebViews; see `lib/browser_fetch.dart`.
final class BrowserDownloadLoop {
  BrowserDownloadLoop({
    required this.fetcher,
    required this.store,
    this.parseChapter = directChapterParser,
    this.pollInterval = const Duration(seconds: 1),
    this.blockedBackoff = const Duration(seconds: 30),
    this.failedBackoff = const Duration(seconds: 5),
    this.onActiveChanged,
    Future<void> Function(Duration) delay = _futureDelay,
  }) : _delay = delay;

  static Future<void> _futureDelay(Duration d) => Future.delayed(d);

  final HtmlFetcher fetcher;
  final BrowserChapterStore store;
  final ChapterParser parseChapter;
  final Duration pollInterval;
  final Duration blockedBackoff;
  final Duration failedBackoff;

  /// Reports "manager running" for the Downloads page indicator; combined
  /// with the isolate's flag by `lib/download_manager.dart`.
  final void Function(bool active)? onActiveChanged;

  final Future<void> Function(Duration) _delay;

  bool _running = false;
  int _generation = 0;

  bool get isRunning => _running;

  /// Starts the drain loop (no-op when already running).
  void start() {
    if (_running) return;
    _running = true;
    final gen = ++_generation;
    onActiveChanged?.call(true);
    unawaited(_run(gen));
  }

  /// Stops after the current chapter attempt finishes. Queued chapters stay
  /// queued; nothing is dropped.
  void cancel() {
    if (!_running) return;
    _running = false;
    ++_generation;
    onActiveChanged?.call(false);
  }

  Future<void> _run(int gen) async {
    while (_running && gen == _generation) {
      var backoff = pollInterval;
      try {
        final result = await runOnce(gen);
        if (result != null) {
          backoff = switch (result) {
            BrowserChapterAction.blocked => blockedBackoff,
            BrowserChapterAction.failed => failedBackoff,
            _ => pollInterval,
          };
        }
      } catch (e) {
        print("Browser download loop error: $e");
        backoff = failedBackoff;
      }
      await _delay(backoff);
    }
  }

  /// One pass over the queue in canonical order: fetch + parse + store each
  /// chapter until the queue is empty or an attempt must stop the pass
  /// (blocked/failed — the next chapters would hit the same wall). Returns
  /// the stopping action, or null when the pass ran to completion.
  ///
  /// The optional [generation] guard stops the pass when [cancel] was called
  /// mid-pass; callers outside the loop can omit it.
  Future<BrowserChapterAction?> runOnce([int? generation]) async {
    final chapters = await store.queuedChapters();
    for (final c in chapters) {
      if (generation != null && generation != _generation) return null;
      final action = await processChapter(c);
      switch (action) {
        case BrowserChapterAction.saved:
        case BrowserChapterAction.dequeued:
          continue;
        case BrowserChapterAction.blocked:
        case BrowserChapterAction.failed:
          return action;
      }
    }
    return null;
  }

  /// Fetch, parse and file one queued chapter. Never throws: failures map to
  /// [BrowserChapterAction.blocked]/[BrowserChapterAction.failed] (queue
  /// untouched) so one bad chapter cannot kill the loop.
  Future<BrowserChapterAction> processChapter(BrowserQueuedChapter c) async {
    final url = scribbleHubChapterUrl(c.seriesId, c.seriesName, c.chapterID);
    final String html;
    try {
      html = await fetcher.fetchHtml(url, isReady: isScribbleHubChapterReady);
    } on SiteBlocked catch (e) {
      print("Chapter ${c.chapterID} blocked (${e.kind}); keeping queued");
      return BrowserChapterAction.blocked;
    } catch (e) {
      print("Chapter ${c.chapterID} fetch failed ($e); keeping queued");
      return BrowserChapterAction.failed;
    }
    ChapterData? data;
    Object? parseError;
    try {
      data = await parseChapter(html, c.chapterID);
    } catch (e) {
      parseError = e;
    }
    final action = classifyBrowserChapterFetch(html, data != null);
    switch (action) {
      case BrowserChapterAction.saved:
        await store.saveChapter(c, data!);
      case BrowserChapterAction.dequeued:
        // A real chapter page without parsable content will never parse on
        // retry: drop just this chapter, keep the rest of the queue.
        print("Giving up on chapter ${c.chapterID} (${c.name}): $parseError");
        await store.dequeueChapter(c);
      case BrowserChapterAction.blocked:
      case BrowserChapterAction.failed:
        // Queue untouched (the fetcher said content never arrived but the
        // page classifier insists — e.g. a challenge slipped past the
        // fetcher).
        break;
    }
    return action;
  }
}

/// Store adapter over the real database: queued ScribbleHub chapters joined
/// with their series names, in the canonical order `_queuedChapters`
/// already produces.
final class AppDBBrowserStore implements BrowserChapterStore {
  AppDBBrowserStore(this.db);

  final AppDB db;

  @override
  Future<List<BrowserQueuedChapter>> queuedChapters() async {
    final rows = (await db.queuedChapters())
        .where((c) => c.site == Site.scribbleHub)
        .toList();
    if (rows.isEmpty) return [];
    final series = {for (final s in await db.series()) (s.site, s.id): s.name};
    return [
      for (final c in rows)
        BrowserQueuedChapter(
          number: c.number,
          chapterID: c.chapterID,
          name: c.name,
          seriesId: c.id,
          seriesName: series[(c.site, c.id)] ?? "",
        ),
    ];
  }

  @override
  Future<void> saveChapter(BrowserQueuedChapter chapter, ChapterData data) =>
      db.saveChapter(Site.scribbleHub, chapter.seriesId, chapter.number,
          chapter.chapterID, data.content!, data.name, rawHtml: data.rawHtml);

  @override
  Future<void> dequeueChapter(BrowserQueuedChapter chapter) =>
      db.dequeueChapterByID(Site.scribbleHub, chapter.seriesId, chapter.chapterID);
}
