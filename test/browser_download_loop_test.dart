// Unit tests for the main-isolate ScribbleHub download loop: scheduling,
// classification and the queue-safety rules, driven through fake
// [HtmlFetcher]/[BrowserChapterStore] implementations (a real WebView cannot
// run in `flutter test`; the WebView plumbing itself is validated by
// `flutter build apk --debug` + on-device runs).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/browser_download_loop.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/rr_parse.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart';
import 'package:story_reader/sh_toc.dart';

class FakeFetcher implements HtmlFetcher {
  /// url string -> HTML to return, or the error to throw.
  FakeFetcher(this.responses);

  final Map<String, Object> responses;
  final requested = <Uri>[];

  @override
  Future<String> fetchHtml(Uri url,
      {required bool Function(String html) isReady}) async {
    requested.add(url);
    final response = responses[url.toString()];
    switch (response) {
      case null:
        throw StateError("unexpected fetch to $url");
      case Exception():
        throw response;
      case Error():
        throw response;
      case String():
        // Contract mirrors BrowserFetcher: the final document is returned
        // as-is; the loop parses/classifies it (challenge bodies included).
        return response;
      default:
        throw StateError("unexpected fake response for $url: $response");
    }
  }
}

class FakeStore implements BrowserChapterStore {
  FakeStore(this.queue);

  final List<BrowserQueuedChapter> queue;
  final saved = <(BrowserQueuedChapter, ChapterData)>[];
  final dequeued = <BrowserQueuedChapter>[];

  @override
  Future<List<BrowserQueuedChapter>> queuedChapters() async =>
      List.of(queue);

  @override
  Future<void> saveChapter(BrowserQueuedChapter chapter, ChapterData data) async {
    saved.add((chapter, data));
  }

  @override
  Future<void> dequeueChapter(BrowserQueuedChapter chapter) async {
    dequeued.add(chapter);
  }
}

BrowserQueuedChapter chapter(String id, {String? slugName}) =>
    BrowserQueuedChapter(
      number: 0,
      chapterID: id,
      name: "Chapter $id",
      seriesId: "623932",
      seriesName: slugName ?? "Fixture Series",
      site: Site.scribbleHub,
    );

BrowserQueuedChapter rrChapter(String id) => BrowserQueuedChapter(
      number: 0,
      chapterID: id,
      name: "Chapter $id",
      seriesId: "111",
      seriesName: "Fixture Tale",
      site: Site.royalRoad,
    );

String urlFor(String id) =>
    scribbleHubChapterUrl("623932", "Fixture Series", id).toString();

String rrUrlFor(String id) =>
    royalRoadChapterUrl("111", "Fixture Tale", id, "Chapter $id").toString();

/// A real chapter page that carries the title but no #chp_raw content node
/// (never parses). Deliberately free of challenge markers.
const unparseableRealPage =
    '<html><body><div class="chapter-title">Gone weird</div>'
    '<div id="elsewhere"><p>No content node here.</p></div></body></html>';

void main() {
  final goodPage = File("test/fixtures/sh_chapter_page.html").readAsStringSync();
  final challengePage =
      File("test/fixtures/sh_cloudflare_interstitial.html").readAsStringSync();

  final siteBlocked = SiteBlocked("https://www.scribblehub.com/read/x/chapter/1/",
      kind: BotChallengeKind.cloudflare, siteName: "ScribbleHub");

  BrowserDownloadLoop makeLoop(FakeFetcher fetcher, FakeStore store) =>
      BrowserDownloadLoop(fetcher: fetcher, store: store);

  group("BrowserDownloadLoop.processChapter", () {
    test("RoyalRoad chapter: RR URL + RR parser, saved under royalRoad",
        () async {
      final c = rrChapter("901");
      final rrPage =
          File("test/fixtures/rr_chapter.html").readAsStringSync();
      final fetcher = FakeFetcher({rrUrlFor("901"): rrPage});
      final store = FakeStore([c]);
      final action = await makeLoop(fetcher, store).processChapter(c);
      expect(action, BrowserChapterAction.saved);
      expect(fetcher.requested.single.toString(), rrUrlFor("901"),
          reason: "the loop must fetch the RoyalRoad URL, not the SH one");
      expect(store.saved, hasLength(1));
      expect(store.saved.single.$1.site, Site.royalRoad);
      // The RR parser keeps the queued name and the processed body
      // (hidden anti-piracy paragraph removed, notes relocated).
      expect(store.saved.single.$2.name, "Chapter 901");
      expect(store.saved.single.$2.content, isNotNull);
      expect(store.saved.single.$2.rawHtml, contains("placeholder corridor"));
      expect(store.saved.single.$2.rawHtml,
          isNot(contains("unlawfully taken")));
    });

    test("RoyalRoad challenge body classifies as blocked, queue intact",
        () async {
      final c = rrChapter("902");
      final challenge =
          File("test/fixtures/rr_anubis_challenge.html").readAsStringSync();
      final fetcher = FakeFetcher({rrUrlFor("902"): challenge});
      final store = FakeStore([c]);
      final action = await makeLoop(fetcher, store).processChapter(c);
      expect(action, BrowserChapterAction.blocked);
      expect(store.saved, isEmpty);
      expect(store.dequeued, isEmpty);
    });


    test("successful fetch parses and saves the chapter", () async {
      final c = chapter("101");
      final fetcher = FakeFetcher({urlFor("101"): goodPage});
      final store = FakeStore([c]);
      final action = await makeLoop(fetcher, store).processChapter(c);
      expect(action, BrowserChapterAction.saved);
      expect(store.saved, hasLength(1));
      expect(store.saved.single.$2.name, "Seven - A Handmade Fixture");
      expect(store.saved.single.$2.content, isNotNull);
      expect(store.dequeued, isEmpty);
    });

    test("challenge + user cancel keeps the chapter queued", () async {
      final c = chapter("102");
      // The fetcher raises SiteBlocked when verification is cancelled.
      final fetcher = FakeFetcher({urlFor("102"): siteBlocked});
      final store = FakeStore([c]);
      final action = await makeLoop(fetcher, store).processChapter(c);
      expect(action, BrowserChapterAction.blocked);
      expect(store.saved, isEmpty);
      expect(store.dequeued, isEmpty,
          reason: "blocked != gone: the queue must never be dropped here");
    });

    test("a challenge body handed back by the fetcher classifies as blocked",
        () async {
      final c = chapter("103");
      // A challenge document the fetcher still returned must map to
      // `blocked` — never `dequeue`.
      expect(classifyBrowserChapterFetch(challengePage, false,
              site: Site.scribbleHub),
          BrowserChapterAction.blocked);
      final fetcher = FakeFetcher({urlFor("103"): challengePage});
      final store = FakeStore([c]);
      final action = await makeLoop(fetcher, store).processChapter(c);
      expect(action, BrowserChapterAction.blocked);
      expect(store.saved, isEmpty);
      expect(store.dequeued, isEmpty,
          reason: "the fetcher said ready but the page is a challenge wall");
    });

    test("real page that cannot parse is dequeued, pass continues", () async {
      final bad = chapter("200");
      final good = chapter("201");
      final fetcher = FakeFetcher({
        urlFor("200"): unparseableRealPage,
        urlFor("201"): goodPage,
      });
      final store = FakeStore([bad, good]);
      final stopped = await makeLoop(fetcher, store).runOnce();
      expect(stopped, isNull, reason: "dequeue must not stop the pass");
      expect(store.dequeued.map((c) => c.chapterID), ["200"]);
      expect(store.saved.map((e) => e.$1.chapterID), ["201"]);
    });

    test("transient fetch failure keeps queued and stops the pass", () async {
      final c1 = chapter("300");
      final c2 = chapter("301");
      final fetcher = FakeFetcher({
        urlFor("300"): TimeoutException("boom"),
        urlFor("301"): goodPage,
      });
      final store = FakeStore([c1, c2]);
      final stopped = await makeLoop(fetcher, store).runOnce();
      expect(stopped, BrowserChapterAction.failed);
      expect(store.saved, isEmpty);
      expect(store.dequeued, isEmpty);
      expect(fetcher.requested.map((u) => u.toString()), [urlFor("300")],
          reason: "the rest of the pass would hit the same wall");
    });

    test("runOnce walks the queue in canonical order", () async {
      final chapters = [chapter("1"), chapter("2"), chapter("3")];
      final fetcher = FakeFetcher({
        urlFor("1"): goodPage,
        urlFor("2"): goodPage,
        urlFor("3"): goodPage,
      });
      final store = FakeStore(chapters);
      final stopped = await makeLoop(fetcher, store).runOnce();
      expect(stopped, isNull);
      expect(fetcher.requested.map((u) => u.pathSegments[3]),
          ["1", "2", "3"]);
      expect(store.saved.map((e) => e.$1.chapterID), ["1", "2", "3"]);
    });
  });

  group("isolateSkipsChapter (loop hand-off rule)", () {
    test("isolate skips every browser-owned site while the loop is active",
        () {
      expect(isolateSkipsChapter(true, Site.scribbleHub), isTrue);
      expect(isolateSkipsChapter(true, Site.royalRoad), isTrue,
          reason: "RoyalRoad went Cloudflare-walled in 2026-10: the browser "
              "loop owns it wherever a WebView exists");
      expect(isolateSkipsChapter(false, Site.scribbleHub), isFalse,
          reason: "no WebView platform: the isolate keeps the HTTP path");
      expect(isolateSkipsChapter(false, Site.royalRoad), isFalse,
          reason: "no WebView platform: the isolate keeps the HTTP path");
    });

    test("browserOwnedSites is exactly the walled sites", () {
      expect(browserOwnedSites, {Site.scribbleHub, Site.royalRoad});
    });
  });

  group("BrowserDownloadLoop lifecycle", () {
    test("cancel stops the drain; queued chapters survive", () async {
      var resolve = Completer<void>();
      final fetcher = _BlockingFetcher(resolve.future, goodPage);
      final store = FakeStore([chapter("400"), chapter("401")]);
      var active = false;
      final loop = BrowserDownloadLoop(
        fetcher: fetcher,
        store: store,
        pollInterval: const Duration(milliseconds: 5),
        onActiveChanged: (a) => active = a,
        delay: (_) => Future.value(),
      );
      loop.start();
      expect(active, isTrue);
      await fetcher.entered.future;
      loop.cancel();
      expect(active, isFalse);
      resolve.complete();
      // Give the in-flight pass a chance to finish; nothing further runs.
      await Future.delayed(const Duration(milliseconds: 50));
      expect(store.saved.length, lessThanOrEqualTo(1));
      expect(store.dequeued, isEmpty);
      expect(store.queue, hasLength(2), reason: "queue untouched by cancel");
    });
  });
}

/// Fetcher that blocks on [gate] inside the first fetch, recording entry.
class _BlockingFetcher implements HtmlFetcher {
  _BlockingFetcher(this.gate, this.html);

  final Future<void> gate;
  final String html;
  final entered = Completer<void>();
  bool _entered = false;

  @override
  Future<String> fetchHtml(Uri url,
      {required bool Function(String html) isReady}) async {
    if (!_entered) {
      _entered = true;
      entered.complete();
    }
    await gate;
    return html;
  }
}
