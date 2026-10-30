// Deleted / missing chapters on the WebView path: the pure "this page is
// final" markers (RR "This chapter has been deleted" / 404, ScribbleHub's
// WordPress 404), the combined `*Final` readiness predicates that stop the
// 45 s poll on such pages, and the dequeue classification that mirrors a
// plain-HTTP 404 (previously these pages burned the full page budget and
// were retried forever).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/browser_download_loop.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/rr_parse.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Returns one canned page, recording the `isReady` predicate it was handed
/// so the test can prove a deleted page is accepted *immediately*.
class OnceFetcher implements HtmlFetcher {
  OnceFetcher(this.html);

  final String html;
  bool Function(String)? sawIsReady;

  @override
  Future<String> fetchHtml(Uri url,
      {required bool Function(String html) isReady}) async {
    sawIsReady = isReady;
    return html;
  }
}

class RecordingStore implements BrowserChapterStore {
  RecordingStore(this.queue);

  final List<BrowserQueuedChapter> queue;
  final saved = <BrowserQueuedChapter>[];
  final dequeued = <BrowserQueuedChapter>[];

  @override
  Future<List<BrowserQueuedChapter>> queuedChapters() async => List.of(queue);

  @override
  Future<void> saveChapter(BrowserQueuedChapter c, ChapterData d) async =>
      saved.add(c);

  @override
  Future<void> dequeueChapter(BrowserQueuedChapter c) async =>
      dequeued.add(c);
}

void main() {
  final rrChapter = fixture('rr_chapter.html');
  final rrDeleted = fixture('rr_chapter_deleted.html');
  final rr404 = fixture('rr_page_notfound.html');
  final rrSearch = fixture('rr_search.html');
  final rrSeries = fixture('rr_series.html');
  final anubis = fixture('rr_anubis_challenge.html');
  final cloudflare = fixture('sh_cloudflare_interstitial.html');
  final shChapter = fixture('sh_chapter_page.html');
  final sh404 = fixture('sh_chapter_notfound.html');

  group('isRoyalRoadNotFound', () {
    test('deleted-chapter and 404 pages match', () {
      expect(isRoyalRoadNotFound(rrDeleted), isTrue);
      expect(isRoyalRoadNotFound(rr404), isTrue);
    });
    test('real content pages and anti-bot walls do not', () {
      expect(isRoyalRoadNotFound(rrChapter), isFalse);
      expect(isRoyalRoadNotFound(rrSearch), isFalse);
      expect(isRoyalRoadNotFound(rrSeries), isFalse);
      expect(isRoyalRoadNotFound(anubis), isFalse);
      expect(isRoyalRoadNotFound(cloudflare), isFalse);
      expect(isRoyalRoadNotFound(""), isFalse);
    });
  });

  group('isScribbleHubNotFound', () {
    test('the 404 page matches', () {
      expect(isScribbleHubNotFound(sh404), isTrue);
    });
    test('real chapter pages and walls do not', () {
      expect(isScribbleHubNotFound(shChapter), isFalse);
      expect(isScribbleHubNotFound(cloudflare), isFalse);
      expect(isScribbleHubNotFound("<html></html>"), isFalse);
    });
  });

  group('final-page readiness (no 45 s stall on error pages)', () {
    test('RR: chapter body OR deleted/404 marker satisfies the predicate', () {
      expect(isRoyalRoadChapterFinal(rrChapter), isTrue);
      expect(isRoyalRoadChapterFinal(rrDeleted), isTrue);
      expect(isRoyalRoadChapterFinal(rr404), isTrue);
      expect(isRoyalRoadChapterFinal(anubis), isFalse,
          reason: "a wall is not final — it must stay retryable");
    });
    test('SH: #chp_raw OR 404 marker satisfies the predicate', () {
      expect(isScribbleHubChapterFinal(shChapter), isTrue);
      expect(isScribbleHubChapterFinal(sh404), isTrue);
      expect(isScribbleHubChapterFinal(cloudflare), isFalse);
    });
  });

  group('classifyBrowserChapterFetch: not-found pages dequeue like HTTP 404',
      () {
    test("RR deleted page (unparsable) -> dequeued", () {
      expect(
          classifyBrowserChapterFetch(rrDeleted, false, site: Site.royalRoad),
          BrowserChapterAction.dequeued);
      expect(
          classifyBrowserChapterFetch(rr404, false, site: Site.royalRoad),
          BrowserChapterAction.dequeued);
    });
    test("SH 404 page (unparsable) -> dequeued", () {
      expect(
          classifyBrowserChapterFetch(sh404, false,
              site: Site.scribbleHub),
          BrowserChapterAction.dequeued);
    });
    test("a challenge still classifies as blocked, never dequeued", () {
      expect(
          classifyBrowserChapterFetch(anubis, false, site: Site.royalRoad),
          BrowserChapterAction.blocked);
      expect(
          classifyBrowserChapterFetch(cloudflare, false,
              site: Site.scribbleHub),
          BrowserChapterAction.blocked);
    });
    test("a parsed chapter saves even if odd text trips a marker", () {
      expect(
          classifyBrowserChapterFetch(rrChapter, true, site: Site.royalRoad),
          BrowserChapterAction.saved);
    });
  });

  group("BrowserDownloadLoop end-to-end (deleted chapters)", () {
    test("RR deleted page: isReady accepts it immediately, chapter dequeued",
        () async {
      final c = BrowserQueuedChapter(
          number: 0,
          chapterID: "901",
          name: "Gone",
          seriesId: "111",
          seriesName: "Alpha One",
          site: Site.royalRoad);
      final fetcher = OnceFetcher(rrDeleted);
      final store = RecordingStore([c]);
      final action =
          await BrowserDownloadLoop(fetcher: fetcher, store: store)
              .processChapter(c);
      expect(action, BrowserChapterAction.dequeued);
      expect(fetcher.sawIsReady!(rrDeleted), isTrue,
          reason: "the loop's predicate must not stall on the error page");
      expect(store.dequeued, [c]);
      expect(store.saved, isEmpty);
    });

    test("SH 404 page: dequeued, queue keeps flowing", () async {
      final bad = BrowserQueuedChapter(
          number: 0,
          chapterID: "100",
          name: "Ghost",
          seriesId: "623932",
          seriesName: "Fixture Series",
          site: Site.scribbleHub);
      final good = BrowserQueuedChapter(
          number: 1,
          chapterID: "101",
          name: "Fine",
          seriesId: "623932",
          seriesName: "Fixture Series",
          site: Site.scribbleHub);
      final fetcher = _QueueFetcher({
        "100": sh404,
        "101": shChapter,
      });
      final store = RecordingStore([bad, good]);
      final stopped =
          await BrowserDownloadLoop(fetcher: fetcher, store: store)
              .runOnce();
      expect(stopped, isNull);
      expect(store.dequeued.map((c) => c.chapterID), ["100"]);
      expect(store.saved.map((c) => c.chapterID), ["101"]);
    });
  });
}

class _QueueFetcher implements HtmlFetcher {
  _QueueFetcher(this.byChapterId);

  final Map<String, String> byChapterId;

  @override
  Future<String> fetchHtml(Uri url,
      {required bool Function(String html) isReady}) async {
    final id = url.pathSegments[url.pathSegments.indexOf("chapter") + 1];
    final html = byChapterId[id];
    if (html == null) throw StateError("unexpected fetch to $url");
    if (!isReady(html)) throw StateError("$id page never became ready");
    return html;
  }
}
