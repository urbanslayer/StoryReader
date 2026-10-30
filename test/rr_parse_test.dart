// Hermetic tests for the pure RoyalRoad parsers, the WebView `isReady`
// predicates and the canonical URLs (no network; fixtures are hand-written
// with placeholder prose, structurally mirrored from real captured pages).
//
// Regression guard: challenge pages (Cloudflare "Just a moment…" 403, the
// today's RR wall, and the Anubis PoW page with HTTP 200, yesterday's) must
// never be parsed as content, and a page missing structure must raise a
// typed RoyalRoadParseError instead of a null-check crash.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/rr_parse.dart';
import 'package:story_reader/series_data.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  final search = fixture('rr_search.html');
  final series = fixture('rr_series.html');
  final chapter = fixture('rr_chapter.html');
  final anubis = fixture('rr_anubis_challenge.html');
  final cloudflare = fixture('sh_cloudflare_interstitial.html');

  group('parseRoyalRoadSearch', () {
    test('parses the two results (ids from the /fiction/<id>/ URL, names, '
        'thumbnail URLs, no bytes)', () {
      final results = parseRoyalRoadSearch(search);
      expect(results.map((s) => s.id), ['111', '222']);
      expect(results.map((s) => s.name), ['Alpha One', 'Beta Two']);
      expect(results.every((s) => s.site == Site.royalRoad), isTrue);
      expect(results.first.thumbnailUrl,
          'https://www.royalroadcdn.invalid/public/covers-large/111-alpha-one.jpg');
      expect(results.every((s) => s.thumbnail == null), isTrue,
          reason: 'parsers never do network I/O');
    });

    test('challenge pages yield no results, never phantom content', () {
      expect(parseRoyalRoadSearch(anubis), isEmpty);
      expect(parseRoyalRoadSearch(cloudflare), isEmpty);
    });
  });

  group('parseRoyalRoadSeries', () {
    final (data, chapters) = parseRoyalRoadSeries(series, '111');

    test('title, description and thumbnail URL', () {
      expect(data.name, 'Alpha One');
      expect(data.id, '111');
      expect(data.site, Site.royalRoad);
      expect(data.description, contains('Zavra is a young apprentice'));
      expect(data.thumbnailUrl,
          'https://www.royalroadcdn.invalid/public/covers-full/111-alpha-one.jpg');
    });

    test('stats (score from the Overall Score data-content, counts from the '
        'label/value list)', () {
      expect(data.score, 4.50);
      expect(data.views, 12345678);
      expect(data.follows, 27213);
      expect(data.favourites, 26207);
      expect(data.ratings, 1435);
    });

    test('content warnings from the block before the description', () {
      expect(data.contentWarnings,
          {CW.sexual, CW.gore, CW.language, CW.mature});
    });

    test('chapters ascending, ids from /chapter/<id>/, volume rows skipped',
        () {
      expect(chapters.map((c) => c.id), ['901', '902', '903']);
      expect(chapters.map((c) => c.name),
          ['1. Chapter One', '2. Chapter Two', '3. Chapter Three']);
      expect(data.chapters, 3);
    });

    test('challenge pages raise the typed parse error, not content', () {
      expect(() => parseRoyalRoadSeries(anubis, '111'),
          throwsA(isA<RoyalRoadParseError>()));
      expect(() => parseRoyalRoadSeries(cloudflare, '111'),
          throwsA(isA<RoyalRoadParseError>()));
    });
  });

  group('parseRoyalRoadChapter', () {
    final data = parseRoyalRoadChapter(chapter, '901', '1. Chapter One');

    test('keeps the queued id/name and produces content + rawHtml', () {
      expect(data.id, '901');
      expect(data.name, '1. Chapter One');
      expect(data.content, isNotNull);
      expect(data.rawHtml, isNotNull);
      expect(data.rawHtml, contains('placeholder corridor'));
    });

    test('removes the hidden anti-piracy paragraph '
        '(<style>.xyz{display:none}</style> + <p class="xyz">)', () {
      expect(data.rawHtml, isNot(contains('unlawfully taken')));
      expect(jsonEncode(data.content!.toJson()),
          isNot(contains('unlawfully taken')));
    });

    test('keeps styled tables for the EPUB sanitizer input', () {
      expect(data.rawHtml, contains('<table'));
      expect(data.rawHtml, contains('text-align: center'));
    });

    test('relocates author notes around the body wrapped as wi_authornotes',
        () {
      final raw = data.rawHtml!;
      expect(raw.indexOf('NOTE-BEFORE'), lessThan(raw.indexOf('Zavra opened')),
          reason: 'the note before the body lands at its start');
      expect(raw.indexOf('NOTE-AFTER'), greaterThan(raw.indexOf('placeholder map')),
          reason: 'the note after the body lands at its end');
      final wrappers = 'class="wi_authornotes"'.allMatches(raw).length;
      final bodies = 'class="wi_authornotes_body"'.allMatches(raw).length;
      expect(wrappers, 2);
      expect(bodies, 2);
      expect(raw, isNot(contains('author-note-portlet')));
    });

    test('challenge pages raise the typed parse error, not content', () {
      expect(() => parseRoyalRoadChapter(anubis, '901', 'x'),
          throwsA(isA<RoyalRoadParseError>()));
      expect(() => parseRoyalRoadChapter(cloudflare, '901', 'x'),
          throwsA(isA<RoyalRoadParseError>()));
    });
  });

  group('WebView isReady predicates', () {
    test('real pages are ready', () {
      expect(isRoyalRoadSearchReady(search), isTrue);
      expect(isRoyalRoadSeriesReady(series), isTrue);
      expect(isRoyalRoadChapterReady(chapter), isTrue);
    });

    test('challenge pages are never ready', () {
      for (final wall in [anubis, cloudflare]) {
        expect(isRoyalRoadSearchReady(wall), isFalse);
        expect(isRoyalRoadSeriesReady(wall), isFalse);
        expect(isRoyalRoadChapterReady(wall), isFalse);
      }
    });
  });

  group('canonical URLs', () {
    test('search', () {
      expect(royalRoadSearchUrl('the farmer').toString(),
          'https://www.royalroad.com/fictions/search?title=the+farmer');
    });
    test('series', () {
      expect(royalRoadSeriesUrl('21220', 'Mother of Learning').toString(),
          'https://www.royalroad.com/fiction/21220/mother-of-learning/');
    });
    test('chapter', () {
      expect(
          royalRoadChapterUrl('21220', 'Mother of Learning', '301778',
                  'Good Morning Brother')
              .toString(),
          'https://www.royalroad.com/fiction/21220/mother-of-learning/chapter/301778/good-morning-brother/');
    });
  });
}
