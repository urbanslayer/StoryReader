// Hermetic tests for the pure ScribbleHub TOC parser (no network).
//
// Fixtures:
//  - sh_ajax_fragment.html: hand-written `wi_gettocchp` ajax fragment shape
//    (nested divs, `li > a`, newest-first, volume header, non-chapter link).
//  - sh_series_page.html: hand-written full series page with `.toc_w`/`.toc_a`
//    rows newest-first, a volume header row, and a decoy /chapter/ link
//    outside the TOC.
//  - sh_series_page_live.html / _toc2.html: captured real pages for series
//    623932 (On Astral Tides), ?toc=1 and ?toc=2.
//  - sh_ajax_fragment_live.html: captured real `wi_gettocchp` response for
//    series 623932 (448 chapters, newest-first).
//  - sh_cloudflare_interstitial.html: captured-style CF "Just a moment..." page.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh_toc.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

List<String> ids(List<ChapterData> chapters) => chapters.map((c) => c.id).toList();

void main() {
  group('parseScribbleHubToc — admin-ajax fragment shape', () {
    final parsed = parseScribbleHubToc(fixture('sh_ajax_fragment.html'));

    test('returns ascending order (fixture is newest-first)', () {
      expect(ids(parsed), ['101', '102', '103', '104']);
    });

    test('ids come from /chapter/<id>/, names are trimmed, junk skipped', () {
      expect(parsed.first.name, 'Chapter One');
      expect(parsed[2].name, 'Chapter Three – Contains Things');
      // "View all" (rankings link) and the volume header row are not chapters.
      expect(parsed.length, 4);
    });
  });

  group('parseScribbleHubToc — series page (.toc_w) shape', () {
    final parsed = parseScribbleHubToc(fixture('sh_series_page.html'));

    test('returns ascending order (page is newest-first)', () {
      expect(ids(parsed), ['301', '302', '303']);
    });

    test('volume header row (li.toc_w without chapter link) is skipped', () {
      expect(parsed.map((c) => c.name), ['One', 'Two', 'Three']);
    });

    test('decoy /chapter/ link outside the TOC is ignored', () {
      expect(ids(parsed), isNot(contains('9999999')));
    });
  });

  group('parseScribbleHubToc — live fixtures (series 623932, On Astral Tides)', () {
    final p1 = parseScribbleHubToc(fixture('sh_series_page_live.html'));

    test('toc=1 page parses 15 entries in ascending order', () {
      expect(p1.length, 15);
      // Page is rendered newest-first (723 "Seven Hundred And Twenty-Three"
      // at the top, 710 at the bottom); ascending means the bottom entry is
      // first after parsing.
      expect(p1.first.id, '2565799');
      expect(p1.first.name, 'Seven Hundred And Ten');
      expect(p1.last.id, '2640407');
      expect(p1.last.name, 'Seven Hundred And Twenty-Three');
      // Site-stable numeric ids only; never the `order` attribute (448..434
      // on this page, which disagrees with the written chapter numbers).
      expect(ids(p1), everyElement(matches(RegExp(r'^\d+$'))));
    });

    test('?toc=N pages merge into one ascending, gapless list', () {
      final p2 = parseScribbleHubToc(fixture('sh_series_page_live_toc2.html'));
      expect(p2.length, 15);
      expect(p2.first.id, '2488586'); // "Six Hundred And Ninety-Nine"
      expect(p2.last.id, '2560642'); // "Seven Hundred And Nine"

      final merged = parseScribbleHubTocPages(
          [fixture('sh_series_page_live.html'), fixture('sh_series_page_live_toc2.html')]);
      expect(merged.length, 30);
      // Older page comes first overall.
      expect(merged.first.id, '2488586');
      expect(merged.last.id, '2640407');
      // Page boundary: 709 (newest on toc=2) is immediately followed by 710
      // (oldest on toc=1) in ascending order.
      expect(ids(merged)[14], '2560642');
      expect(ids(merged)[15], '2565799');
      // No duplicates.
      expect(ids(merged).toSet().length, 30);
    });

    test('merging identical pages dedupes to one copy', () {
      final html = fixture('sh_series_page_live.html');
      expect(parseScribbleHubTocPages([html, html, html]).length, 15);
    });
  });

  group('parseScribbleHubToc — recorded live admin-ajax fragment', () {
    final ajax = parseScribbleHubToc(fixture('sh_ajax_fragment_live.html'));

    test('parses all 448 chapters in ascending order', () {
      expect(ajax.length, 448);
      // Recorded newest-first (Seven Hundred And Twenty-Three first, cnt=448);
      // ascending must start at the book's first chapter.
      expect(ajax.first.id, '623934');
      expect(ajax.first.name, 'One');
      expect(ajax.last.id, '2640407');
      expect(ajax.last.name, 'Seven Hundred And Twenty-Three');
      expect(ids(ajax).toSet().length, 448, reason: 'ids must be unique');
      expect(ids(ajax), everyElement(matches(RegExp(r'^\d+$'))));
    });

    test('matches the series-page pagination for the overlapping chapters', () {
      // The same chapters parsed off the live ?toc=1 series page must appear
      // with identical ids/names in the ajax list (both shapes agree).
      final page = parseScribbleHubToc(fixture('sh_series_page_live.html'));
      final ajaxById = {for (final c in ajax) c.id: c.name};
      for (final c in page) {
        expect(ajaxById[c.id], c.name);
      }
    });
  });

  group('garbage input', () {
    test('empty and junk HTML parse to an empty list, never throw', () {
      expect(parseScribbleHubToc(''), isEmpty);
      expect(parseScribbleHubToc('not html at all \x00\x01 <<>> <a href='), isEmpty);
      expect(parseScribbleHubToc('<div><p>hello</p></div>'), isEmpty);
      expect(parseScribbleHubTocPages(['', 'junk <<<']), isEmpty);
    });
  });

  group('Cloudflare interstitial detection', () {
    final interstitial = fixture('sh_cloudflare_interstitial.html');

    test('403 plus "Just a moment" page is detected', () {
      expect(isCloudflareInterstitial(403, interstitial), isTrue);
      expect(isCloudflareInterstitial(403, ''), isTrue); // status alone suffices
      expect(isCloudflareInterstitial(null, interstitial), isTrue); // body alone suffices
    });

    test('real content is not flagged', () {
      expect(isCloudflareInterstitial(200, fixture('sh_series_page_live.html')), isFalse);
      expect(isCloudflareInterstitial(200, '<div>chapters</div>'), isFalse);
      expect(isCloudflareInterstitial(500, 'server exploded'), isFalse);
    });

    test('interstitial body parses to zero chapters', () {
      expect(parseScribbleHubToc(interstitial), isEmpty);
    });

    test('SiteBlocked is a distinguishable typed failure', () {
      const err = SiteBlocked('https://www.scribblehub.com/wp-admin/admin-ajax.php',
          statusCode: 403);
      expect(err, isA<Exception>());
      expect(err.statusCode, 403);
      expect(err.toString(), contains('SiteBlocked'));
      expect(err.toString(), contains('403'));
      // Not swallowed by generic Exception checks the UI already does…
      Object thrown = err;
      try {
        throw err;
      } on SiteBlocked catch (e) {
        thrown = e;
      }
      expect(thrown, same(err));
    });
  });
}
