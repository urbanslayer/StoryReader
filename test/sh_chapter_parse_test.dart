// Unit tests for the pure ScribbleHub chapter-page parse (the HTML->ChapterData
// half of the WebView download path). Fixture is a hand-written page; no
// copyrighted prose anywhere.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/sh.dart';

void main() {
  final chapterHtml = File("test/fixtures/sh_chapter_page.html").readAsStringSync();
  final challengeHtml =
      File("test/fixtures/sh_cloudflare_interstitial.html").readAsStringSync();

  group("parseScribbleHubChapter", () {
    test("extracts title and #chp_raw content", () {
      final data = parseScribbleHubChapter(chapterHtml, "2640407");
      expect(data.id, "2640407");
      expect(data.name, "Seven - A Handmade Fixture");
      final content = data.content;
      expect(content, isNotNull, reason: "#chp_raw subtree must become a RichTextDocument");
      expect(content!.document, isNotEmpty);
      // The fixture's table and image survive the RichText conversion.
      expect(content.document.any((e) => e.toString().isNotEmpty), isTrue);
      expect(content.imageSources.map((u) => u.toString()),
          contains("https://example.com/status-chart.png"));
    });

    test("throws StateError when #chp_raw is missing (unparseable real page)", () {
      const noContent =
          '<html><body><div class="chapter-title">Nothing here</div></body></html>';
      expect(() => parseScribbleHubChapter(noContent, "1"), throwsStateError);
    });

    test("throws StateError when the chapter title is missing", () {
      const noTitle = '<html><body><div id="chp_raw"><p>x</p></div></body></html>';
      expect(() => parseScribbleHubChapter(noTitle, "1"), throwsStateError);
    });

    test("a Cloudflare interstitial never parses", () {
      expect(() => parseScribbleHubChapter(challengeHtml, "1"), throwsStateError);
    });
  });

  group("isScribbleHubChapterReady", () {
    test("ready exactly when the content node is present", () {
      expect(isScribbleHubChapterReady(chapterHtml), isTrue);
      expect(isScribbleHubChapterReady(challengeHtml), isFalse);
      expect(isScribbleHubChapterReady("<html></html>"), isFalse);
    });
  });

  group("scribbleHubChapterUrl", () {
    test("builds the canonical /read/<id>-<slug>/chapter/<id>/ URL", () {
      final url = scribbleHubChapterUrl("623932", "On Astral Tides", "2640407");
      expect(
          url.toString(),
          "https://www.scribblehub.com/read/623932-on-astral-tides/chapter/2640407/");
      // The chopper path segment (idSlug) is the second path segment.
      expect(url.pathSegments[0], "read");
      expect(url.pathSegments[1], "623932-on-astral-tides");
    });
  });
}
