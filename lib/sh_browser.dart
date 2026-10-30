// ScribbleHub chapter fetching through the WebView browser path.
//
// Exposed for on-demand consumers (the EPUB exporter re-fetching missing
// chapters) as well as for `lib/browser_download_loop.dart`'s queue drain:
// same URL, same `isReady` predicate, same pure parser.

import 'package:flutter/foundation.dart';

import 'package:story_reader/browser_fetch.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart';

/// Fetches one ScribbleHub chapter page through [BrowserFetcher] (real
/// WebView: passes Cloudflare where plain HTTP cannot) and parses it with the
/// shared [parseScribbleHubChapter] — off the UI thread via [compute].
///
/// Throws [SiteBlocked] when the site kept serving an anti-bot challenge
/// (user cancelled or verification timed out) and [TimeoutException] on a
/// dead page.
Future<ChapterData> fetchScribbleHubChapterViaBrowser(
    String seriesId, String seriesName, String chapterId) async {
  final html = await BrowserFetcher.instance.fetchHtml(
      scribbleHubChapterUrl(seriesId, seriesName, chapterId),
      isReady: isScribbleHubChapterFinal);
  return parseScribbleHubChapterOffIsolate(html, chapterId);
}

/// Parse chapter HTML in a background isolate ([parseScribbleHubChapter] is
/// pure Dart, so it is safe to ship off the UI thread).
Future<ChapterData> parseScribbleHubChapterOffIsolate(
        String html, String chapterId) =>
    compute(_parseChapterTask, (html, chapterId));

ChapterData _parseChapterTask((String, String) args) =>
    parseScribbleHubChapter(args.$1, args.$2);
