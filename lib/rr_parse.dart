// Pure (no network, no `package:flutter/...`) parsing of RoyalRoad HTML,
// plus canonical URL builders and the WebView `isReady` predicates.
//
// Measured live (2026-10): every royalroad.com page (search, series, chapter)
// answers plain HTTP clients with a Cloudflare "Just a moment..." 403 —
// earlier the same day it was an Anubis PoW page with HTTP 200 — so on
// Android these pages are fetched through the WebView (lib/rr_browser.dart)
// and parsed here; the same parsers back the plain-HTTP path in rr.dart for
// platforms without WebViews. Challenge pages are screened by the callers
// (isBotChallenge) before these parsers run; each parser is additionally
// defensive: a page missing required structure raises [RoyalRoadParseError]
// instead of a null-check crash, so a wall page is never mistaken for
// content.
//
// Structures mirrored from real captured pages (June 2025 snapshots):
//
//  - Search: `.fiction-list > .fiction-list-item`, title link under
//    `.fiction-title`, cover `<img src=…>` (royalroadcdn.com).
//  - Series: `.fic-header` (h1 title, `.thumbnail` cover),
//    `.fiction-stats .stats-content` (left column: score spans carrying
//    `data-content="4.83 / 5"`; right column: `li` label/value pairs —
//    "Total Views :", "Followers :", "Favorites :", "Ratings :"),
//    content warnings in a `ul` in the block *before* `.description`,
//    chapter list in the `#chapters` table's first `tbody` (ascending, ids
//    from `/chapter/<id>/` URL segments).
//  - Chapter: `.chapter-content` body; anti-piracy paragraphs hidden via a
//    `<style>` rule (`display:none`) with a random class; author notes in
//    `.author-note` blocks before/after the content.

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:story_reader/db.dart';
import 'package:story_reader/rich_text_tree.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart' show slugify;

const String royalRoadBaseURL = "https://www.royalroad.com/";

/// A RoyalRoad page did not carry the structure its parser needs. Extends
/// [Error] (like the ScribbleHub parsers' [StateError]) so the download
/// isolate's "a real 200 page that can never parse" rule still applies, and
/// implements [Exception] so generic `on Exception` handlers see it too.
final class RoyalRoadParseError extends Error implements Exception {
  final String message;
  RoyalRoadParseError(this.message);

  @override
  String toString() => "RoyalRoadParseError: $message";
}

// ---- canonical URLs ---------------------------------------------------------

/// Search results page for a title query.
Uri royalRoadSearchUrl(String title) => Uri.parse("${royalRoadBaseURL}fictions/search")
    .replace(queryParameters: {"title": title});

/// Series ("fiction") page, e.g.
/// `https://www.royalroad.com/fiction/21220/mother-of-learning/`.
Uri royalRoadSeriesUrl(String seriesId, String seriesName) =>
    Uri.parse("${royalRoadBaseURL}fiction/$seriesId/${slugify(seriesName)}/");

/// Chapter page, e.g.
/// `https://www.royalroad.com/fiction/21220/mother-of-learning/chapter/301778/1-good-morning-brother/`.
Uri royalRoadChapterUrl(
        String seriesId, String seriesName, String chapterId, String chapterName) =>
    Uri.parse("${royalRoadBaseURL}fiction/$seriesId/${slugify(seriesName)}"
        "/chapter/$chapterId/${slugify(chapterName)}/");

// ---- WebView readiness predicates -------------------------------------------
//
// Cheap substring scans (the WebView re-evaluates these every second); a
// Cloudflare/Anubis interstitial matches none of them.

/// Search results page rendered: the results container (or the widget that
/// wraps it, which is also present when the search came back empty).
bool isRoyalRoadSearchReady(String html) {
  final h = html.toLowerCase();
  return h.contains('class="fiction-list') ||
      h.contains("search-container") ||
      h.contains("no fictions were found");
}

/// Series page rendered: the `#chapters` TOC table.
bool isRoyalRoadSeriesReady(String html) {
  final h = html.toLowerCase();
  return h.contains('id="chapters"') || h.contains('class="chapter-row');
}

/// Chapter page rendered: the story body container.
bool isRoyalRoadChapterReady(String html) =>
    html.toLowerCase().contains("chapter-content");

// ---- parsers ----------------------------------------------------------------

/// Parses a RoyalRoad search results page. Returns the matches (ascending is
/// not meaningful here — site order is kept); empty when the page shows no
/// results. Covers are exposed as [SeriesData.thumbnailUrl] only — bytes are
/// fetched separately (plain HTTP works for royalroadcdn.com).
List<SeriesData> parseRoyalRoadSearch(String html) {
  final dom.Document doc;
  try {
    doc = html_parser.parse(html);
  } catch (e) {
    throw RoyalRoadParseError("search page is not parseable HTML");
  }
  final list = doc.querySelector(".fiction-list");
  if (list == null) {
    return []; // "no results" (or a page shape we do not know)
  }
  final out = <SeriesData>[];
  for (final item in list.querySelectorAll(".fiction-list-item")) {
    final anchor = item.querySelector(".fiction-title a") ??
        (item.querySelector(".fiction-title")?.children.isNotEmpty ?? false
            ? item.querySelector(".fiction-title")!.children[0]
            : null);
    final href = anchor?.attributes["href"];
    if (href == null) {
      continue;
    }
    final segments = Uri.parse(href).pathSegments;
    if (segments.length < 2) {
      continue;
    }
    final name = anchor!.text.trim();
    if (name.isEmpty) {
      continue;
    }
    out.add(SeriesData(
      site: Site.royalRoad,
      id: segments[segments.length - 2],
      name: name,
      thumbnailUrl: item.getElementsByTagName("img").isNotEmpty
          ? item.getElementsByTagName("img").first.attributes["src"]
          : null,
    ));
  }
  return out;
}

/// Parses a RoyalRoad series page: metadata + the chapter list in ascending
/// book order (the `#chapters` table is rendered oldest-first; ids come from
/// the `/chapter/<id>/` URL segment, identity per the stable-chapter-identity
/// rule). Throws [RoyalRoadParseError] when the title or the TOC table is
/// missing — including on a Cloudflare/Anubis interstitial.
(SeriesData, List<ChapterData>) parseRoyalRoadSeries(String html, String id) {
  final dom.Document doc;
  try {
    doc = html_parser.parse(html);
  } catch (e) {
    throw RoyalRoadParseError("series page is not parseable HTML");
  }

  final header = doc.querySelector(".fic-header");
  final title = header?.querySelector("h1");
  if (title == null || title.text.trim().isEmpty) {
    throw RoyalRoadParseError("series page has no .fic-header h1 title");
  }

  final chaptersTable = doc.getElementById("chapters");
  final tbodies = chaptersTable?.getElementsByTagName("tbody") ?? const [];
  if (tbodies.isEmpty) {
    throw RoyalRoadParseError("series page has no #chapters table");
  }
  final chapters = <ChapterData>[];
  final seen = <String>{};
  for (final row in tbodies[0].children) {
    final anchor = row.querySelector("td a[href]") ?? row.querySelector("a[href]");
    final href = anchor?.attributes["href"];
    if (href == null) {
      continue; // volume header or decoration row
    }
    final segments = Uri.parse(href).pathSegments;
    // .../fiction/<sid>/<slug>/chapter/<cid>/<cslug>
    final cidIndex = segments.indexOf("chapter");
    if (cidIndex < 0 || cidIndex + 1 >= segments.length) {
      continue;
    }
    final chapterId = segments[cidIndex + 1];
    final name = anchor!.text.trim();
    if (name.isEmpty || !seen.add(chapterId)) {
      continue;
    }
    chapters.add(ChapterData(chapterId, name));
  }

  // Stats. Left column: the overall-score star carries
  // data-content="4.83 / 5". Right column: `li` label/value pairs.
  var score = 0.0;
  var views = 0, follows = 0, favourites = 0, ratings = 0;
  final stats = doc.querySelector(".fiction-stats .stats-content") ??
      doc.querySelector(".stats-content");
  if (stats != null) {
    final scoreSpan =
        stats.querySelector("li [data-content]") ?? stats.querySelector("[data-content]");
    score = _firstDouble(scoreSpan?.attributes["data-content"]) ?? 0.0;
    final lists = stats.children.isEmpty
        ? const <dom.Element>[]
        : [
            for (final col in stats.children)
              if (col.children.isNotEmpty) col.children[0]
          ];
    for (final ul in lists) {
      final lis = ul.children;
      for (var i = 0; i + 1 < lis.length; i++) {
        final label = lis[i]
            .text
            .toLowerCase()
            .replaceAll(RegExp(r"[^a-z ]"), "")
            .replaceAll(RegExp(r"\s+"), " ")
            .trim();
        final value = _firstInt(lis[i + 1].text) ?? 0;
        switch (label) {
          case "total views":
            views = value;
          case "followers":
            follows = value;
          case "favorites":
          case "favourites":
            favourites = value;
          case "ratings":
            ratings = value;
        }
      }
    }
  }

  final description = doc.querySelector(".description");
  var cws = <CW>{};
  if (description != null &&
      (description.parent?.children.length ?? 0) >= 3 &&
      description.previousElementSibling != null) {
    final cwsText =
        description.previousElementSibling!.querySelector("ul")?.text.toLowerCase() ??
            "";
    if (cwsText.contains("sexual")) {
      cws.add(CW.sexual);
    }
    if (cwsText.contains("violence")) {
      cws.add(CW.gore);
    }
    if (cwsText.contains("profanity")) {
      cws.add(CW.language);
    }
    if (cwsText.contains("sensitive")) {
      cws.add(CW.mature);
    }
  }

  return (
    SeriesData(
      site: Site.royalRoad,
      id: id,
      name: title.text.trim(),
      description: description?.text.trim() ?? "",
      chapters: chapters.length,
      views: views,
      follows: follows,
      favourites: favourites,
      ratings: ratings,
      score: score,
      contentWarnings: cws,
      thumbnailUrl: header?.querySelector(".thumbnail")?.attributes["src"],
    ),
    chapters,
  );
}

/// Parses a RoyalRoad chapter page into a [ChapterData]:
///
///  * removes the hidden anti-piracy paragraph (RoyalRoad hides one element
///    per page behind a random-class `<style>` rule with `display:none`),
///  * relocates author notes (`.author-note`) to the start/end of the
///    content wrapped as `wi_authornotes` blocks (what the sanitizer turns
///    into asides), keeping their before/after position,
///  * keeps the *processed* `.chapter-content` inner HTML as
///    [ChapterData.rawHtml] (the EPUB sanitizer input).
///
/// Throws [RoyalRoadParseError] when `.chapter-content` is missing —
/// including on a Cloudflare/Anubis interstitial.
ChapterData parseRoyalRoadChapter(String html, String chapterId, String name) {
  final dom.Document doc;
  try {
    doc = html_parser.parse(html);
  } catch (e) {
    throw RoyalRoadParseError("chapter page is not parseable HTML");
  }
  final content = doc.querySelector(".chapter-content");
  if (content == null) {
    throw RoyalRoadParseError("chapter page has no .chapter-content element");
  }

  // Anti-piracy: the first <style> rule hidden via display:none targets a
  // random class inside the story body. Defensive: skip when absent (older /
  // Adblock-stripped pages) and never let an odd selector crash the parse.
  final hiddenStyle = doc
      .getElementsByTagName("style")
      .where((e) => e.text.contains(RegExp(r"display\s*:\s*none")))
      .toList();
  for (final style in hiddenStyle.take(1)) {
    final selector = style.text.trim().split(RegExp(r"\s*\{"))[0].trim();
    if (selector.isEmpty) {
      continue;
    }
    try {
      content.querySelector(selector)?.remove();
    } catch (_) {
      // Unusual selector syntax: nothing safe to remove.
    }
  }

  final notes = doc.querySelectorAll(".author-note");
  for (final note in notes) {
    bool before = false;
    {
      dom.Element? s = note.parent;
      while ((s = s?.nextElementSibling) != null) {
        if (s == content) {
          before = true;
          break;
        }
      }
    }
    final n = dom.Element.tag("div");
    final b = dom.Element.tag("div");
    n.classes.add("wi_authornotes");
    b.classes.add("wi_authornotes_body");
    b.children.addAll(note.children);
    n.children.add(b);
    if (before) {
      content.children.insert(0, n);
    } else {
      content.children.add(n);
    }
  }

  // The *processed* .chapter-content (hidden anti-piracy paragraph removed,
  // author notes relocated and wrapped as wi_authornotes) is the sanitizer
  // input kept for EPUB export.
  final rawHtml = content.innerHtml;
  return ChapterData(chapterId, name, RichTextDocument.html(content.nodes), rawHtml);
}

int? _firstInt(String text) =>
    int.tryParse(text.replaceAll(",", "").replaceAll(RegExp(r"[^\d-]"), ""));

double? _firstDouble(String? text) {
  if (text == null) {
    return null;
  }
  final match = RegExp(r"[\d]+(?:\.[\d]+)?").firstMatch(text);
  return match == null ? null : double.tryParse(match.group(0)!);
}
