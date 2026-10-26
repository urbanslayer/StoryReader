

import 'dart:async';
import 'dart:isolate';

import 'package:chopper/chopper.dart';
import 'package:drift/isolate.dart';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:story_reader/client.dart';
import 'package:story_reader/db.dart';
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
      // Backoff: 60 s when the site blocked us (Cloudflare), 5 s after any
      // other failure inside this pass, otherwise the normal 1 s poll.
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
            if (isCloudflareInterstitial(resp.statusCode, resp.bodyString)) {
              // Blocked, not gone: keep the queue intact and back off.
              throw SiteBlocked("chapter ${c.chapterID}", statusCode: resp.statusCode);
            }
            var data = resp.body;
            if (data == null || data.content == null) {
              // 404/410 (chapter deleted upstream) or a parse failure for
              // *this* chapter: dequeue it and carry on with the rest, so one
              // dead chapter cannot stall the whole queue forever.
              print("Giving up on chapter ${c.chapterID} (${c.name}): HTTP ${resp.statusCode}");
              await db.dequeueChapterByID(c.site, c.id, c.chapterID);
              continue;
            }
            await db.saveChapter(c.site, c.id, c.number, c.chapterID, data.content!, data.name);
          } on SiteBlocked {
            backoff = const Duration(seconds: 60);
            break;
          } catch (e) {
            if (e is Error) {
              // Chapter-specific parse failure (missing content node):
              // retrying the same HTML can never succeed — dequeue it.
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






