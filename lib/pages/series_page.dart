import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/epub/export_service.dart';
import 'package:story_reader/main.dart';
import 'package:story_reader/pages/chapter_display.dart';
import 'package:story_reader/prefs.dart';
import 'package:story_reader/series_data.dart';

class SeriesPage extends StatefulWidget {
  final Series series;

  const SeriesPage(this.series, {super.key});

  @override
  State<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends State<SeriesPage> {
  Future? inProgress;

  @override
  void initState() {
    super.initState();
    appDB.updateLastReadDate(widget.series.site, widget.series.id);
  }

  @override
  Widget build(BuildContext context) {
    var size = MediaQuery.sizeOf(context);
    const int breakpoint = 500;
    return Scaffold(
      body: SafeArea(
        child: StreamBuilder(
            stream: appDB.chaptersFor(SeriesData(site: widget.series.site, id: widget.series.id)),
            builder: (c, d) {
              if (!d.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              var chapters = d.data!;
              return CustomScrollView(
                restorationId: "SeriesScroll",
                slivers: [
                  // TODO change layout on smaller screens
                  SliverAppBar(
                    pinned: true,
                    title: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                            flex: 3,
                            child: Text(widget.series.name, softWrap: true, style: const TextStyle(fontSize: 20))),
                        if (size.width >= breakpoint) _deleteButton(c),
                        if (chapters.isNotEmpty && size.width >= breakpoint) _continueButton(chapters),
                        if (size.width >= breakpoint) _netButton(),
                        if (size.width >= breakpoint) _exportButton(),
                      ],
                    ),
                    actions: [
                      if (size.width < breakpoint)
                        if (inProgress == null)
                          PopupMenuButton(
                            itemBuilder: (c) {
                              return [
                                const PopupMenuItem(
                                  child: Text("Delete"),
                                  value: 0,
                                ),
                                const PopupMenuItem(
                                  child: Text("Online Version"),
                                  value: 1,
                                ),
                                if (chapters.isNotEmpty)
                                  const PopupMenuItem(
                                    child: Text("Continue"),
                                    value: 2,
                                  ),
                                const PopupMenuItem(
                                  child: Text("Export EPUB"),
                                  value: 3,
                                )
                              ];
                            },
                            onSelected: (v) {
                              if (v == 0) {
                                _showDeleteDialog(context);
                              }
                              if (v == 1) {
                                _doNet();
                              }
                              if (v == 2 && chapters.isNotEmpty) {
                                _doContinue(chapters);
                              }
                              if (v == 3) {
                                _showExportDialog();
                              }
                            },
                          )
                        else
                          const CircularProgressIndicator()
                    ],
                  ),
                  SliverList.separated(
                    itemBuilder: (c, i) {
                      var c = chapters[i];
                      // Chapter identity and delete target is the site
                      // chapterID; the legacy `number` slot is a meaningless
                      // index once chapters are deleted upstream — never show
                      // or key on it.
                      String? badge = switch (c.upstreamState) {
                        ChapterUpstreamState.missingUpstream => "Removed by author",
                        ChapterUpstreamState.renamed => "Renamed upstream",
                        ChapterUpstreamState.upstream => null,
                      };
                      var label = Text(c.name, softWrap: true);
                      // Leading fixed-width book chapter number (never the
                      // legacy `number` slot / TOC index).
                      var shownNumber = displayChapterNumber(c.name, c.chapterNumber);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: Row(
                          children: [
                            if (shownNumber != null)
                              Opacity(opacity: c.isRead ? 0.5 : 1.0,
                                  child: ChapterNumberPrefix(shownNumber)),
                            Flexible(
                              fit: FlexFit.tight,
                              flex: 3,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 32.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Read chapters are dimmed.
                                    Opacity(opacity: c.isRead ? 0.5 : 1.0, child: label),
                                    if (badge != null)
                                      Text(badge,
                                          style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                                  ],
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(right: 32.0),
                              child: ElevatedButton(
                                  onPressed: () => router.push("/read", extra: c.toJson()),
                                  child: const Text("Read")),
                            ),
                            ElevatedButton(
                                onPressed: () =>
                                    appDB.deleteChapterByID(widget.series.site, widget.series.id, c.chapterID),
                                child: const Text("Delete")),
                            PopupMenuButton<String>(
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: "markReadUpTo",
                                  child: Text("Mark all read up to here"),
                                ),
                              ],
                              onSelected: (v) {
                                if (v == "markReadUpTo") {
                                  appDB.markReadUpTo(widget.series.site, widget.series.id, c.chapterID);
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                    separatorBuilder: (c, i) => const Divider(),
                    itemCount: chapters.length,
                  ),
                ],
              );
            }),
      ),
    );
  }

  Flexible _netButton() {
    return Flexible(
        flex: 1,
        child: ElevatedButton(
            onPressed: () => _doNet(),
            child: (inProgress == null)
                ? const Text("Online Version", softWrap: true)
                : const CircularProgressIndicator()));
  }

  Flexible _exportButton() {
    return Flexible(
        flex: 1,
        child: ElevatedButton(
            onPressed: _showExportDialog, child: const Text("Export EPUB", softWrap: true)));
  }

  /// Export dialog: chapter count (remembered in [Preferences]), whether to
  /// download missing chapters, whether to mark exported ones as read, and
  /// how many unread chapters there are.
  Future<void> _showExportDialog() async {
    var unreadCount = 0;
    try {
      unreadCount =
          (await appDB.nextUnreadChaptersForExport(widget.series.site, widget.series.id, 1000000)).length;
    } catch (_) {
      // The dialog still works with a zero count; the export reports errors.
    }
    if (!mounted) {
      return;
    }
    var count = Preferences.exportChapterCount.value.clamp(1, 10000);
    var fetchMissing = true;
    var markRead = true;
    var countError = false;
    final controller = TextEditingController(text: count.toString());
    final chosen = await showDialog<bool>(
        context: context,
        builder: (c) => StatefulBuilder(builder: (c, setDialogState) {
              return AlertDialog(
                title: const Text("Export EPUB"),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(unreadCount == 1
                          ? "1 unread chapter available."
                          : "$unreadCount unread chapters available."),
                      const SizedBox(height: 12),
                      TextField(
                        controller: controller,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: "Number of chapters",
                          errorText: countError ? "Enter a number from 1 to 10000" : null,
                        ),
                      ),
                      CheckboxListTile(
                        value: fetchMissing,
                        onChanged: (v) => setDialogState(() => fetchMissing = v ?? true),
                        title: const Text("Download missing chapters"),
                        contentPadding: EdgeInsets.zero,
                      ),
                      CheckboxListTile(
                        value: markRead,
                        onChanged: (v) => setDialogState(() => markRead = v ?? true),
                        title: const Text("Mark exported chapters as read"),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text("Cancel")),
                  TextButton(
                      onPressed: () {
                        final parsed = int.tryParse(controller.text.trim());
                        if (parsed == null || parsed < 1 || parsed > 10000) {
                          setDialogState(() => countError = true);
                          return;
                        }
                        count = parsed;
                        Navigator.of(c).pop(true);
                      },
                      child: const Text("Export")),
                ],
              );
            }));
    controller.dispose();
    if (chosen != true) {
      return;
    }
    Preferences.exportChapterCount.value = count;
    await _runExport(count: count, fetchMissing: fetchMissing, markRead: markRead);
  }

  /// Runs the export behind a progress dialog, then the SAF save sheet, and
  /// only marks the chapters as read after the file was actually saved.
  Future<void> _runExport({required int count, required bool fetchMissing, required bool markRead}) async {
    final progress = ValueNotifier<ExportProgress>(const ExportProgress(ExportPhase.refreshingToc));
    // ignore: unawaited_futures
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (c) => ValueListenableBuilder(
            valueListenable: progress,
            builder: (c, p, _) => AlertDialog(
                  content: Row(children: [
                    const SizedBox(
                        width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    const SizedBox(width: 16),
                    Expanded(child: Text(p.label)),
                  ]),
                )));
    try {
      final result = await exportNextUnread(appDB, widget.series.site, widget.series.id,
          limit: count,
          fetchMissing: fetchMissing,
          markAsRead: markRead,
          onProgress: (p) => progress.value = p);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(); // close the progress dialog
      String? savedPath;
      try {
        savedPath = await FilePicker.saveFile(
            dialogTitle: "Save EPUB", fileName: result.fileName, bytes: result.bytes);
      } catch (e) {
        _showExportSnack("Could not save the file: $e");
        return;
      }
      if (savedPath == null) {
        _showExportSnack("Save cancelled — nothing was marked as read.");
        return;
      }
      await result.markExportedChaptersRead(appDB, widget.series.site, widget.series.id);
      final skipped = result.skippedUnavailable.length;
      _showExportSnack("Exported ${result.exportedChapterIDs.length} chapters to ${result.fileName}"
          "${skipped > 0 ? " ($skipped unavailable)" : ""} — "
          "${result.imagesEmbedded} images embedded, ${result.imagesMissing} unavailable.");
    } catch (e) {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(); // close the progress dialog
      final message = e is ExportException ? e.message : "$e";
      _showExportSnack("Export failed: $message");
    } finally {
      progress.dispose();
    }
  }

  void _showExportSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 6),
    ));
  }

  void _doNet() {
    setState(() {
      inProgress ??= (() {
        var extra = <String, dynamic>{
          "id": widget.series.id,
          "site": widget.series.site.index,
          "name": widget.series.name,
        };
        router.push("/seriesNet", extra: extra);
        setState(() {
          inProgress = null;
        });
      })();
    });
  }

  Flexible _continueButton(List<Chapter> chapters) {
    return Flexible(
        child: ElevatedButton(
      onPressed: () => _doContinue(chapters),
      child: const Text("Continue"),
    ));
  }

  /// Continue: the stable last-read chapter (by chapterID), falling back to
  /// the first unread chapter, then the first chapter. The legacy numeric
  /// `lastRead` slot lookup is gone — it threw StateError once the slot no
  /// longer matched any downloaded chapter.
  Future<Object?> _doContinue(List<Chapter> chapters) async {
    var target = await appDB.lastReadChapter(widget.series.site, widget.series.id) ??
        chapters.firstWhereOrNull((c) => !c.isRead) ??
        chapters.firstOrNull;
    if (target == null) {
      return null;
    }
    return router.push("/read", extra: target.toJson());
  }

  Flexible _deleteButton(BuildContext c) {
    return Flexible(
        flex: 1,
        child: ElevatedButton(onPressed: () => _showDeleteDialog(c), child: const Text("Delete", softWrap: true)));
  }

  Future<dynamic> _showDeleteDialog(BuildContext c) async {
    var size = (await appDB.seriesSize(widget.series.site, widget.series.id)).toDouble() / 1000000.0;
    return showDialog(
        builder: (c) => FractionallySizedBox(
            heightFactor: 0.5,
            widthFactor: 0.5,
            child: Card(
                child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: IntrinsicHeight(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(bottom: 32.0),
                      child: Text("Really delete this series? It currently uses ${size.toStringAsFixed(2)}MB of storage."),
                    ),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      ElevatedButton(onPressed: () => router.pop(), child: const Text("No")),
                      ElevatedButton(
                          onPressed: () {
                            appDB.deleteSeries(widget.series);
                            appDB.vacuum();
                            router.pop();
                            router.pop();
                          },
                          child: const Text("Yes")),
                    ]),
                  ],
                ),
              ),
            ))),
        context: c);
  }
}
