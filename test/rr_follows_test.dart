// Hermetic tests for the RoyalRoad follows import: the pure page parser
// (entries, last-read/latest chapter links, pagination detection, empty
// list, login redirect), the WebView readiness predicate, and the import
// orchestration against a fake fetcher + in-memory AppDB (new series added,
// existing series untouched, lastReadChapterID only stamped on new rows).

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/browser_download_loop.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/rr_follows.dart';
import 'package:story_reader/rr_parse.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Returns canned HTML per URL and enforces the fetcher contract: the
/// response must satisfy the caller's `isReady` predicate (so the fixtures
/// double as predicate tests).
class StubFetcher implements HtmlFetcher {
  StubFetcher(this.pages);

  final Map<String, Object> pages;
  final requested = <Uri>[];

  @override
  Future<String> fetchHtml(Uri url,
      {required bool Function(String html) isReady}) async {
    requested.add(url);
    final page = pages[url.toString()];
    if (page == null) throw StateError("unexpected fetch to $url");
    if (page is! String) throw page; // RoyalRoadNotLoggedIn / SiteBlocked
    expect(isReady(page), isTrue,
        reason: "fixture for $url must satisfy the follows isReady "
            "predicate (or the fetch would stall)");
    return page;
  }
}

void main() {
  final follows = fixture('rr_follows.html');
  final empty = fixture('rr_follows_empty.html');
  final loginRedirect = fixture('rr_follows_login_redirect.html');
  final anubis = fixture('rr_anubis_challenge.html');
  final cloudflare = fixture('sh_cloudflare_interstitial.html');

  group('parseRoyalRoadFollows', () {
    final parsed = parseRoyalRoadFollows(follows);

    test('three entries with ids from /fiction/<id>/ and cover URLs', () {
      expect(parsed.map((f) => f.seriesId), ['111', '222', '333']);
      expect(parsed.map((f) => f.title), ['Alpha One', 'Beta Two', 'Gamma Three']);
      expect(parsed.first.thumbnailUrl,
          'https://www.royalroadcdn.invalid/public/covers-large/111-alpha-one.jpg');
      expect(parsed[2].thumbnailUrl, isNull);
    });

    test('last-read link (Continue Reading) and latest-chapter link', () {
      expect(parsed[0].lastReadChapterId, '901');
      expect(parsed[0].lastReadChapterName, isNotEmpty);
      expect(parsed[0].latestChapterId, '950');
      // Entry two has only a latest-chapter link, entry three none at all.
      expect(parsed[1].lastReadChapterId, isNull);
      expect(parsed[1].latestChapterId, '777');
      expect(parsed[2].lastReadChapterId, isNull);
      expect(parsed[2].latestChapterId, isNull);
    });

    test('empty list, walls and garbage parse to no entries without crashing',
        () {
      expect(parseRoyalRoadFollows(empty), isEmpty);
      expect(parseRoyalRoadFollows(anubis), isEmpty);
      expect(parseRoyalRoadFollows(cloudflare), isEmpty);
      expect(parseRoyalRoadFollows('>>> not html'), isEmpty);
    });
  });

  group('pagination detection', () {
    test('highest ?page=N from the pagination bar', () {
      expect(parseRoyalRoadFollowsPageCount(follows), 3);
      expect(parseRoyalRoadFollowsPageCount(empty), 1);
      expect(parseRoyalRoadFollowsPageCount('garbage <<<'), 1);
    });
    test('page URLs', () {
      expect(royalRoadFollowsUrl().toString(),
          'https://www.royalroad.com/my/follows');
      expect(royalRoadFollowsUrl(2).toString(),
          'https://www.royalroad.com/my/follows?page=2');
    });
  });

  group('isRoyalRoadFollowsReady', () {
    test('list, empty marker and login redirect are all "loaded"', () {
      expect(isRoyalRoadFollowsReady(follows), isTrue);
      expect(isRoyalRoadFollowsReady(empty), isTrue);
      expect(isRoyalRoadFollowsReady(loginRedirect), isTrue);
    });
    test('anti-bot walls are not', () {
      expect(isRoyalRoadFollowsReady(anubis), isFalse);
      expect(isRoyalRoadFollowsReady(cloudflare), isFalse);
    });
  });

  group('isRoyalRoadLoginPage (follows login redirect)', () {
    test('the redirect page is recognised, the list is not', () {
      expect(isRoyalRoadLoginPage(loginRedirect), isTrue);
      expect(isRoyalRoadLoginPage(follows), isFalse);
    });
  });

  group('importRoyalRoadFollows', () {
    late AppDB db;
    setUp(() => db = AppDB(NativeDatabase.memory()));
    tearDown(() async => db.close());

    Future<Series?> series(String id) => (db.select(db.seriesTable)
          ..where((s) => s.id.equals(id)))
        .getSingleOrNull();

    test('new series added (last-read marker + date only for them), '
        'existing untouched, pagination walked sequentially', () async {
      // 222 is already in the library under its own name/marker.
      await db.addSeriesIfNeeded(Site.royalRoad, "222", "My Old Name", "old");
      await db.setLastReadChapter(Site.royalRoad, "222", "keep-me");

      final fetcher = StubFetcher({
        'https://www.royalroad.com/my/follows': follows,
        'https://www.royalroad.com/my/follows?page=2': empty,
        'https://www.royalroad.com/my/follows?page=3': empty,
      });
      final report =
          await importRoyalRoadFollows(db: db, fetcher: fetcher);

      expect(report.summary,
          'Added 2 series, 1 already in library, 0 skipped (errors)');
      expect(report.pages, 3);
      expect(
          fetcher.requested.map((u) => u.toString()),
          [
            'https://www.royalroad.com/my/follows',
            'https://www.royalroad.com/my/follows?page=2',
            'https://www.royalroad.com/my/follows?page=3',
          ],
          reason: 'sequential polite pagination');

      final added = await series('111');
      expect(added, isNotNull);
      expect(added!.name, 'Alpha One');
      expect(added.description, isEmpty, reason: 'filled on first online visit');
      expect(added.lastReadChapterID, '901',
          reason: 'follows page had a last-read chapter link');
      expect(added.lastReadDate, isNotNull,
          reason: 'surfaces in the library recent list');

      final noMarker = await series('333');
      expect(noMarker, isNotNull);
      expect(noMarker!.lastReadChapterID, isNull,
          reason: 'no last-read link -> no marker, no date');
      expect(noMarker.lastReadDate, isNull);

      final existing = await series('222');
      expect(existing!.name, 'My Old Name', reason: 'untouched');
      expect(existing.description, 'old');
      expect(existing.lastReadChapterID, 'keep-me', reason: 'untouched');
      expect(existing.lastReadDate, isNull);
    });

    test('no chapters are queued by the import', () async {
      final fetcher = StubFetcher({
        'https://www.royalroad.com/my/follows': follows,
        'https://www.royalroad.com/my/follows?page=2': empty,
        'https://www.royalroad.com/my/follows?page=3': empty,
      });
      await importRoyalRoadFollows(db: db, fetcher: fetcher);
      expect(await db.queuedChapters(), isEmpty);
    });

    test('login redirect fails the import with RoyalRoadNotLoggedIn', () async {
      final fetcher = StubFetcher({
        'https://www.royalroad.com/my/follows': loginRedirect,
      });
      await expectLater(
          importRoyalRoadFollows(db: db, fetcher: fetcher),
          throwsA(isA<RoyalRoadNotLoggedIn>()));
      expect(await db.hasSeries(Site.royalRoad, '111'), isFalse);
    });

    test('empty follows list imports nothing and errors nothing', () async {
      final fetcher = StubFetcher({
        'https://www.royalroad.com/my/follows': empty,
      });
      final report = await importRoyalRoadFollows(db: db, fetcher: fetcher);
      expect(report.added, 0);
      expect(report.existing, 0);
      expect(report.skipped, 0);
    });

    test('thumbnail bytes are stored best-effort; undecodable bytes still '
        'add the series', () async {
      final fetcher = StubFetcher({
        'https://www.royalroad.com/my/follows': follows,
        'https://www.royalroad.com/my/follows?page=2': empty,
        'https://www.royalroad.com/my/follows?page=3': empty,
      });
      final report = await importRoyalRoadFollows(
        db: db,
        fetcher: fetcher,
        fetchThumbnail: (url) async =>
            Uint8List.fromList([1, 2, 3]), // not a real image
      );
      expect(report.added, 3);
      final added = await series('111');
      expect(added!.thumbnail, Uint8List.fromList([1, 2, 3]));
      expect(added.thumbnailWidth, isNull,
          reason: 'undecodable bytes -> no dimensions, series still added');
    });

    test('a throwing thumbnail fetcher never loses a series row', () async {
      final fetcher = StubFetcher({
        'https://www.royalroad.com/my/follows': follows,
        'https://www.royalroad.com/my/follows?page=2': empty,
        'https://www.royalroad.com/my/follows?page=3': empty,
      });
      final report = await importRoyalRoadFollows(
        db: db,
        fetcher: fetcher,
        fetchThumbnail: (url) async => throw StateError("cdn down"),
      );
      expect(report.skipped, 0);
      expect(report.added, 3);
      final added = await series('111');
      expect(added, isNotNull);
      expect(added!.thumbnail, isNull);
    });
  });
}
