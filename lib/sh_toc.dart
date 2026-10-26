// Pure (no `package:flutter/...` imports) parsing of ScribbleHub tables of
// contents, plus anti-bot challenge detection (Cloudflare *and* Anubis).
//
// ScribbleHub serves the chapter list in two shapes:
//
//  1. The `wi_gettocchp` admin-ajax fragment historically consumed by
//     `SHAPI.chapters()` (`body.children[0].children[0].children`): nested
//     `div`s around a `ul` of `li > a` chapter links.
//  2. The series page itself (and its `?toc=N` pages): `<li class="toc_w"
//     order="N">` rows holding `<a class="toc_a"
//     href="…/read/<series-slug>/chapter/<chapterId>/">Title</a>`, possibly
//     interleaved with volume/header rows (`li.toc_w` without a chapter link).
//
// Both lists are rendered **newest-first**; the parsers here return the list
// reversed, i.e. in ascending book order. Identity is the numeric id in the
// `/chapter/<id>/` URL path segment — never the `order` attribute, which is a
// site-side position counter that disagrees with the book's own chapter
// numbering once chapters are deleted.

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:story_reader/series_data.dart';

/// Which anti-bot system answered with a challenge instead of content.
enum BotChallengeKind { cloudflare, anubis }

/// A site (anti-bot wall in front of it) answered with a challenge page
/// instead of content. Distinguishable from a bare network failure so the UI
/// can tell the user "the site blocked the request", and carries [kind] /
/// [siteName] so the message can name the site and the challenge system
/// (e.g. "RoyalRoad is asking for a browser check (Anubis)").
final class SiteBlocked implements Exception {
  /// The URL that returned the challenge page.
  final String url;

  /// HTTP status seen, when known (Cloudflare usually 403, Anubis 200).
  final int? statusCode;

  /// Which anti-bot system produced the page, when recognised.
  final BotChallengeKind? kind;

  /// Name of the site that produced the page, when known.
  final String? siteName;

  const SiteBlocked(this.url, {this.statusCode, this.kind, this.siteName});

  /// User-facing explanation naming the site and the challenge system.
  String get userMessage {
    final site = siteName ?? "The site";
    return switch (kind) {
      BotChallengeKind.cloudflare =>
        "$site is asking for a browser check (Cloudflare). Try again later.",
      BotChallengeKind.anubis =>
        "$site is asking for a browser check (Anubis). Try again later.",
      null => "$site blocked the request. Try again later.",
    };
  }

  @override
  String toString() =>
      "SiteBlocked{url: $url, statusCode: $statusCode, kind: $kind, siteName: $siteName}";
}

/// Whether a response looks like a Cloudflare challenge/error page rather than
/// real content: an HTTP 403, or a body carrying the classic interstitial
/// titles ("Just a moment…", "Attention Required! | Cloudflare").
bool isCloudflareInterstitial(int? statusCode, String body) =>
    statusCode == 403 || _cloudflareMarkers(body);

/// Whether the body carries Cloudflare interstitial markers (title scan of
/// the head of the document, where the title lives).
bool _cloudflareMarkers(String body) {
  final head = body.length > 4096 ? body.substring(0, 4096) : body;
  final lower = head.toLowerCase();
  return lower.contains("just a moment") ||
      lower.contains("attention required");
}

/// Whether the body carries Anubis (github.com/TecharoHQ/anubis) challenge
/// markers. Anubis answers with HTTP **200**, so status codes never help;
/// only the page contents identify it. Measured live against RoyalRoad
/// (2026-10): title "Making sure you&#39;re not a bot!" plus
/// `<script id="anubis_version">` / `<script id="anubis_challenge">` JSON
/// blobs (`{"rules":{"algorithm":"fast","difficulty":4},...}`).
bool _isAnubisBody(String body) {
  final head = body.length > 8192 ? body.substring(0, 8192) : body;
  final lower = head.toLowerCase();
  if (lower.contains("anubis_challenge") || lower.contains("anubis_version")) {
    return true;
  }
  // The exact challenge title, apostrophe HTML-escaped (`you&#39;re`) or not.
  // Require both halves so a chapter that merely mentions "not a bot" in its
  // first kilobytes cannot trip this.
  return lower.contains("making sure you") && lower.contains("not a bot");
}

/// Which anti-bot challenge (if any) a response carries. Anubis is checked
/// first: it arrives with status 200, so the Cloudflare status rule must not
/// shadow it, and a body scan distinguishes them anyway.
BotChallengeKind? botChallengeKind(int? statusCode, String? body) {
  if (_isAnubisBody(body ?? "")) {
    return BotChallengeKind.anubis;
  }
  if (statusCode == 403 || _cloudflareMarkers(body ?? "")) {
    return BotChallengeKind.cloudflare;
  }
  return null;
}

/// Whether a response is an anti-bot challenge page (Cloudflare or Anubis)
/// rather than real content. Unlike [isCloudflareInterstitial] this also
/// catches Anubis pages, which RoyalRoad serves with HTTP 200.
bool isBotChallenge(int? statusCode, String? body) =>
    botChallengeKind(statusCode, body) != null;

/// Matches the site-stable chapter id inside a chapter URL such as
/// `https://www.scribblehub.com/read/623932-<slug>/chapter/2640407/`.
final RegExp _chapterIdPattern = RegExp(r"/chapter/(\d+)");

String? _chapterIdFromHref(String href) => _chapterIdPattern.firstMatch(href)?.group(1);

/// Parses one ScribbleHub TOC document — either the `wi_gettocchp` ajax
/// fragment or a (paged) series page with `.toc_w`/`.toc_a` entries — and
/// returns the chapters in **ascending book order** (the site lists
/// newest-first, so the document order is reversed).
///
/// Volume/header rows, `order` attributes, and links that are not chapter
/// links are skipped. Never throws: unparseable input yields an empty list;
/// duplicates (same `/chapter/<id>/`) keep their first occurrence.
List<ChapterData> parseScribbleHubToc(String html) {
  final dom.DocumentFragment doc;
  try {
    doc = html_parser.parseFragment(html);
  } catch (_) {
    return [];
  }

  // Prefer the TOC structure so decoy /chapter/ links elsewhere on a series
  // page (widgets, "most recent" boxes) cannot leak into the list.
  var anchors = doc.querySelectorAll("li.toc_w > a[href]");
  if (anchors.isEmpty) {
    // `.toc_a` may be nested (e.g. wrapped in a span) on either shape.
    anchors = doc.querySelectorAll("li.toc_w a[href]");
  }
  if (anchors.isEmpty) {
    // Recorded live `wi_gettocchp` fragment: `div#c_toc_box > ol.ol_toc >
    // li.li_toc > a` (one entry per chapter, newest first).
    anchors = doc.querySelectorAll("li.li_toc a[href]");
  }
  if (anchors.isEmpty) {
    // Legacy ajax fragment: `div > div > ul > li > a`, no toc_* classes.
    // Restrict to the TOC containers the endpoint is known to emit before
    // falling back to a global anchor scan.
    for (final container in const [
      "div.wi-main-body-episode a[href]",
      "ul.wi-episode-list a[href]",
      "div.read-container a[href]",
      "div.read_container_data a[href]",
      "div.page-item-detail a[href]",
    ]) {
      anchors = doc.querySelectorAll(container);
      if (anchors.isNotEmpty) {
        break;
      }
    }
  }
  if (anchors.isEmpty) {
    anchors = doc.querySelectorAll("a[href]");
  }

  final chapters = <ChapterData>[];
  final seen = <String>{};
  for (final a in anchors) {
    final href = a.attributes["href"];
    if (href == null) {
      continue;
    }
    final id = _chapterIdFromHref(href);
    if (id == null) {
      // Volume header, "view all", bookmark, or any non-chapter link.
      continue;
    }
    final name = a.text.trim();
    if (name.isEmpty) {
      continue;
    }
    if (seen.add(id)) {
      chapters.add(ChapterData(id, name));
    }
  }
  // Newest-first on the site → return ascending book order.
  return chapters.reversed.toList();
}

/// Merges successive `?toc=N` series pages (page 1 first; each page is
/// newest-first and later pages hold *older* chapters) into one ascending list.
///
/// Duplicate entries across pages keep their first occurrence.
List<ChapterData> parseScribbleHubTocPages(List<String> pageHtmls) {
  final pages = <List<ChapterData>>[];
  final seen = <String>{};
  for (final page in pageHtmls) {
    final ascending = parseScribbleHubToc(page).where((c) => seen.add(c.id)).toList();
    if (ascending.isNotEmpty) {
      pages.add(ascending);
    }
  }
  final merged = <ChapterData>[];
  // First page holds the newest chapters: concatenate oldest page first.
  for (final page in pages.reversed) {
    merged.addAll(page);
  }
  return merged;
}
