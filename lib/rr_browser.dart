// RoyalRoad page fetching through the WebView browser path.
//
// Measured live (2026-10): every royalroad.com page (search, series/TOC,
// chapter) answers plain HTTP clients with a Cloudflare "Just a moment..."
// 403 (earlier the same day: an Anubis PoW page with HTTP 200 — both walls
// are supported). On Android these pages therefore load through the same
// reused HeadlessInAppWebView that ScribbleHub chapters use
// (`lib/browser_fetch.dart`): serialised through the one fetcher, paced at
// >= 1.5 s between page loads, with user-completed verification on a hard
// challenge (`lib/pages/verify_page.dart`). Parsing goes through the pure
// parsers in `lib/rr_parse.dart`, so the WebView path and the plain-HTTP
// path (kept for Linux, where there is no WebView) produce identical data.
//
// Thumbnails (royalroadcdn.com) still answer plain HTTP, so bytes are
// fetched over HTTP with a graceful give-up; page HTML never does.

import 'package:flutter/foundation.dart';

import 'package:story_reader/browser_fetch.dart';
import 'package:story_reader/client.dart';
import 'package:story_reader/prefs.dart';
import 'package:story_reader/rr_parse.dart';
import 'package:story_reader/series_data.dart';

/// Search cap matching the historical search page behaviour (10 results).
const int royalRoadBrowserSearchLimit = 10;

/// Searches RoyalRoad through [BrowserFetcher] and parses with
/// [parseRoyalRoadSearch]; thumbnail bytes top up over plain HTTP (images
// survive Cloudflare) and a thumbnail failure never fails the search.
Future<List<SeriesData>> fetchRoyalRoadSearchViaBrowser(String query) async {
  final html = await BrowserFetcher.instance.fetchHtml(
      royalRoadSearchUrl(query),
      isReady: isRoyalRoadSearchReady);
  final results = parseRoyalRoadSearch(html)
      .take(royalRoadBrowserSearchLimit)
      .toList();
  await _fillThumbnails(results);
  return results;
}

/// Fetches a series page (metadata + ascending chapter TOC) through
/// [BrowserFetcher]. Throws [SiteBlocked] when the site kept serving a
/// challenge, [RoyalRoadParseError] when the page has no TOC structure.
Future<(SeriesData, List<ChapterData>)> fetchRoyalRoadSeriesViaBrowser(
    String seriesId, String seriesName) async {
  final html = await BrowserFetcher.instance.fetchHtml(
      royalRoadSeriesUrl(seriesId, seriesName),
      isReady: isRoyalRoadSeriesReady);
  final (data, chapters) = parseRoyalRoadSeries(html, seriesId);
  await _fillThumbnails([data]);
  return (data, chapters);
}

/// Fetches one RoyalRoad chapter page through [BrowserFetcher] (real
/// WebView: passes Cloudflare where plain HTTP cannot) and parses it with
/// the shared [parseRoyalRoadChapter] — off the UI thread via [compute].
///
/// Throws [SiteBlocked] when the site kept serving an anti-bot challenge
/// (user cancelled or verification timed out), [TimeoutException] on a dead
/// page and [RoyalRoadParseError] when the page cannot parse.
Future<ChapterData> fetchRoyalRoadChapterViaBrowser(
    String seriesId, String seriesName, String chapterId,
    [String chapterName = ""]) async {
  final html = await BrowserFetcher.instance.fetchHtml(
      royalRoadChapterUrl(seriesId, seriesName, chapterId, chapterName),
      isReady: isRoyalRoadChapterReady);
  return parseRoyalRoadChapterOffIsolate(html, chapterId, chapterName);
}

/// Parse chapter HTML in a background isolate ([parseRoyalRoadChapter] is
/// pure Dart, so it is safe to ship off the UI thread).
Future<ChapterData> parseRoyalRoadChapterOffIsolate(
        String html, String chapterId, String chapterName) =>
    compute(_parseChapterTask, (html, chapterId, chapterName));

ChapterData _parseChapterTask((String, String, String) args) =>
    parseRoyalRoadChapter(args.$1, args.$2, args.$3);

/// Fetches [thumbnailUrl] bytes over plain HTTP into `thumbnail` when images
/// are enabled. royalroadcdn.com is not behind the page wall; if it ever
/// joins it, the thumbnail is simply skipped (graceful, not fatal).
Future<void> _fillThumbnails(List<SeriesData> items) async {
  if (!Preferences.useImages.value) {
    return;
  }
  final urls = {
    for (final s in items)
      if (s.thumbnailUrl != null && s.thumbnailUrl!.isNotEmpty) s.thumbnailUrl!
  };
  if (urls.isEmpty) {
    return;
  }
  final client = httpClient();
  try {
    final bytesByUrl = <String, Uint8List>{};
    for (final url in urls) {
      final resolved =
          url.startsWith("/") ? Uri.parse(royalRoadBaseURL).resolve(url) : Uri.parse(url);
      try {
        final resp = await client
            .get(resolved.replace(scheme: "https"))
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          bytesByUrl[url] = resp.bodyBytes;
        }
      } catch (_) {
        // Thumbnail trouble never fails the page it belongs to.
      }
    }
    for (final s in items) {
      s.thumbnail = bytesByUrl[s.thumbnailUrl];
    }
  } finally {
    client.close();
  }
}
