import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:html/parser.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:story_reader/chapter_number.dart';
import 'package:story_reader/rich_text_tree.dart';
import 'package:story_reader/series_data.dart';

part 'db.g.dart';

enum Site {
  scribbleHub,
  royalRoad;
  
  /// A string representation of a Site.
  @override
  String toString() => switch (this) {
    Site.scribbleHub => "ScribbleHub",
    Site.royalRoad => "RoyalRoad",
  };
}



@DataClassName("Series")
class SeriesTable extends Table {
  IntColumn get site => intEnum<Site>()();

  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get description => text()();

  BlobColumn get thumbnail => blob().nullable()();

  IntColumn get lastRead => integer().nullable()();

  /// Stable identity of the last-read chapter (its site chapter id). Takes
  /// priority over [lastRead] when set; [lastRead] is kept for the transition.
  TextColumn get lastReadChapterID => text().nullable()();
  DateTimeColumn get lastReadDate => dateTime().nullable()();
  
  IntColumn get thumbnailWidth => integer().nullable()();
  IntColumn get thumbnailHeight => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id, site};

  @override
  String? get tableName => "series";
}

/// Relationship of a stored chapter to the live upstream table of contents.
enum ChapterUpstreamState {
  /// Present in the live TOC.
  upstream,

  /// The author removed it from the TOC; content and scroll position are kept.
  missingUpstream,

  /// Still published, but the upstream title no longer matches [Chapters.name].
  renamed,
}

/// Sentinel for `chapters.position` meaning "not in the live TOC" (removed
/// upstream or never reconciled). This is Int64.MAX_VALUE: ordering by
/// position ASC puts such rows after every live chapter.
const int kNoPosition = 9223372036854775807;

class Chapters extends Table {
  IntColumn get site => intEnum<Site>().references(SeriesTable, #site)();
  TextColumn get id => text().references(SeriesTable, #id)();

  /// Legacy 0-based TOC index at download time; part of the primary key so it
  /// is never rewritten once a chapter exists. Use [position] for ordering.
  IntColumn get number => integer()();

  TextColumn get chapterID => text()();
  TextColumn get name => text()();
  BlobColumn get content => blob().nullable()();
  IntColumn get scrollPosition => integer().nullable()();
  BoolColumn get queued => boolean()();

  /// Current index in the live table of contents; [kNoPosition] when the
  /// chapter is not in the live TOC (removed upstream or never reconciled).
  IntColumn get position => integer().withDefault(Constant(kNoPosition))();

  /// The book's own chapter number parsed from the title, null when absent.
  IntColumn get chapterNumber => integer().nullable()();

  IntColumn get upstreamState => intEnum<ChapterUpstreamState>().withDefault(const Constant(0))();

  BoolColumn get isRead => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>>? get primaryKey => {site, id, number};
}

class ChapterImages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get url => text().unique()();
  BlobColumn get image => blob().nullable()();
  BoolColumn get shouldDownload => boolean().withDefault(Constant(true))();
  
  @override
  String? get tableName => "images";
}

Future<File> _dbFile() async {
  final folder = await getApplicationSupportDirectory();
  return File(path.join(folder.path, "db.sqlite"));
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final file = await _dbFile();
    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    }
    
    final cacheBase = (await getTemporaryDirectory()).path;
    sqlite3.tempDirectory = cacheBase;
    
    return NativeDatabase.createInBackground(file);
  });
}

enum ChapterStatus {
  downloaded,
  queued,
  online,
}

final _gzip = GZipCodec(level: 9, raw: true, gzip: false);
const _utf8 = Utf8Codec();

@DriftDatabase(tables: [SeriesTable, Chapters, ChapterImages])
class AppDB extends _$AppDB {
  AppDB([QueryExecutor? executor]) : super(executor ?? _open());
  
  RichTextDocument? chapterContents(Chapter c) {
    if (c.content != null) {
      var data = _utf8.decoder.convert(_gzip.decoder.convert(c.content!));
      //File("chapter-dump.json").writeAsString(JsonEncoder.withIndent("  ").convert(jsonDecode(data)));
      return RichTextDocument.fromJson(jsonDecode(data));
    }
    return null;
  }
  
  Future<void> dequeueImage(int id) {
    return customUpdate("UPDATE images SET should_download = false WHERE id = ?", updateKind: UpdateKind.update, updates: {chapterImages}, variables: [
      Variable.withInt(id)
    ]);
  }

  Future<void> queueImage(int id) {
    return customUpdate("UPDATE images SET should_download = true WHERE id = ?", updateKind: UpdateKind.update,
        updates: {chapterImages},
        variables: [
          Variable.withInt(id)
        ]);
  }
  
  Stream<List<ChapterImage>> queuedImagesStream() {
    return (select(chapterImages)..where((i) => i.image.isNull() & i.shouldDownload)).watch();
  }
  
  Future<List<ChapterImage>> queuedImages() {
    return (select(chapterImages)..where((i) => i.image.isNull() & i.shouldDownload)).get();
  }
  
  Future<Uint8List?> chapterImage(int id) {
    return (select(chapterImages)..where((i) => i.id.equals(id))).getSingleOrNull().then((v) => v?.image);
  }

  Stream<Uint8List?> chapterImageWatch(int id) {
    return (select(chapterImages)
      ..where((i) => i.id.equals(id))).watchSingleOrNull().map((v) => v?.image).distinct((c, n) {
        if (c == n) {
          return true;
        }
        if (c == null || n == null) {
          return false;
        }
        return c.equals(n);
    });
  }
  
  Future<List<Series>> series() async {
    return select(seriesTable).get();
  }
  
  Future<int> dbSize() async {
    return (await _dbFile()).length();
  }
  
  Future<int> addImage(String url) {
    return transaction(() async {
      var i = await (select(chapterImages)..where((i) => i.url.equals(url))).getSingleOrNull();
      if (i != null) {
        return i.id;
      }
      await into(chapterImages).insert(ChapterImagesCompanion.insert(url: url, shouldDownload: Value(true)));
      return (await (select(chapterImages)..where((i) => i.url.equals(url))).getSingle()).id;
    });
  }
  
  Future<void> setImageData(int id, Uint8List image) {
    return (update(chapterImages)..where((i) => i.id.equals(id))).write(ChapterImagesCompanion(image: Value(image)));
  }
  
  Future<int> imageSize() {
    return Future.wait([
      select(seriesTable).map((s) => s.thumbnail).get().then((l) => l.whereNotNull().map((i) => i.length).sum),
      select(chapterImages).map((s) => s.image).get().then((l) => l.whereNotNull().map((i) => i.length).sum)
    ]).then((l) => l.sum);
  }

  Future<int> seriesSize(Site site, String id) {
    return transaction(() async {
      var s = await (select(seriesTable)..where((s) => s.id.equals(id) & s.site.equals(site.index))).getSingle();
      var cs = await (select(chapters)
        ..where((s) => s.id.equals(id) & s.site.equals(site.index))).get();
      return (s.thumbnail?.length ?? 0) + s.name.length + s.description.length + cs.map((c) => (c.name.length ?? 0) + (c.content?.length ?? 0)).sum;
    });
  }
  
  Future<void> deleteImages() {
    return transaction(() async {
      await customUpdate("UPDATE series SET thumbnail = NULL", updates: {seriesTable}, updateKind: UpdateKind.update);
      await customUpdate("UPDATE images SET image = NULL, should_download = false", updateKind: UpdateKind.update, updates: {chapterImages});
    });
  }
  
  Future<void> vacuum() {
    return customStatement("VACUUM");
  }

  Future<void> deleteDB() {
    return transaction(() async {
      await delete(seriesTable).go();
      await delete(chapters).go();
      await delete(chapterImages).go();
    });
  }
  
  Future<void> replaceDB(List<Series> series, List<Chapter> chapters, List<ChapterImage> chapterImages) {
    return transaction(() async {
      await delete(seriesTable).go();
      await delete(this.chapters).go();
      await delete(this.chapterImages).go();
      await batch((batch) async {
        batch.insertAll(seriesTable, series);
        // insertOrReplace so a payload that still carries v10-era duplicate
        // chapterIDs collapses to one row instead of violating the unique index.
        batch.insertAll(this.chapters, chapters, mode: InsertMode.insertOrReplace);
        batch.insertAll(this.chapterImages, chapterImages);
      });
    });
  }
  
  
  Stream<ChapterStatus> chapterStatus(Site site, String id, int number) {
    // Call sites pass a live TOC index; match the reconciled `position` first
    // and fall back to the legacy `number` slot for never-reconciled rows.
    return (select(chapters)
          ..where((c) =>
              c.id.equals(id) & c.site.equals(site.index) & (c.position.equals(number) | c.number.equals(number))))
        .watch()
        .map((cl) {
      var c = cl.where((c) => c.position == number).firstOrNull ?? cl.where((c) => c.number == number).firstOrNull;
      if (c == null) {
        return ChapterStatus.online;
      }
      if (c.content != null) {
        return ChapterStatus.downloaded;
      }
      if (c.queued) {
        return ChapterStatus.queued;
      }
      return ChapterStatus.online;
    });
  }

  Future<void> addSeriesIfNeeded(Site site, String id, String name, String description, [Uint8List? thumbnail, int? thumbnailWidth, int? thimbnailHeight]) {
    var s = Series(site: site, id: id, name: name, description: description, thumbnail: thumbnail, thumbnailWidth: thumbnailWidth, thumbnailHeight: thimbnailHeight);
    return transaction(() async {
      var rc = await (select(seriesTable)
            ..whereSamePrimaryKey(s)
            ..limit(1))
          .get();
      if (rc.isEmpty) {
        await into(seriesTable).insert(s, mode: InsertMode.insert);
      }
    });
  }

  Future<void> deleteChapter(Site site, String id, int number) {
    return transaction(() async {
      var s = await (select(seriesTable)..where((s) => s.site.equals(site.index) & s.id.equals(id))).getSingleOrNull();
      var doomed = await (select(chapters)
            ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.number.equals(number)))
          .get();
      for (var c in doomed) {
        await (delete(chapters)..whereSamePrimaryKey(c)).go();
      }
      if (s != null) {
        if (s.lastRead == number) {
          await setLastRead(site, id, null);
        } else if (s.lastReadChapterID != null && doomed.any((c) => c.chapterID == s.lastReadChapterID)) {
          await setLastReadChapter(site, id, null);
        }
      }
    });
  }

  /// Canonical chapter ordering, used everywhere chapters are listed:
  /// live TOC position first, then the book's own chapter number, then name.
  List<OrderingTerm Function($ChaptersTable)> get canonicalChapterOrder => [
        (c) => OrderingTerm.asc(c.position),
        (c) => OrderingTerm.asc(c.chapterNumber),
        (c) => OrderingTerm.asc(c.name),
      ];

  SimpleSelectStatement<$ChaptersTable, Chapter> _queuedChapters() {
    return (select(chapters)
      ..where((c) => c.queued.equals(true))
      ..orderBy([
        (c) => OrderingTerm(expression: c.site),
        (c) => OrderingTerm(expression: c.id),
        ...canonicalChapterOrder,
      ]));
  }
  
  

  Future<List<Chapter>> queuedChapters() {
    return _queuedChapters().get();
  }

  Stream<List<Chapter>> queuedChaptersStream() {
    return _queuedChapters().watch();
  }

  Future<void> setThumbnail(Site site, String id, Uint8List thumbnail, int width, int height) {
    return customUpdate(
      "UPDATE series SET thumbnail = ?, thumbnail_width = ?, thumbnail_height = ? WHERE site = ? AND id = ?",
      variables: [
        Variable.withBlob(thumbnail),
        Variable.withInt(width),
        Variable.withInt(height),
        Variable.withInt(site.index),
        Variable.withString(id),
      ],
      updates: {seriesTable},
      updateKind: UpdateKind.update,
    );
  }

  /// Sets the legacy numeric marker and, when a row can be resolved for it,
  /// the stable [Series.lastReadChapterID] that takes priority over it.
  Future<void> setLastRead(Site site, String id, int? last) {
    return transaction(() async {
      String? chapterID;
      if (last != null) {
        var rows = await (select(chapters)
              ..where((c) =>
                  c.site.equals(site.index) & c.id.equals(id) & (c.position.equals(last) | c.number.equals(last))))
            .get();
        var row = rows.where((c) => c.position == last).firstOrNull ??
            rows.where((c) => c.number == last).firstOrNull;
        if (row != null && row.chapterID.isNotEmpty) {
          chapterID = row.chapterID;
        }
      }
      await customUpdate(
        "UPDATE series SET last_read = ?, last_read_chapter_i_d = ? WHERE site = ? AND id = ?",
        variables: [
          Variable(last),
          Variable<String>(chapterID),
          Variable.withInt(site.index),
          Variable.withString(id),
        ],
        updates: {seriesTable},
        updateKind: UpdateKind.update,
      );
    });
  }

  /// Sets the stable last-read marker by site chapter id. Takes priority over
  /// the legacy numeric [setLastRead] marker.
  Future<void> setLastReadChapter(Site site, String id, String? chapterID) {
    return customUpdate(
      "UPDATE series SET last_read_chapter_i_d = ? WHERE site = ? AND id = ?",
      variables: [
        Variable<String>(chapterID),
        Variable.withInt(site.index),
        Variable.withString(id),
      ],
      updates: {seriesTable},
      updateKind: UpdateKind.update,
    );
  }

  /// Resolves the last-read chapter: `lastReadChapterID` wins when set and a
  /// matching row exists, otherwise the legacy `lastRead` numeric marker.
  Future<Chapter?> lastReadChapter(Site site, String id) {
    return transaction(() async {
      var s = await (select(seriesTable)..where((s) => s.site.equals(site.index) & s.id.equals(id))).getSingleOrNull();
      if (s == null) {
        return null;
      }
      if (s.lastReadChapterID != null) {
        var byId = await (select(chapters)
              ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.chapterID.equals(s.lastReadChapterID!)))
            .get();
        var row = byId.firstOrNull;
        if (row != null) {
          return row;
        }
      }
      if (s.lastRead != null) {
        var rows = await (select(chapters)
              ..where((c) =>
                  c.site.equals(site.index) & c.id.equals(id) & (c.position.equals(s.lastRead!) | c.number.equals(s.lastRead!))))
            .get();
        return rows.where((c) => c.position == s.lastRead).firstOrNull ??
            rows.where((c) => c.number == s.lastRead).firstOrNull;
      }
      return null;
    });
  }
  
  Future<void> updateLastReadDate(Site site, String id) {
    return customUpdate(
      "UPDATE series SET last_read_date = ? WHERE site = ? AND id = ?",
      variables: [
        Variable.withDateTime(DateTime.timestamp()),
        Variable.withInt(site.index),
        Variable.withString(id),
      ],
      updates: {seriesTable},
      updateKind: UpdateKind.update,
    );
  }

  Future<void> setScrollPosition(Site site, String id, int number, int? position) {
    return customUpdate(
      "UPDATE chapters SET scroll_position = ? WHERE site = ? AND id = ? AND number = ?",
      variables: [
        Variable(position),
        Variable.withInt(site.index),
        Variable.withString(id),
        Variable.withInt(number),
      ],
      updates: {chapters},
      updateKind: UpdateKind.update,
    );
  }

  Future<void> saveChapter(Site site, String id, int number, String chapterID, RichTextDocument contents, String name) {
    return transaction(() async {
      var imageIDS = await Future.wait(contents.imageSources.map((url) => addImage(url.toString())).toList());
      //print(imageIDS);
      contents.rewriteImageIndices(imageIDS);
      var content = Uint8List.fromList(_gzip.encoder.convert(_utf8.encoder.convert(jsonEncode(contents.toJson()))));
      // The row identified by the stable chapterID is the save target; the
      // legacy (site, id, number) slot is only a fallback for pre-M1 callers.
      var byID = await (select(chapters)
            ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.chapterID.equals(chapterID)))
          .get();
      var target = byID.firstOrNull;
      if (target == null) {
        var byNumber = await (select(chapters)
              ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.number.equals(number)))
            .get();
        target = byNumber.firstOrNull;
      }
      // Only store content into a row that is actually queued.
      if (target != null && target.queued) {
        await (update(chapters)..whereSamePrimaryKey(target)).write(ChaptersCompanion(
              chapterID: Value(chapterID),
              name: Value(name),
              content: Value(content),
              chapterNumber: Value(parseChapterNumber(name)),
              queued: const Value(false),
            ));
      }
    });
  }

  Future<void> queueChapter(Site site, String name, String id, int number, String chapterID) {
    return transaction(() async {
      var rows = await (select(chapters)
            ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.chapterID.equals(chapterID)))
          .get();
      var row = rows.firstOrNull;
      if (row == null) {
        var existing = await (select(chapters)..where((c) => c.site.equals(site.index) & c.id.equals(id))).get();
        var used = existing.map((c) => c.number).toSet();
        await into(chapters).insert(Chapter(
            site: site,
            name: name,
            id: id,
            number: freeNumber(number, used),
            queued: true,
            chapterID: chapterID,
            position: number,
            chapterNumber: parseChapterNumber(name),
            upstreamState: ChapterUpstreamState.upstream,
            isRead: false));
      } else if (row.content == null) {
        await (update(chapters)..whereSamePrimaryKey(row)).write(ChaptersCompanion(
              name: Value(name),
              queued: const Value(true),
              position: Value(number),
              chapterNumber: Value(parseChapterNumber(name)),
              upstreamState: const Value(ChapterUpstreamState.upstream),
            ));
      }
    });
  }

  Future<void> queueChapters(Site site, String id, List<String> names, List<int> numbers, List<String> chapterIDs, [bool queue = true]) {
    return transaction(() async {
      var rc = await (select(chapters)
            ..where((c) => c.site.equals(site.index) & c.id.equals(id)))
          .get();
      var byID = <String, Chapter>{ for (var c in rc) c.chapterID: c };
      var used = rc.map((c) => c.number).toSet();
      for (var (i, cid) in chapterIDs.indexed) {
        var row = byID[cid];
        if (row == null) {
          var fresh = Chapter(
              site: site,
              name: names[i],
              id: id,
              number: freeNumber(numbers[i], used),
              chapterID: cid,
              queued: queue,
              position: numbers[i],
              chapterNumber: parseChapterNumber(names[i]),
              upstreamState: ChapterUpstreamState.upstream,
              isRead: false);
          byID[cid] = fresh;
          rc.add(fresh);
        } else {
          if (!queue || row.content == null) {
            var updated = row.copyWith(
              queued: queue,
              position: numbers[i],
              chapterNumber: Value(parseChapterNumber(names[i])),
              upstreamState: ChapterUpstreamState.upstream,
              name: row.content == null ? names[i] : row.name,
            );
            byID[cid] = updated;
            rc[rc.indexOf(row)] = updated;
          }
        }
      }
      await batch((batch) {
        batch.insertAll(chapters, rc, mode: InsertMode.insertOrReplace);
      });
    });
  }

  Future<void> dequeueChapter(Site site, String id, int number) {
    return transaction(() async {
      var rows = await (select(chapters)
            ..where((c) =>
                c.site.equals(site.index) & c.id.equals(id) & (c.position.equals(number) | c.number.equals(number))))
          .get();
      var row = rows.where((c) => c.position == number).firstOrNull ??
          rows.where((c) => c.number == number).firstOrNull;
      if (row != null && row.content == null) {
        await (update(chapters)..whereSamePrimaryKey(row)).write(const ChaptersCompanion(queued: Value(false)));
      }
    });
  }

  Future<void> dequeueAll() async {
    await await customUpdate("UPDATE images SET should_download = false", updateKind: UpdateKind.update,
        updates: {chapterImages});
    await customUpdate("UPDATE chapters SET queued = false", updateKind: UpdateKind.update, updates: {chapters});
  }

  SimpleSelectStatement<$SeriesTableTable, Series> _downloadedSeries() {
    return select(seriesTable)
      ..orderBy([(s) => OrderingTerm(expression: s.name)]);
  }

  Future<void> deleteSeries(Series s) {
    return transaction(() async {
      await (delete(seriesTable)..whereSamePrimaryKey(s)).go();
      await (delete(chapters)..where((c) => c.site.equals(s.site.index) & c.id.equals(s.id))).go();
    });
  }

  Stream<List<Series>> downloadedSeries() {
    return _downloadedSeries().watch().distinct((a, b) {
      if (a.length != b.length) {
        return false;
      }
      for (int i = 0; i < a.length; i++) {
        if (a[i].site != b[i].site || a[i].id != b[i].id) {
          return false;
        }
      }
      return true;
    });
  }

  Future<List<Series>> downloadedSeriesFuture() {
    return _downloadedSeries().get();
  }

  Stream<List<Chapter>> chaptersFor(SeriesData s) {
    return _chaptersFor(s).watch();
  }

  Future<List<Chapter>> chaptersForFuture(SeriesData s) {
    return _chaptersFor(s).get();
  }

  SimpleSelectStatement<$ChaptersTable, Chapter> _chaptersFor(SeriesData s) {
    return select(chapters)
      ..where((c) => c.id.equals(s.id) & c.site.equals(s.site.index) & c.content.isNotNull())
      ..orderBy(canonicalChapterOrder);
  }

  /// Picks a free legacy `number` slot for a fresh row: [preferred] when
  /// unused, otherwise the next unused slot above it. `number` is part of the
  /// primary key, so a live TOC index can collide with a retained row whose
  /// chapter was deleted upstream.
  static int freeNumber(int preferred, Set<int> used) {
    var n = preferred;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  /// The downloaded-but-unread, still-published chapters of a series in
  /// canonical order — the selection used for EPUB export batches.
  Future<List<Chapter>> nextUnreadChapters(Site site, String id, int limit) {
    return (select(chapters)
          ..where((c) =>
              c.site.equals(site.index) &
              c.id.equals(id) &
              c.content.isNotNull() &
              c.isRead.equals(false) &
              c.upstreamState.isNotInValues([ChapterUpstreamState.missingUpstream]))
          ..orderBy(canonicalChapterOrder)
          ..limit(limit))
        .get();
  }

  Future<void> setRead(Site site, String id, String chapterID, bool read) {
    return (update(chapters)
          ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.chapterID.equals(chapterID)))
        .write(ChaptersCompanion(isRead: Value(read)));
  }

  /// Repairs the v10-era corruption where one `chapterID` occupies several
  /// `number` slots: keeps exactly one row per `(site, id, chapterID)` — the
  /// one with content (highest `number` among content-bearing rows, so its
  /// name+content+scrollPosition stay together), else the highest `number`.
  /// Returns the number of rows deleted. Rows with an empty `chapterID` have
  /// no stable identity and are left alone.
  Future<int> deduplicateChapters({Site? site, String? id}) async {
    return transaction(() async {
      var query = select(chapters);
      if (site != null) {
        query.where((c) => c.site.equals(site.index));
      }
      if (id != null) {
        query.where((c) => c.id.equals(id));
      }
      var all = await query.get();
      var groups = groupBy(all, (Chapter c) => (c.site, c.id, c.chapterID));
      var doomed = <Chapter>[];
      for (var group in groups.entries) {
        if (group.key.$3.isEmpty || group.value.length < 2) {
          continue;
        }
        var rows = group.value.toList()
          ..sort((a, b) {
            var ca = a.content != null ? 1 : 0;
            var cb = b.content != null ? 1 : 0;
            if (ca != cb) {
              return cb.compareTo(ca); // content-bearing rows win
            }
            return b.number.compareTo(a.number); // newest write wins
          });
        doomed.addAll(rows.skip(1));
      }
      for (var c in doomed) {
        await (delete(chapters)..whereSamePrimaryKey(c)).go();
      }
      return doomed.length;
    });
  }

  /// Aligns stored chapters with the live upstream table of contents.
  ///
  /// * Live TOC entries are upserted in TOC order (`position = index`,
  ///   `chapterNumber = parseChapterNumber(name)`); a name mismatch marks the
  ///   row `renamed` but **never touches its content**; a previously missing
  ///   chapter that reappears returns to `upstream`.
  /// * Local rows whose `chapterID` is absent from [toc] become
  ///   `missingUpstream` with `position = kNoPosition` and `queued = false`,
  ///   **keeping** their content, scroll position and name — so a deleted
  ///   chapter sorts after all live ones instead of being lost.
  ///
  /// The `lastReadChapterID` marker is a stable id and needs no adjustment.
  Future<void> reconcileChapters(Site site, String seriesId, List<ChapterData> toc) {
    return transaction(() async {
      var existing = await (select(chapters)
            ..where((c) => c.site.equals(site.index) & c.id.equals(seriesId)))
          .get();
      var byID = <String, Chapter>{ for (var c in existing) c.chapterID: c };
      var usedNumbers = existing.map((c) => c.number).toSet();

      for (var (i, entry) in toc.indexed) {
        var parsed = parseChapterNumber(entry.name);
        var row = byID[entry.id];
        if (row == null) {
          await into(chapters).insert(Chapter(
              site: site,
              id: seriesId,
              number: freeNumber(i, usedNumbers),
              chapterID: entry.id,
              name: entry.name,
              queued: false,
              position: i,
              chapterNumber: parsed,
              upstreamState: ChapterUpstreamState.upstream,
              isRead: false));
          continue;
        }
        ChapterUpstreamState state;
        if (row.upstreamState == ChapterUpstreamState.missingUpstream) {
          // Re-uploaded by the author: back to normal (re-download happens
          // through the normal queue if its content is absent).
          state = ChapterUpstreamState.upstream;
        } else {
          state = row.name != entry.name ? ChapterUpstreamState.renamed : ChapterUpstreamState.upstream;
        }
        // Name and content are deliberately untouched: `name` stays the local
        // copy so the renamed state remains detectable until a re-download.
        await (update(chapters)..whereSamePrimaryKey(row)).write(ChaptersCompanion(
              position: Value(i),
              chapterNumber: Value(parsed),
              upstreamState: Value(state),
            ));
      }

      var tocIDs = toc.map((t) => t.id).toSet();
      for (var row in existing) {
        if (tocIDs.contains(row.chapterID)) {
          continue;
        }
        await (update(chapters)..whereSamePrimaryKey(row)).write(const ChaptersCompanion(
              position: Value(kNoPosition),
              upstreamState: Value(ChapterUpstreamState.missingUpstream),
              queued: Value(false),
            ));
      }
    });
  }

  @override
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(onCreate: (m) async {
      await m.createAll();
      await customStatement(_uniqueChapterIndexStatement);
    }, onUpgrade: (Migrator m, int from, int to) async {
      await transaction(() async {
        if (from < 2) {
          await m.addColumn(seriesTable, seriesTable.lastReadDate);
        }
        if (from < 3) {
          await m.addColumn(seriesTable, seriesTable.thumbnailWidth);
          await m.addColumn(seriesTable, seriesTable.thumbnailHeight);
        }
        if (from < 4) {
          await m.alterTable(TableMigration(chapters, columnTransformer: {chapters.content: chapters.content.cast<Uint8List>()}));
          var cs = (await select(chapters).get()).map((c) {
            if (c.content != null) {
              var content = utf8.decode(c.content!);
              return c.copyWith(content: Value(Uint8List.fromList(_gzip.encode(_utf8.encode(content)))));
            }
            return c;
          }).toList();
          await batch((b) {
            b.replaceAll(chapters, cs);
          });
        }
      });
      if (from < 4) {
        await vacuum();
      }
      if (from < 5) {
        await m.createTable(chapterImages);
      }
      if (from < 7) {
        await m.addColumn(chapterImages, chapterImages.shouldDownload);
      }
      if (from == 6 || from == 7) {
        var cs = await Future.wait((await select(chapters).get()).map((c) async {
          if (c.content != null) {
            var content = _utf8.decode(_gzip.decode(c.content!));
            var rtd = RichTextDocument.fromJson(jsonDecode(content));
            rtd.addSpacing();
            return c.copyWith(content: Value(Uint8List.fromList(_gzip.encode(_utf8.encode(jsonEncode(rtd.toJson()))))));
          }
          return c;
        }).toList());
        await batch((b) {
          b.replaceAll(chapters, cs);
        });
      }
      if (from < 6) {
        var cs = await Future.wait((await select(chapters).get()).map((c) async {
          if (c.content != null) {
            var content = _utf8.decode(_gzip.decode(c.content!));
            var rtd = RichTextDocument.html(parseFragment(content).nodes);
            var imageIDS = await Future.wait(rtd.imageSources.map((url) => addImage(url.toString())).toList());
            rtd.rewriteImageIndices(imageIDS);
            return c.copyWith(content: Value(Uint8List.fromList(_gzip.encode(_utf8.encode(jsonEncode(rtd.toJson()))))));
          }
          return c;
        }).toList());
        await batch((b) {
          b.replaceAll(chapters, cs);
        });
      }
      if (from < 10) {
        var cs = await Future.wait((await select(chapters).get()).map((c) async {
          if (c.content != null) {
            var content = _utf8.decode(_gzip.decode(c.content!));
            var rtd = RichTextDocument.fromJson(jsonDecode(content));
            rtd.visit((e) {
              if (e is RichTextText) {
                e.content = e.content.trim();
              }
            });
            rtd.addSpacing();
            return c.copyWith(content: Value(Uint8List.fromList(_gzip.encode(_utf8.encode(jsonEncode(rtd.toJson()))))));
          }
          return c;
        }).toList());
        await batch((b) {
          b.replaceAll(chapters, cs);
        });
      }
      if (from < 11) {
        // M1 — stable chapter identity. All new columns are defaulted or
        // nullable, so no table rebuild is needed.
        await m.addColumn(chapters, chapters.position);
        await m.addColumn(chapters, chapters.chapterNumber);
        await m.addColumn(chapters, chapters.upstreamState);
        await m.addColumn(chapters, chapters.isRead);
        await m.addColumn(seriesTable, seriesTable.lastReadChapterID);

        // Repair v10 duplicate rows before the unique index can exist.
        await deduplicateChapters();

        // Best guess until the first reconcile: the legacy TOC index was the
        // position when the row was written.
        await customStatement("UPDATE chapters SET position = number");

        // Derive the book's own chapter number from the stored title.
        var renamed = (await select(chapters).get())
            .map((c) => c.copyWith(chapterNumber: Value(parseChapterNumber(c.name))))
            .where((c) => c.chapterNumber != null)
            .toList();
        await batch((b) {
          b.replaceAll(chapters, renamed);
        });

        // Promote lastRead to the stable chapterID when the slot is unique.
        for (var s in await select(seriesTable).get()) {
          var last = s.lastRead;
          if (last == null) {
            continue;
          }
          var rows = await (select(chapters)
                ..where((c) => c.site.equals(s.site.index) & c.id.equals(s.id) & c.number.equals(last)))
              .get();
          if (rows.length == 1 && rows.single.chapterID.isNotEmpty) {
            await (update(seriesTable)..whereSamePrimaryKey(s))
                .write(SeriesTableCompanion(lastReadChapterID: Value(rows.single.chapterID)));
          }
        }

        await customStatement(_uniqueChapterIndexStatement);
      }
    });
  }
}

/// Drift has no declarative multi-column unique index. Column names are the
/// drift-generated snake_case names (`chapterID` -> `chapter_i_d`).
const String _uniqueChapterIndexStatement =
    "CREATE UNIQUE INDEX IF NOT EXISTS chapters_chapter_key ON chapters (site, id, chapter_i_d)";
