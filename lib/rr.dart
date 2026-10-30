
import 'dart:typed_data';

import 'package:chopper/chopper.dart';
import 'package:story_reader/client.dart';
import 'package:story_reader/prefs.dart';
import 'package:story_reader/rr_parse.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart';
import 'package:story_reader/sh_toc.dart';

part 'rr.chopper.dart';


const String baseURL = royalRoadBaseURL;

/// Builds the typed [SiteBlocked] every RoyalRoad call site throws when an
/// anti-bot challenge answers instead of content. Measured 2026-10: RR moved
/// from an Anubis PoW page (HTTP 200) to a Cloudflare "Just a moment..."
/// 403 — both kinds are recognised. On platforms with WebViews the pages
/// are fetched through the WebView instead (see `lib/rr_browser.dart`); this
/// HTTP path stays for Linux and as the shared contract for the parsers.
SiteBlocked _rrBlocked(String url, int statusCode, String body) => SiteBlocked(
      url,
      statusCode: statusCode,
      kind: botChallengeKind(statusCode, body),
      siteName: "RoyalRoad",
    );

@ChopperApi(baseUrl: baseURL)
abstract class RRAPI extends ChopperService {
  
  Future<Response<List<SeriesData>>> simpleSearch(String name) async {
    var resp = await _simpleSearch(name);
    if (isBotChallenge(resp.statusCode, resp.bodyString)) {
      throw _rrBlocked("${baseURL}fictions/search", resp.statusCode, resp.bodyString);
    }
    if (! resp.isSuccessful) {
      return resp.copyWith();
    }
    // parseRoyalRoadSearch never null-crashes on a page without the results
    // list (it returns an empty list); challenge pages were screened above.
    List<SeriesData> respBody = parseRoyalRoadSearch(resp.bodyString);
    for (var s in respBody) {
      s.thumbnail = await _thumbnail(s.thumbnailUrl);
    }
    return resp.copyWith(body: respBody);
  }
  
  Future<Uint8List?> _thumbnail(String? url) async {
    if (url == null || url.isEmpty) {
      return null;
    }
    if (! Preferences.useImages.value) {
      return null;
    }
    if (url.startsWith("/")) {
      url = Uri.parse(baseURL).resolve(url).toString();
    }
    return (await _rrC.get(Uri.parse(url))).bodyBytes;
  }
  
  Future<Response<(SeriesData, List<ChapterData>)>> series(String id, String name) async {
    var resp = await _series(id, slugify(name));
    if (isBotChallenge(resp.statusCode, resp.bodyString)) {
      throw _rrBlocked("${baseURL}fiction/$id/", resp.statusCode, resp.bodyString);
    }
    if (! resp.isSuccessful) {
      return resp.copyWith();
    }
    var (data, chapters) = parseRoyalRoadSeries(resp.bodyString, id);
    data.thumbnail = await _thumbnail(data.thumbnailUrl);
    return resp.copyWith(body: (data, chapters));
  }
  
  Future<Response<ChapterData>> chapterContents(SeriesData s, String id, String name) async {
    var resp = await _chapterContents(s.id, slugify(s.name), id, slugify(name));
    if (isBotChallenge(resp.statusCode, resp.bodyString)) {
      throw _rrBlocked("${baseURL}fiction/${s.id}/chapter/$id/",
          resp.statusCode, resp.bodyString);
    }
    if (! resp.isSuccessful) {
      return resp.copyWith();
    }
    // RoyalRoadParseError (extends Error) on a 200 page without
    // .chapter-content: the download isolate reads that as "a real page
    // that can never parse" and dequeues the chapter, as before.
    return resp.copyWith(body: parseRoyalRoadChapter(resp.bodyString, id, name));
  }
  
  
  @Get(path: "fictions/search")
  Future<Response> _simpleSearch(@Query() String title);
  
  @Get(path: "fiction/{id}/{slugged}")
  Future<Response> _series(@Path("id") String id, @Path("slugged") String slugged);
  
  @Get(path: "fiction/{sid}/{sslug}/chapter/{cid}/{cslug}")
  Future<Response> _chapterContents(@Path("sid") String seriesID, @Path("sslug") String seriesSlug, @Path("cid") String chapterID, @Path("cslug") String chapterSlug);
  
  /// Builds an API instance. [client] is only for tests (fixture-replaying
  /// clients); production uses the shared, retrying site client.
  static RRAPI create([ChopperClient? client]) => _$RRAPI(client ?? _rrC);
}

final _rrC = ChopperClient(client: httpClient(), interceptors: [RetryInterceptor()]);
