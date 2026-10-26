

import 'dart:async';
import 'dart:isolate';

import 'package:chopper/chopper.dart';
import 'package:drift/isolate.dart';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:story_reader/client.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/download_outcome.dart';
import 'package:story_reader/main.dart';
import 'package:story_reader/rr.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh_toc.dart';

void startDownloadManager() {
  if (_downloadManager == null) {
    _chapterDownloadManager();
  }
}

void stopDownloadManager() {
  var d = _downloadManager;
  if (d != null) {
    d.kill();
  }
}

final StreamController<bool> downloadManagerActiveStream = (() {
  var c = StreamController<bool>.broadcast();
  c.onListen = () => c.add(_downloadManagerActive.value);
  return c;
})();
final ValueNotifier<bool> _downloadManagerActive = (() {
  var v = ValueNotifier(false);
  v.addListener(() => downloadManagerActiveStream.add(v.value));
  return v;
})();
Isolate? _downloadManager;



void _chapterDownloadManager() async {
  var client = httpClient();
  var connection = await appDB.serializableConnection();
  var exit = ReceivePort();
  exit.listen((_) {
    _downloadManager = null;
    _downloadManagerActive.value = false;
  });
  _downloadManagerActive.value = true;
  var i = await Isolate.spawn((_) async {
    var db = AppDB(await connection.connect());
    while (true) {
      var l = await db.queuedChapters();
      var sl = await db.series();
      var il = await db.queuedImages();
      // Backoff: 60 s when the site blocked us (Cloudflare/Anubis challenge
      // or a 429 rate limit), 5 s after any other transient failure inside
      // this pass, otherwise the normal 1 s poll. Chapters are only ever
      // dropped from the queue when they are genuinely gone (404/410) or
      // their page can never parse — see `classifyChapterFetch`.
      var backoff = const Duration(seconds: 1);
      try {
        for (var im in il) {
          var req = http.Request("GET", Uri.parse(im.url));
          req.headers.addAll({
            "Sec-Fetch-Dest": "image",
            "Sec-Fetch-Mode": "no-cors",
            "Sec-Fetch-Site": "cross-site",
            "Referer": baseURL,
          });
          req.followRedirects = false;
          await db.setImageData(im.id, await (await client.send(req)).stream.toBytes());
        }
        for (var c in l) {
          var s = sl.firstWhere((s) => s.site == c.site && s.id == c.id);
          try {
            Response<ChapterData> resp;
            switch (c.site) {
              case Site.scribbleHub:
                resp = await shC.chapterContents(SeriesData(site: c.site, id: c.id, name: s.name), c.chapterID);
              case Site.royalRoad:
                resp = await rrC.chapterContents(SeriesData(site: c.site, id: c.id, name: s.name), c.chapterID, c.name);
            }
            // The API layer throws SiteBlocked on a challenge page; classify
            // whatever came back otherwise (null body from RetryInterceptor
            // after 3 failed tries means "fetch failed", not "chapter gone").
            var data = resp.body;
            var outcome =
                classifyChapterFetch(resp.statusCode, resp.bodyString, data?.content != null);
            switch (outcome) {
              case DownloadOutcome.save:
                await db.saveChapter(c.site, c.id, c.number, c.chapterID, data!.content!, data.name);
              case DownloadOutcome.dequeue:
                // 404/410 (chapter deleted upstream) or a 200 page for *this*
                // chapter that can never parse: dequeue it and carry on with
                // the rest, so one dead chapter cannot stall the whole queue.
                print("Giving up on chapter ${c.chapterID} (${c.name}): HTTP ${resp.statusCode}");
                await db.dequeueChapterByID(c.site, c.id, c.chapterID);
              case DownloadOutcome.retrySoon:
                // Transient (5xx, other non-success): stop this pass, retry soon.
                print("Retrying chapter ${c.chapterID} (${c.name}) soon: HTTP ${resp.statusCode}");
                backoff = const Duration(seconds: 5);
                break;
              case DownloadOutcome.retrySlow:
                // Blocked or rate limited, not gone: keep the queue intact.
                print("Site blocked/limited chapter fetch (${resp.statusCode}); keeping queue");
                backoff = const Duration(seconds: 60);
                break;
            }
            if (outcome == DownloadOutcome.retrySoon || outcome == DownloadOutcome.retrySlow) {
              break; // rest of the pass would hit the same wall
            }
          } on SiteBlocked {
            // Blocked, not gone: keep the queue intact and back off.
            backoff = const Duration(seconds: 60);
            break;
          } catch (e) {
            if (e is Error) {
              // The API layer already screens out challenge pages and
              // non-success responses, so an Error here is a *200 page*
              // whose content node is missing: retrying the same HTML can
              // never succeed — dequeue just this chapter.
              print("Could not parse chapter ${c.chapterID} (${c.name}): $e");
              await db.dequeueChapterByID(c.site, c.id, c.chapterID);
              continue;
            }
            // Transient error (network, timeout): stop this pass, retry soon.
            print(e);
            backoff = const Duration(seconds: 5);
            break;
          }
          await Future.delayed(Duration.zero);
        }
      } catch (e) {
        if (e is Error) {
          print(e.stackTrace);
        }
        print(e);
        backoff = const Duration(seconds: 5);
      }
      await Future.delayed(backoff);
    }
  }, [], errorsAreFatal: true, debugName: "Download Isolate", onExit: exit.sendPort);
  _downloadManager = i;
}






