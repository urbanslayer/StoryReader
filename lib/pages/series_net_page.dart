import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/download_manager.dart';
import 'package:story_reader/main.dart';
import 'package:story_reader/prefs.dart';
import 'package:story_reader/sh_toc.dart';
import 'dart:ui' as ui;

import '../series_data.dart';

class SeriesNetPage extends StatefulWidget {
  final Site site;
  final String id;
  final String name;

  const SeriesNetPage({super.key, required this.site, required this.id, required this.name});

  @override
  State<SeriesNetPage> createState() => _SeriesNetPageState();
}

class _SeriesNetPageState extends State<SeriesNetPage> {
  late Future<SeriesData> req;

  List<ChapterData>? chapters;
  int? thumbnailWidth;
  int? thumbnailHeight;
  
  bool errored = false;

  /// The series is in the library (a `series` row exists): its DB rows were
  /// reconciled against the live TOC and the retained-removed section may
  /// exist.
  bool inLibrary = false;

  /// Non-null when the site answered with an anti-bot challenge (Cloudflare
  /// or Anubis): show an inline message instead of silently popping.
  String? blockedMessage;

  /// Applies a freshly-fetched ascending TOC: reconciles the stored chapters
  /// against it when (and only when) the series is already in the library —
  /// browsing must never create chapter rows — then renders.
  Future<void> _applyToc(List<ChapterData> ascending) async {
    var lib = await appDB.hasSeries(widget.site, widget.id);
    if (lib) {
      await appDB.reconcileChapters(widget.site, widget.id, ascending);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      chapters = ascending;
      inLibrary = lib;
    });
  }

  /// Surfaces a [SiteBlocked] as the inline blocked message (safe to call
  /// before the first build: pre-mount assignments are picked up by it).
  void _showBlocked(SiteBlocked d) {
    if (blockedMessage != null) {
      return;
    }
    if (mounted) {
      setState(() => blockedMessage = d.userMessage);
    } else {
      blockedMessage = d.userMessage;
    }
  }

  /// Error handler for the TOC fetches: a blocked site is surfaced to the
  /// user (naming the site and the challenge system); everything else keeps
  /// the historical pop-to-behaviour.
  void _onTocError(Object d, StackTrace t) {
    if (d is SiteBlocked) {
      _showBlocked(d);
      return;
    }
    if (!errored) {
      errored = true;
      Future.microtask(() async => router.pop());
    }
  }
  
  Future<void> _setThumbnail(Uint8List? thumbnail) async {
    if (Preferences.useImages.value && thumbnail != null) {
      var b = await ui.ImmutableBuffer.fromUint8List(thumbnail);
      var i = await ui.ImageDescriptor.encoded(b);
      var w = i.width;
      var h = i.height;
      thumbnailWidth = w;
      thumbnailHeight = h;
      i.dispose();
      b.dispose();
      appDB.setThumbnail(widget.site, widget.id, thumbnail, w, h);
    }
  }
  
  @override
  void initState() {
    super.initState();
    switch (widget.site) {
      case Site.scribbleHub:
        req = shC.series(widget.id, widget.name).then((r) async {
          var b = r.body!;
          var thumbnail = b.thumbnail;
          await _setThumbnail(thumbnail);
          return b;
        }).onError((d, t) {
          if (d is SiteBlocked) {
            _showBlocked(d);
          } else if (! errored) {
            errored = true;
            Future.microtask(() async => router.pop());
          }
          return SeriesData(site: widget.site, id: widget.id);
        });
        
        shC
            .chapters(widget.id)
            .then((r) => r.body!)
            // ScribbleHub returns newest-first; canonical order is ascending.
            .then((cs) => _applyToc(cs.reversed.toList()))
            .onError(_onTocError);
      case Site.royalRoad:
        req = rrC.series(widget.id, widget.name).then((r) async {
          var b = r.body!;
          var s = b.$1;
          var cl = b.$2;
          var thumbnail = s.thumbnail;
          await _setThumbnail(thumbnail);
          // RoyalRoad already lists chapters ascending.
          await _applyToc(cl);
          return s;
        }).onError((d, t) {
          if (d is SiteBlocked) {
            _showBlocked(d);
          } else if (! errored) {
            errored = true;
            Future.microtask(() async => router.pop());
          }
          return SeriesData(site: widget.site, id: widget.id);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder(
            future: req,
            builder: (c, d) {
              if (d.hasError) {
                router.pop();
                return const Center(child: CircularProgressIndicator());
              }
              if (d.hasData) {
                var s = d.data!;
                return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: CustomScrollView(restorationId: "SeriesNetScroll",
                      slivers: [
                        SliverAppBar(
                          pinned: true,
                          title: Row(
                            children: [
                              Flexible(
                                flex: 1,
                                child: Text(
                                  s.name,
                                  style: const TextStyle(fontSize: 30),
                                  softWrap: true,
                                ),
                              )
                            ],
                          ),
                        ),
                        SliverList.list(children: [
                          Row(
                            children: [
                              if (Preferences.useImages.value && s.thumbnail != null)
                                Flexible(
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 8.0),
                                    child: ConstrainedBox(
                                        constraints: const BoxConstraints(minWidth: 250, maxWidth: 250),
                                        child: Center(child: Image.memory(s.thumbnail!, fit: BoxFit.scaleDown))),
                                  ),
                                ),
                              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text("Site: ${s.site.toString()}"),
                                Text(
                                  "Views: ${s.views}",
                                  textAlign: TextAlign.start,
                                ),
                                Text("Likes: ${s.favourites}"),
                                Text("Followers: ${s.follows}"),
                                Text("Rating: ${s.score.toStringAsFixed(2)}"),
                                Text("Number of ratings: ${s.ratings}"),
                                Text("Chapters: ${s.chapters}"),
                                (() {
                                  if (s.contentWarnings.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text("Content warnings:"),
                                      Padding(
                                        padding: const EdgeInsets.all(16.0),
                                        child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: s.contentWarnings.map((w) => Text(w.name())).toList()),
                                      )
                                    ],
                                  );
                                })(),
                              ]),
                            ],
                          ),
                          Divider(),
                          SelectableText(s.description),
                          Divider(),
                        ]),
                        ...(() {
                          var l = <Widget>[];
                          if (blockedMessage != null) {
                            l.add(Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16.0),
                              child: Center(
                                  child: Text(blockedMessage!,
                                      softWrap: true, textAlign: TextAlign.center)),
                            ));
                          }
                          if (chapters == null) {
                            if (blockedMessage == null) {
                              l.add(Center(child: CircularProgressIndicator()));
                            }
                          } else {
                            l.add(Row(
                              children: [
                                const Flexible(
                                  fit: FlexFit.tight,
                                  child: Text(
                                    "Chapters:",
                                    style: TextStyle(fontSize: 20),
                                    softWrap: true,
                                  ),
                                ),
                                ElevatedButton(
                                    onPressed: () async {
                                      await appDB.addSeriesIfNeeded(
                                          widget.site, widget.id, s.name, s.description, s.thumbnail, thumbnailWidth, thumbnailHeight);
                                      await appDB.updateLastReadDate(widget.site, widget.id);
                                      List<int> indexes = [];
                                      List<String> ids = [];
                                      List<String> names = [];
                                      for (var (i, c) in chapters!.indexed) {
                                        indexes.add(i);
                                        ids.add(c.id);
                                        names.add(c.name);
                                      }
                                      // The index is stored as `position`; identity stays the chapterID.
                                      appDB.queueChapters(widget.site, widget.id, names, indexes, ids);
                                      startDownloadManager();
                                    },
                                    child: Text("Download all")),
                              ],
                            ));
                            l.add(Divider());
                            for (var c in chapters!) {
                              l.add(Row(
                                children: [
                                  Flexible(fit: FlexFit.tight, child: Text(c.name, softWrap: true)),
                                  StreamBuilder(
                                      stream: appDB.chapterStatusByID(widget.site, widget.id, c.id),
                                      builder: (_, d) {
                                        if (d.hasData) {
                                          var status = d.data!;
                                          switch (status) {
                                            case ChapterStatus.downloaded:
                                              return ElevatedButton(
                                                  onPressed: () {
                                                    appDB.deleteChapterByID(widget.site, widget.id, c.id);
                                                  },
                                                  child: Text("Delete"));
                                            case ChapterStatus.queued:
                                              return ElevatedButton(
                                                  onPressed: () {
                                                    appDB.dequeueChapterByID(widget.site, widget.id, c.id);
                                                  },
                                                  child: Text("Unqueue"));
                                            case ChapterStatus.online:
                                              return ElevatedButton(
                                                  onPressed: () async {
                                                    await appDB.addSeriesIfNeeded(
                                                        widget.site, widget.id, s.name, s.description, s.thumbnail, thumbnailWidth, thumbnailHeight);
                                                    await appDB.updateLastReadDate(widget.site, widget.id);
                                                    // `i` here is the live TOC position, not an identity.
                                                    appDB.queueChapter(widget.site, c.name, widget.id, chapters!.indexOf(c), c.id);
                                                    startDownloadManager();
                                                  },
                                                  child: Text("Download"));
                                          }
                                        }
                                        return SizedBox.shrink();
                                      })
                                ],
                              ));
                              l.add(Divider());
                            }
                          }
                          if (inLibrary) {
                            l.add(StreamBuilder<List<Chapter>>(
                              stream: appDB.missingUpstreamChapters(
                                  SeriesData(site: widget.site, id: widget.id)),
                              builder: (_, d) {
                                var removed = d.data ?? const <Chapter>[];
                                if (removed.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Divider(),
                                      Text("Removed by author (kept offline)",
                                          style: TextStyle(fontSize: 20)),
                                      Divider(),
                                      ...removed.map((c) => Row(
                                            children: [
                                              Flexible(
                                                  fit: FlexFit.tight,
                                                  child: Text(c.name, softWrap: true)),
                                              Padding(
                                                padding: const EdgeInsets.only(right: 8.0),
                                                child: ElevatedButton(
                                                    onPressed: () =>
                                                        router.push("/read", extra: c.toJson()),
                                                    child: Text("Read")),
                                              ),
                                              ElevatedButton(
                                                  onPressed: () => appDB
                                                      .deleteChapterByID(widget.site, widget.id, c.chapterID),
                                                  child: Text("Delete")),
                                            ],
                                          )),
                                    ]);
                              },
                            ));
                          }
                          return [SliverList.list(children: l)];
                        })(),
                      ],
                    ));
              } else {
                return const Center(child: CircularProgressIndicator());
              }
            }),
      ),
    );
  }
}

