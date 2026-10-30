// Import of the user's RoyalRoad Follows list into the local library.
//
// The follows pages (`https://www.royalroad.com/my/follows`) sit behind the
// same Cloudflare wall as every other royalroad.com page, so they load
// through the shared [HtmlFetcher] (production: the `BrowserFetcher`
// singleton — serialised and paced like every other WebView fetch; tests
// inject a fake). Parsing is the pure [parseRoyalRoadFollows] in
// `lib/rr_parse.dart`.
//
// Import policy (deliberate):
//  * Series already in the library are counted and left untouched.
//  * New series are added with an empty description (filled on first online
//    visit) and a best-effort thumbnail fetched over plain HTTP
//    (royalroadcdn.com is not walled; failures never fail the import).
//  * Chapters are NOT downloaded — a follows list can mean thousands of
//    chapters. A "last read" chapter link from the page is stored as the
//    stable lastReadChapterID marker (plus lastReadDate so the series
//    surfaces in the library's recent list); the user then opens a series
//    and uses Download all / Export EPUB.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:story_reader/browser_download_loop.dart';
import 'package:story_reader/client.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/rr_parse.dart';

/// Safety cap on follows pagination (RoyalRoad pages the list at 50 entries).
const int royalRoadFollowsMaxPages = 100;

/// Tally of one follows import.
final class FollowsImportReport {
  int added = 0;
  int existing = 0;
  int skipped = 0;
  int pages = 0;

  String get summary =>
      "Added $added series, $existing already in library, $skipped skipped "
      "(errors)";
}

/// Fetches thumbnail bytes over plain HTTP, best effort (null on any
/// failure — royalroadcdn.com is not Cloudflare-walled, but the import must
/// survive whatever happens to an image).
Future<Uint8List?> fetchRoyalRoadThumbnailBytes(String url) async {
  final client = httpClient();
  try {
    final resolved = url.startsWith("/")
        ? Uri.parse(royalRoadBaseURL).resolve(url)
        : Uri.parse(url);
    final resp = await client
        .get(resolved.replace(scheme: "https"))
        .timeout(const Duration(seconds: 10));
    return resp.statusCode == 200 ? resp.bodyBytes : null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// Walks the follows list (page 1, then `?page=N` while the pagination bar
/// advertises more, sequentially — the fetcher paces politely) and files
/// every entry that is not already in the library.
///
/// Throws [RoyalRoadNotLoggedIn] when a page redirects to the login page and
/// [SiteBlocked] when the fetcher gave up on an anti-bot challenge.
/// [fetchThumbnail] is injectable (null disables thumbnail fetching, keeping
/// tests hermetic); [onProgress] reports (pagesDone, seriesSeen).
Future<FollowsImportReport> importRoyalRoadFollows({
  required AppDB db,
  required HtmlFetcher fetcher,
  Future<Uint8List?> Function(String url)? fetchThumbnail,
  void Function(int pagesDone, int seriesSeen)? onProgress,
}) async {
  final report = FollowsImportReport();
  final firstUrl = royalRoadFollowsUrl(1);
  var html = await fetcher.fetchHtml(firstUrl, isReady: isRoyalRoadFollowsReady);
  if (isRoyalRoadLoginPage(html)) throw RoyalRoadNotLoggedIn(firstUrl.toString());
  final pageCount =
      parseRoyalRoadFollowsPageCount(html).clamp(1, royalRoadFollowsMaxPages);

  for (var page = 1; page <= pageCount; page++) {
    if (page > 1) {
      final url = royalRoadFollowsUrl(page);
      html = await fetcher.fetchHtml(url, isReady: isRoyalRoadFollowsReady);
      if (isRoyalRoadLoginPage(html)) throw RoyalRoadNotLoggedIn(url.toString());
    }
    report.pages = page;
    for (final follow in parseRoyalRoadFollows(html)) {
      if (await db.hasSeries(Site.royalRoad, follow.seriesId)) {
        report.existing++;
        continue;
      }
      try {
        Uint8List? bytes;
        int? width, height;
        final thumbnailUrl = follow.thumbnailUrl;
        if (fetchThumbnail != null &&
            thumbnailUrl != null &&
            thumbnailUrl.isNotEmpty) {
          try {
            bytes = await fetchThumbnail(thumbnailUrl);
          } catch (_) {
            bytes = null; // thumbnails never cost a library row
          }
          if (bytes != null) {
            final (w, h) = await _imageSize(bytes);
            width = w;
            height = h;
          }
        }
        await db.addSeriesIfNeeded(Site.royalRoad, follow.seriesId,
            follow.title, "", bytes, width, height);
        final lastRead = follow.lastReadChapterId;
        if (lastRead != null && lastRead.isNotEmpty) {
          // The series row was just created, so it has no lastReadChapterID
          // yet; existing series were skipped above and stay untouched.
          await db.setLastReadChapter(Site.royalRoad, follow.seriesId, lastRead);
          await db.updateLastReadDate(Site.royalRoad, follow.seriesId);
        }
        report.added++;
      } catch (_) {
        report.skipped++;
      }
    }
    onProgress?.call(page, report.added + report.existing + report.skipped);
  }
  return report;
}

Future<(int?, int?)> _imageSize(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size = (frame.image.width, frame.image.height);
    frame.image.dispose();
    codec.dispose();
    return size;
  } catch (_) {
    return (null, null);
  }
}
