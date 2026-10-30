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

// ---- account / login -------------------------------------------------------
//
// Shapes mirrored from royalroad.com (Oct 2026):
//  - Logged-in `https://www.royalroad.com/account`: the navbar carries a
//    logout link (`/Account/Logout`); the page/form carries the display name
//    (profile link `/profile/<slug>` in the navbar, or the `Name` input of
//    the profile form).
//  - Logged-out: `/account` redirects to `/account/login`, whose form has a
//    password input and posts to `/account/login`.
// The app never reads the password field — these parsers only look for
// structural markers (links, form action, *name* attributes).

/// Canonical URL whose render tells whether the shared WebView cookie jar
/// holds a RoyalRoad session (`/account` → redirects to the login page when
/// signed out).
Uri royalRoadAccountUrl() => Uri.parse("${royalRoadBaseURL}account");

/// RoyalRoad's own login page (the user types credentials *in the WebView*;
/// the app never sees or stores the password).
Uri royalRoadLoginPageUrl() => Uri.parse("${royalRoadBaseURL}account/login");

/// The URL [CookieManager] is queried with — every royalroad.com cookie
/// (session and Cloudflare alike) is visible from it.
const String royalRoadCookieUrl = "https://www.royalroad.com/";

/// Sign-in state parsed from the account page. [username] is empty when the
/// page proves a session exists but carries no recognisable name element.
final class RoyalRoadAccountState {
  final bool loggedIn;
  final String username;

  const RoyalRoadAccountState({required this.loggedIn, this.username = ""});

  @override
  String toString() =>
      "RoyalRoadAccountState{loggedIn: $loggedIn, username: $username}";
}

/// True when [html] is the login page (a password input posting to
/// `/account/login`); challenge pages carry neither marker, and a logged-in
/// page (which always carries the logout link — even next to a
/// "change password" input) is never mistaken for it.
bool isRoyalRoadLoginPage(String html) {
  final h = html.toLowerCase();
  if (h.contains("logout")) return false;
  final hasPassword =
      h.contains('type="password"') || h.contains("type='password'");
  if (!hasPassword) return false;
  return h.contains("/account/login") ||
      h.contains('name="login"') ||
      h.contains('name="email"');
}

/// Parses the `/account` page. Returns a logged-in state when the page has a
/// logout link, a logged-out state when it is the login page, and `null` for
/// anything else (anti-bot challenge, unknown shape) so callers never infer
/// a sign-in state from a wall page.
RoyalRoadAccountState? parseRoyalRoadAccount(String html) {
  if (isRoyalRoadLoginPage(html)) {
    return const RoyalRoadAccountState(loggedIn: false);
  }
  final dom.Document doc;
  try {
    doc = html_parser.parse(html);
  } catch (_) {
    return null;
  }
  if (royalRoadLogoutHref(doc) == null) return null;
  return RoyalRoadAccountState(loggedIn: true, username: _accountUsername(doc));
}

/// The account page is "loaded" once it is recognisably the logged-in
/// account page or the login page — cheap substring scans, like the other
/// readiness predicates.
bool isRoyalRoadAccountReady(String html) {
  final h = html.toLowerCase();
  return h.contains("logout") || isRoyalRoadLoginPage(html);
}

/// The resolved logout link on a logged-in page (null when absent), or
/// null. RoyalRoad's Sign-Out control is a plain link to `/Account/Logout`.
Uri? royalRoadLogoutUrl(String html) {
  try {
    final doc = html_parser.parse(html);
    return royalRoadLogoutHref(doc);
  } catch (_) {
    return null;
  }
}

Uri? royalRoadLogoutHref(dom.Document doc) {
  for (final a in doc.getElementsByTagName("a")) {
    final href = a.attributes["href"];
    if (href == null) continue;
    if (href.toLowerCase().contains("logout")) {
      try {
        return Uri.parse(royalRoadBaseURL).resolve(href);
      } catch (_) {
        return null;
      }
    }
  }
  return null;
}

String _accountUsername(dom.Document doc) {
  // The profile form's `Name` input carries the display name verbatim.
  for (final input in doc.getElementsByTagName("input")) {
    final name = input.attributes["name"]?.toLowerCase() ?? "";
    if (name == "name") {
      final value = input.attributes["value"]?.trim() ?? "";
      if (value.isNotEmpty) return value;
    }
  }
  // Navbar profile link: `/profile/<slug>` with the display name as text.
  for (final a in doc.getElementsByTagName("a")) {
    final href = a.attributes["href"]?.toLowerCase() ?? "";
    if (!href.contains("/profile/")) continue;
    final text = a.text.trim();
    if (text.isNotEmpty && text.toLowerCase() != "profile") return text;
  }
  return "";
}

/// True for cookie *names* that prove a RoyalRoad login (ASP.NET Core
/// identity session cookie; name matching only — values are never logged or
/// compared).
bool isRoyalRoadAuthCookieName(String name) {
  final n = name.toLowerCase();
  return n.contains("aspnetcore.identity") || n.contains("identity.application");
}

/// Whether any of these cookie names indicates a signed-in session.
bool hasRoyalRoadAuthCookie(Iterable<String> cookieNames) =>
    cookieNames.any(isRoyalRoadAuthCookieName);

/// True for Cloudflare-issued cookies (`cf_clearance` etc.). Keeping them on
/// logout saves the user a fresh browser check on the next fetch.
bool isRoyalRoadCloudflareCookieName(String name) {
  final n = name.toLowerCase();
  return n == "cf_clearance" ||
      n == "_cf_bm" ||
      n == "__cf_bm" ||
      n.startsWith("cf_chl") ||
      n.startsWith("cf_");
}

// ---- follows list (`/my/follows`) -------------------------------------------
//
// Entries reuse the search-page markup (`.fiction-list` > `.fiction-list-item`
// with the `/fiction/<id>/<slug>` title link and the royalroadcdn cover).
// Each entry may additionally carry a "Continue reading"-style link to the
// last-read chapter and a "Latest Chapter" link — both `/chapter/<id>/` URLs.

/// One entry of the user's RoyalRoad follows list.
final class RoyalRoadFollow {
  final String seriesId;
  final String title;
  final String? thumbnailUrl;

  /// Last-read chapter (the "Continue reading" link), when the page has one.
  final String? lastReadChapterId;
  final String? lastReadChapterName;

  /// Newest chapter link on the entry, when the page has one.
  final String? latestChapterId;
  final String? latestChapterName;

  const RoyalRoadFollow({
    required this.seriesId,
    required this.title,
    this.thumbnailUrl,
    this.lastReadChapterId,
    this.lastReadChapterName,
    this.latestChapterId,
    this.latestChapterName,
  });

  @override
  String toString() =>
      "RoyalRoadFollow{seriesId: $seriesId, title: $title, lastRead: "
      "$lastReadChapterId, latest: $latestChapterId}";
}

/// The user was expected to be signed in but the page came back as the
/// login page (RoyalRoad redirected `/my/follows` to `/account/login`).
final class RoyalRoadNotLoggedIn extends Error implements Exception {
  final String url;
  RoyalRoadNotLoggedIn(this.url);

  @override
  String toString() => "RoyalRoadNotLoggedIn: $url redirected to the login page";
}

/// The follows page is "loaded" when the list container, an explicit
/// empty-list message, or the login redirect is on screen (a challenge page
/// matches none).
bool isRoyalRoadFollowsReady(String html) {
  final h = html.toLowerCase();
  return h.contains('class="fiction-list') ||
      h.contains("not following") ||
      h.contains("no followed") ||
      isRoyalRoadLoginPage(html);
}

/// Page 1 is unparameterised; later pages use `?page=N`.
Uri royalRoadFollowsUrl([int page = 1]) {
  final uri = Uri.parse("${royalRoadBaseURL}my/follows");
  return page <= 1 ? uri : uri.replace(queryParameters: {"page": "$page"});
}

/// The highest `?page=N` referenced by the pagination bar (1 when the page
/// is not paginated). The import loop walks 1..this value sequentially.
int parseRoyalRoadFollowsPageCount(String html) {
  var max = 1;
  try {
    final doc = html_parser.parse(html);
    for (final a in doc.getElementsByTagName("a")) {
      final href = a.attributes["href"] ?? "";
      final match = RegExp(r"[?&]page=(\d{1,4})").firstMatch(href);
      if (match == null) continue;
      final n = int.tryParse(match.group(1) ?? "");
      if (n != null && n > max) max = n;
    }
  } catch (_) {
    // Unparseable: treat as a single page.
  }
  return max;
}

/// Parses one follows-list page into entries (site order kept). Defensive:
/// malformed entries are skipped, never fatal; a page without the list
/// container (empty list, challenge, unknown shape) yields an empty result.
List<RoyalRoadFollow> parseRoyalRoadFollows(String html) {
  final dom.Document doc;
  try {
    doc = html_parser.parse(html);
  } catch (_) {
    return const [];
  }
  final out = <RoyalRoadFollow>[];
  final seen = <String>{};
  for (final item in doc.querySelectorAll(".fiction-list-item")) {
    final (seriesId, title) = _followIdentity(item);
    if (seriesId == null || title == null || !seen.add(seriesId)) continue;

    String? lastId, lastName, latestId, latestName;
    for (final a in item.getElementsByTagName("a")) {
      final href = a.attributes["href"] ?? "";
      final chapterId = _royalRoadChapterId(href);
      if (chapterId == null) continue;
      final text = a.text.trim().toLowerCase();
      final isLastRead =
          text.contains("continue") || text.contains("last read");
      final isLatest = text.contains("latest");
      if (isLastRead && lastId == null) {
        lastId = chapterId;
        lastName = a.text.trim();
      } else if (isLatest && latestId == null) {
        latestId = chapterId;
        latestName = a.text.trim();
      }
    }

    out.add(RoyalRoadFollow(
      seriesId: seriesId,
      title: title,
      thumbnailUrl: item.getElementsByTagName("img").isNotEmpty
          ? item.getElementsByTagName("img").first.attributes["src"]
          : null,
      lastReadChapterId: lastId,
      lastReadChapterName: lastName,
      latestChapterId: latestId,
      latestChapterName: latestName,
    ));
  }
  return out;
}

/// `(seriesId, title)` of a `.fiction-list-item`, or `(null, null)` when the
/// entry has no usable `/fiction/<id>/<slug>` link.
(String?, String?) _followIdentity(dom.Element item) {
  final preferred = item.querySelector(".fiction-title a");
  final anchors = <dom.Element>[
    if (preferred != null) preferred,
    ...item.querySelectorAll(".fiction-title a"),
    ...item.getElementsByTagName("a"),
  ];
  for (final anchor in anchors) {
    final href = anchor.attributes["href"];
    if (href == null) continue;
    List<String> segments;
    try {
      segments = Uri.parse(href).pathSegments;
    } catch (_) {
      continue;
    }
    final i = segments.indexOf("fiction");
    if (i < 0 || i + 1 >= segments.length) continue;
    final name = anchor.text.trim();
    if (name.isEmpty) continue;
    return (segments[i + 1], name);
  }
  return (null, null);
}

/// The `<id>` of a `/chapter/<id>/` URL (absolute or relative), or null.
String? _royalRoadChapterId(String href) {
  List<String> segments;
  try {
    segments = Uri.parse(href).pathSegments;
  } catch (_) {
    return null;
  }
  final i = segments.indexOf("chapter");
  if (i < 0 || i + 1 >= segments.length) return null;
  final id = segments[i + 1];
  return id.isEmpty ? null : id;
}

// ---- deleted / missing chapters ---------------------------------------------
//
// A chapter the author deleted (or a bogus id) loads a real error page that
// never grows the expected content container — without these markers the
// WebView would poll it for the full 45 s budget on every retry, forever.
// Matching a marker means "this page is final": accept it immediately and
// dequeue the chapter, exactly like a plain-HTTP 404.

/// RoyalRoad's deleted/missing-chapter and 404 pages.
bool isRoyalRoadNotFound(String html) {
  final h = html.toLowerCase();
  if (RegExp(r"<title[^>]*>[^<]*404").hasMatch(h)) return true;
  if (h.contains("error-404") || h.contains("page-not-found")) return true;
  return h.contains("this chapter has been deleted") ||
      h.contains("chapter not found") ||
      h.contains("chapter does not exist");
}

/// Chapter fetch is "final" once the body or the deleted/404 marker is on
/// screen — the poll loop must not spend its budget waiting on an error page.
bool isRoyalRoadChapterFinal(String html) =>
    isRoyalRoadChapterReady(html) || isRoyalRoadNotFound(html);

int? _firstInt(String text) =>
    int.tryParse(text.replaceAll(",", "").replaceAll(RegExp(r"[^\d-]"), ""));

double? _firstDouble(String? text) {
  if (text == null) {
    return null;
  }
  final match = RegExp(r"[\d]+(?:\.[\d]+)?").firstMatch(text);
  return match == null ? null : double.tryParse(match.group(0)!);
}
