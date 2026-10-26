import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chopper/chopper.dart';
import 'package:html/parser.dart';
import 'package:html/dom.dart';
import 'package:http/http.dart' as http;
import 'package:story_reader/client.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/prefs.dart';
import 'package:story_reader/rich_text_tree.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh_toc.dart';
import 'package:async/async.dart';

part 'sh.chopper.dart';

/// Builds the typed [SiteBlocked] both ScribbleHub call sites throw when an
/// anti-bot challenge (Cloudflare today, Anubis if it ever appears) answers
/// instead of content.
SiteBlocked _shBlocked(String url, int statusCode, String body) => SiteBlocked(
      url,
      statusCode: statusCode,
      kind: botChallengeKind(statusCode, body),
      siteName: "ScribbleHub",
    );

@ChopperApi(baseUrl: "https://www.scribblehub.com/")
abstract class SHAPI extends ChopperService {
  Future<Response<List<SeriesData>>> simpleSearch(String name) async {
    var resp = await _base({"action": "wi_ajaxsearchmain", "strOne": name, "strType": "series"});
    if (isBotChallenge(resp.statusCode, resp.bodyString)) {
      throw _shBlocked("https://www.scribblehub.com/wp-admin/admin-ajax.php",
          resp.statusCode, resp.bodyString);
    }
    if (!resp.isSuccessful) {
      return resp.copyWith();
    }
    List<SeriesData> resBody = [];
    var body = parseFragment(resp.bodyString);
    for (var a in body.children[0].children) {
      var segments = Uri.parse(a.firstChild!.attributes["href"]!).pathSegments;
      var id = segments[segments.length - 3];

      String thumbnailURL = a.firstChild!.firstChild!.attributes["src"]!;
      Uint8List? thumbnail;
      if (Preferences.useImages.value) {
        thumbnail = (await _shC.get(Uri.parse(thumbnailURL))).bodyBytes;
      }
      resBody.add(SeriesData(site: Site.scribbleHub, name: a.text.trim(), id: id, thumbnail: thumbnail));
    }
    return resp.copyWith(body: resBody);
  }

  @Post(path: "wp-admin/admin-ajax.php")
  @FormUrlEncoded()
  Future<Response> _base(@Body() Map<String, dynamic> fields);

  /// One `?toc=N` page of the series page's table of contents. ScribbleHub
  /// ignores the slug for routing, so a fixed placeholder slug is fine when
  /// only the numeric series id is known. Measured live: Cloudflare answers
  /// `?toc=N` with 403 unless the request carries the series page as
  /// `Referer`, hence the required header parameter.
  @Get(path: "series/{id}/{slugged}/")
  Future<Response> _seriesToc(@Path("id") String id, @Path("slugged") String slugged,
      @Query("toc") int toc, @Header("Referer") String referer);

  /// Fetches the table of contents for a series.
  ///
  /// Tries the `wi_gettocchp` admin-ajax endpoint first; if it errors, is
  /// blocked by Cloudflare, or yields fewer than two chapters, falls back to
  /// scraping the series page (`?toc=1..n`, sequential requests with
  /// [tocPageDelay] between pages).
  ///
  /// Both endpoints list chapters newest-first, so the returned
  /// [Response.body] keeps the historical contract of this method and is
  /// **descending (newest-first)** — `series_net_page.dart` reverses it for
  /// display. Throws [SiteBlocked] when the site answered with an anti-bot
  /// challenge (and nothing could be salvaged from the pagination
  /// fallback), instead of a bare [HttpException].
  Future<Response<List<ChapterData>>> chapters(String id,
      {Duration tocPageDelay = const Duration(milliseconds: 750)}) async {
    Response? ajaxResp;
    SiteBlocked? blocked;
    try {
      var resp = await _base({"action": "wi_gettocchp", "strSID": id});
      if (isBotChallenge(resp.statusCode, resp.bodyString)) {
        blocked = _shBlocked("https://www.scribblehub.com/wp-admin/admin-ajax.php",
            resp.statusCode, resp.bodyString);
      } else if (resp.isSuccessful) {
        var parsed = parseScribbleHubToc(resp.bodyString);
        if (parsed.length > 1) {
          // Historical contract: newest-first (document) order.
          return resp.copyWith(body: parsed.reversed.toList());
        }
        ajaxResp = resp;
      }
    } catch (e) {
      // Network error / timeout: fall through to the series page fallback.
    }

    // Fallback: series pages. The plain series page (no query) *is* the first
    // TOC page; pages 2..n need `?toc=N` with the series page as Referer (see
    // _seriesToc). Page 1 holds the newest chapters; later pages hold older
    // ones. Stop once a page adds nothing new.
    const maxTocPages = 200; // ~3000 chapters at ~15 per page; safety bound.
    const tocSlug = "chapters"; // slug is ignored for routing
    final pageUrl = "https://www.scribblehub.com/series/$id/$tocSlug/";
    final pageBodies = <String>[];
    final seen = <String>{};
    Response? lastResp;
    var complete = false;
    for (var toc = 1; toc <= maxTocPages; toc++) {
      if (toc > 1) {
        await Future.delayed(tocPageDelay);
      }
      Response resp;
      try {
        resp = toc == 1 ? await _series(id, tocSlug) : await _seriesToc(id, tocSlug, toc, pageUrl);
      } catch (e) {
        break; // network failure: don't retry endlessly here, RetryInterceptor already did
      }
      if (isBotChallenge(resp.statusCode, resp.bodyString)) {
        blocked = _shBlocked("$pageUrl?toc=$toc", resp.statusCode, resp.bodyString);
        break;
      }
      if (!resp.isSuccessful) {
        break;
      }
      final pageAsc = parseScribbleHubToc(resp.bodyString);
      final fresh = pageAsc.where((c) => seen.add(c.id)).toList();
      if (fresh.isEmpty) {
        complete = true; // pagination exhausted — count stopped growing
        break;
      }
      pageBodies.add(resp.bodyString);
      lastResp = resp;
    }

    if (lastResp != null && (complete || pageBodies.length >= maxTocPages)) {
      final ascending = parseScribbleHubTocPages(pageBodies);
      // Historical contract: newest-first.
      return lastResp.copyWith(body: ascending.reversed.toList());
    }
    // Nothing usable: surface the block distinctly if we saw one.
    if (blocked != null) {
      throw blocked;
    }
    if (ajaxResp != null) {
      // The ajax call worked but produced <= 1 chapter; hand back whatever it
      // parsed so single-chapter series still render.
      return ajaxResp.copyWith(body: parseScribbleHubToc(ajaxResp.bodyString));
    }
    throw const HttpException("Could not fetch ScribbleHub table of contents");
  }

  @Get(path: "read/{idSlug}/chapter/{id}/")
  Future<Response> _chapterContents(@Path("idSlug") String idSlug, @Path("id") String id);

  Future<Response<ChapterData>> chapterContents(SeriesData series, String id) async {
    var resp = await _chapterContents("${series.id}-${slugify(series.name)}", id);
    if (isBotChallenge(resp.statusCode, resp.bodyString)) {
      throw _shBlocked("https://www.scribblehub.com/read/${series.id}/chapter/$id/",
          resp.statusCode, resp.bodyString);
    }
    if (!resp.isSuccessful) {
      return resp.copyWith();
    }
    var body = parse(resp.bodyString);
    return resp.copyWith(
        body: ChapterData(
            id, body.getElementsByClassName("chapter-title").first.text, RichTextDocument.html(body.getElementById("chp_raw")!.nodes)));
  }

  @Get(path: "series/{id}/{slugged}/")
  Future<Response> _series(@Path("id") String id, @Path("slugged") String slugged);

  Future<Response<SeriesData>> series(String id, String name) async {
    var resp = await _series(id, slugify(name));
    if (isBotChallenge(resp.statusCode, resp.bodyString)) {
      throw _shBlocked("https://www.scribblehub.com/series/$id/",
          resp.statusCode, resp.bodyString);
    }
    if (!resp.isSuccessful) {
      return resp.copyWith();
    }
    var body = parse(resp.bodyString);
    var stats = body.getElementsByClassName("mb_stat");
    var cws = <CW>{};
    var cwElements = body.getElementsByClassName("ul_rate_expand");
    if (cwElements.isNotEmpty) {
      var cwElement = cwElements[0];
      if (cwElement.text.contains("Gore")) {
        cws.add(CW.gore);
      }
      if (cwElement.text.contains("Sexual")) {
        cws.add(CW.sexual);
      }
      if (cwElement.text.contains("Strong")) {
        cws.add(CW.language);
      }
    }
    Uint8List? thumbnail;
    if (Preferences.useImages.value) {
      thumbnail =
          (await _shC.get(Uri.parse(body.getElementsByClassName("fic_image").first.children.first.attributes["src"]!)))
              .bodyBytes;
    }
    return resp.copyWith(
        body: SeriesData(
            site: Site.scribbleHub,
            name: body.getElementsByClassName("fic_title")[0].text.trim(),
            description: body.getElementsByClassName("wi_fic_desc")[0].text.trim(),
            id: id,
            contentWarnings: cws,
            chapters: int.parse(stats.where((s) => s.text == "Chapters").first.parent!.nodes[1].text!),
            score: double.parse(body.getElementById("ratefic_user")!.children.last.children.first.text),
            views: postfixedParseInt(stats.where((s) => s.text == "Views").first.parent!.nodes[1].text!),
            favourites: int.parse(stats.where((s) => s.text == "Favorites").first.parent!.nodes[1].text!),
            follows: int.parse(stats.where((s) => s.text == "Readers").first.parent!.nodes[1].text!),
            ratings: int.parse(body.getElementsByClassName("rate_more")[0].text.split(" ")[0]),
            thumbnail: thumbnail));
  }

  /// Builds an API instance. [client] is only for tests (fixture-replaying
  /// clients); production uses the shared, retrying site client.
  static SHAPI create([ChopperClient? client]) => _$SHAPI(client ?? _shC);
}

final _shC = ChopperClient(client: httpClient(), interceptors: [RetryInterceptor()]);

int postfixedParseInt(String s) {
  s = s.trim();
  if (s.endsWith("k")) {
    return (double.parse(s.substring(0, s.length - 1)) * 1000).toInt();
  }
  if (s.endsWith("M")) {
    return (double.parse(s.substring(0, s.length - 1)) * 1000000).toInt();
  }
  return int.parse(s);
}

String slugify(String name) {
  // TODO What happens with multiple consecutive spaces? Unicode chars? Multiple consecutive -?
  var slugged = name.replaceAll(RegExp(r"[^a-zA-Z ]"), "").replaceAll(" ", "-").replaceAll(RegExp(r"-+"), "-").toLowerCase();
  //print(slugged);
  return slugged;
}

final class RetryInterceptor implements Interceptor {
  @override
  FutureOr<Response<BodyType>> intercept<BodyType>(Chain<BodyType> chain) async {
    Response<BodyType>? res;
    var headers = Map.fromEntries(chain.request.headers.entries);
    // NOTE: do not inject a browser User-Agent here — see lib/client.dart for
    // the measured live behavior (spoofed browser UAs from dart:io trigger
    // Cloudflare 403 interstitials on both sites; the default UA passes).
    var req = chain.request.copyWith(headers: headers);
    for (int i = 0; i < 3; i++) {
      try {
        res = (await Future.value(chain.proceed(req)).timeout(Duration(seconds: 5 * (i + 1)), onTimeout: null))
            as Response<BodyType>?;
      } catch (e) {
        //print(e);
      }
      if (res != null) {
        if (res.body != null) {
          return res;
        } else {
          if (res.statusCode == 429) {
            await Future.delayed(Duration(seconds: 3 * (i + 1)));
          }
          //print(res.statusCode);
          //print(res.headers);
          //print(res.error);
        }
      }
      //print("Try ${i+1} failed");
    }
    if (res == null) {
      throw const HttpException("");
    }
    return res;
  }
}
