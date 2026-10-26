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

/// Navigation rule for Previous/Next over a canonically-ordered chapter list.
///
/// Canonical order sorts retained-removed chapters (`missingUpstream`,
/// `position = kNoPosition`) *after* every live chapter, which is right for
/// listing but wrong mid-book: stepping forward through live chapters must
/// not suddenly jump into the retained section, and stepping back must not
/// fall out of it early. So navigation **skips `missingUpstream` rows unless
/// the current chapter itself is `missingUpstream`** — inside the retained
/// section you can page through it, leaving by the same neighbour a listing
/// implies. [chapterAfter]/[chapterBefore] return null at the ends.
Chapter? chapterAfter(List<Chapter> ordered, String chapterID) {
  var i = ordered.indexWhere((c) => c.chapterID == chapterID);
  if (i == -1) {
    return null;
  }
  var allowMissing = ordered[i].upstreamState == ChapterUpstreamState.missingUpstream;
  for (var j = i + 1; j < ordered.length; j++) {
    if (!allowMissing && ordered[j].upstreamState == ChapterUpstreamState.missingUpstream) {
      continue;
    }
    return ordered[j];
  }
  return null;
}

/// Inverse of [chapterAfter] (see its doc for the navigation rule).
Chapter? chapterBefore(List<Chapter> ordered, String chapterID) {
  var i = ordered.indexWhere((c) => c.chapterID == chapterID);
  if (i <= 0) {
    return null;
  }
  var allowMissing = ordered[i].upstreamState == ChapterUpstreamState.missingUpstream;
  for (var j = i - 1; j >= 0; j--) {
    if (!allowMissing && ordered[j].upstreamState == ChapterUpstreamState.missingUpstream) {
      continue;
    }
    return ordered[j];
  }
  return null;
}

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

  /// M3b: the sanitized source HTML the [content] RichText tree was parsed
  /// from (gzip, like [content]) — the input of `RichTextDocument.html` at
  /// download time (`#chp_raw` inner HTML on ScribbleHub, the processed
  /// `.chapter-content` on RoyalRoad). Null for chapters stored before
  /// schema v12; EPUB export then falls back to `richTextToXhtml(content)`.
  BlobColumn get rawHtml => blob().nullable()();

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

  // ---- Legacy (upstream schema 2..10) library import ----------------------
  // See repairLegacyChapters / promoteLastReadMarkers at the bottom of this
  // file for the shared repair logic. Nothing here changes the schema.

  /// Imports a full library payload exported by the **original upstream
  /// StoryReader** at DB schema [sourceSchema] (2..10) through the network
  /// share.
  ///
  /// Rather than hand-converting every historical row shape, the payload rows
  /// are inserted into a fresh in-memory database carrying the **exact
  /// upstream DDL of [sourceSchema]** ([upstreamSchemaDdl]) with
  /// `PRAGMA user_version = sourceSchema`, and [AppDB] is opened on top of it
  /// so **the real [migration] chain runs** (gzip conversion, HTML→RichText
  /// conversion, image registration, spacing/trim passes, the v11 identity
  /// repair and index, …) up to the current [schemaVersion]. The migrated
  /// rows are then read back and [replaceDB]'d into the live DB in one
  /// transaction. Returns per-repair counts including the source schema.
  Future<LegacyImportReport> importLegacyLibrary(
      Map<String, dynamic> payload, {required int sourceSchema}) async {
    var migrated = await migrateUpstreamPayload(payload, sourceSchema);
    await replaceDB(migrated.series, migrated.chapters, migrated.images);

    // The repair ran inside the temp DB's migration; recount its effects
    // from the payload input vs. the migrated output (same rules as
    // repairLegacyChapters: blank '' content-less rows are dropped, then one
    // row per (site, id, chapterID) survives).
    var rawChapters =
        (payload["chapters"] as List? ?? const []).cast<Map<String, dynamic>>();
    var droppedBlank = rawChapters
        .where((j) => (j["chapterID"] as String? ?? "").isEmpty && j["content"] == null)
        .length;
    var identified = rawChapters.length - droppedBlank;
    var kept = migrated.chapters.length;
    return LegacyImportReport(
      sourceSchema: sourceSchema,
      series: migrated.series.length,
      chapters: kept,
      chaptersWithContent: migrated.chapters.where((c) => c.content != null).length,
      droppedBlankRows: droppedBlank,
      dedupedRows: identified - kept,
      lastReadMarkersPromoted:
          migrated.series.where((s) => s.lastReadChapterID != null).length,
    );
  }

  /// Compatibility wrapper: import an upstream **schema 10** payload (the
  /// shape documented in the original 0.9.x share protocol).
  Future<LegacyImportReport> importLegacyV10Library(Map<String, dynamic> payload) =>
      importLegacyLibrary(payload, sourceSchema: 10);

  /// Builds a throwaway database with the exact upstream DDL for
  /// [sourceSchema], inserts the payload rows (drift `toJson()` shapes —
  /// see [_legacyBlob] / [_legacyDateTime]), and opens an [AppDB] on it so
  /// drift's migration chain upgrades it to the current [schemaVersion].
  /// Returns the migrated rows.
  Future<({List<Series> series, List<Chapter> chapters, List<ChapterImage> images})>
      migrateUpstreamPayload(Map<String, dynamic> payload, int sourceSchema) async {
    var ddl = upstreamSchemaDdl(sourceSchema);
    var raw = sqlite3.openInMemory();
    try {
      for (var stmt in ddl) {
        raw.execute(stmt);
      }
      raw.execute("PRAGMA user_version = $sourceSchema");

      for (var j in (payload["series"] as List? ?? const []).cast<Map<String, dynamic>>()) {
        raw.execute(_seriesInsertStatement(sourceSchema), _seriesInsertArgs(j, sourceSchema));
      }
      for (var j in (payload["chapters"] as List? ?? const []).cast<Map<String, dynamic>>()) {
        raw.execute(_chapterInsertStatement(sourceSchema), _chapterInsertArgs(j, sourceSchema));
      }
      if (sourceSchema >= 5) {
        for (var j in (payload["chapterImages"] as List? ?? const [])
            .cast<Map<String, dynamic>>()) {
          raw.execute(_imageInsertStatement(sourceSchema), _imageInsertArgs(j, sourceSchema));
        }
      }

      // Drift sees user_version = sourceSchema < schemaVersion and runs
      // onUpgrade(sourceSchema -> current) on first access.
      var migrated = AppDB(NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
      try {
        return (
          series: await migrated.select(migrated.seriesTable).get(),
          chapters: await migrated.select(migrated.chapters).get(),
          images: await migrated.select(migrated.chapterImages).get(),
        );
      } finally {
        await migrated.close();
      }
    } finally {
      raw.dispose();
    }
  }

  /// Whether [column] currently exists on [table] (guards every `addColumn`
  /// in [migration] against "duplicate column" when an earlier step created
  /// the table with the *current* definition).
  Future<bool> columnExists(String table, String column) async {
    var rows = await customSelect(
      "SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
      variables: [Variable.withString(table), Variable.withString(column)],
      readsFrom: {seriesTable, chapters, chapterImages},
    ).get();
    return rows.isNotEmpty;
  }

  /// Whether a table exists in the current database file.
  Future<bool> tableExists(String table) async {
    var rows = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(table)],
      readsFrom: {seriesTable, chapters, chapterImages},
    ).get();
    return rows.isNotEmpty;
  }
  // ---- end legacy import --------------------------------------------------

  
  
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

  Future<void> saveChapter(Site site, String id, int number, String chapterID, RichTextDocument contents, String name,
      {String? rawHtml}) {
    return transaction(() async {
      var imageIDS = await Future.wait(contents.imageSources.map((url) => addImage(url.toString())).toList());
      //print(imageIDS);
      contents.rewriteImageIndices(imageIDS);
      var content = Uint8List.fromList(_gzip.encoder.convert(_utf8.encoder.convert(jsonEncode(contents.toJson()))));
      var rawHtmlBlob = rawHtml == null
          ? null
          : Uint8List.fromList(_gzip.encoder.convert(_utf8.encoder.convert(rawHtml)));
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
              // Keep the pair atomic: a stored rawHtml must belong to the
              // stored content, so a save without rawHtml clears the column.
              rawHtml: Value(rawHtmlBlob),
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

  /// Whether a series row exists, i.e. the series is in the library. Only
  /// library series get `reconcileChapters` runs from the online view.
  Future<bool> hasSeries(Site site, String id) {
    return (select(seriesTable)..where((s) => s.site.equals(site.index) & s.id.equals(id))..limit(1))
        .get()
        .then((l) => l.isNotEmpty);
  }

  /// Status of the one row identified by the site chapter id. Identity is
  /// always the `chapterID` — never a TOC index — so a deleted-and-shifted
  /// chapter cannot re-point this status at different content.
  Stream<ChapterStatus> chapterStatusByID(Site site, String id, String chapterID) {
    return (select(chapters)
          ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.chapterID.equals(chapterID)))
        .watch()
        .map((cl) {
      var c = cl.firstOrNull;
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

  /// Retained chapters the author removed from the live TOC and whose content
  /// is stored locally, in canonical order — the "Removed by author (kept
  /// offline)" section of the online series view.
  Stream<List<Chapter>> missingUpstreamChapters(SeriesData s) {
    return (select(chapters)
          ..where((c) =>
              c.site.equals(s.site.index) &
              c.id.equals(s.id) &
              c.content.isNotNull() &
              c.upstreamState.equals(ChapterUpstreamState.missingUpstream.index))
          ..orderBy(canonicalChapterOrder))
        .watch();
  }

  /// Deletes the chapter identified by [chapterID] and clears the stable
  /// last-read marker when it pointed at this chapter.
  Future<void> deleteChapterByID(Site site, String id, String chapterID) {
    return transaction(() async {
      var s = await (select(seriesTable)..where((s) => s.site.equals(site.index) & s.id.equals(id))).getSingleOrNull();
      var doomed = await (select(chapters)
            ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.chapterID.equals(chapterID)))
          .get();
      for (var c in doomed) {
        await (delete(chapters)..whereSamePrimaryKey(c)).go();
      }
      if (s != null && s.lastReadChapterID == chapterID) {
        await setLastReadChapter(site, id, null);
      }
    });
  }

  /// Takes the download queue flag off the chapter identified by [chapterID]
  /// (only while it has no content — a downloaded chapter is not "queued").
  Future<void> dequeueChapterByID(Site site, String id, String chapterID) {
    return transaction(() async {
      var row = (await (select(chapters)
            ..where((c) => c.site.equals(site.index) & c.id.equals(id) & c.chapterID.equals(chapterID)))
          .get())
          .firstOrNull;
      if (row != null && row.content == null) {
        await (update(chapters)..whereSamePrimaryKey(row)).write(const ChaptersCompanion(queued: Value(false)));
      }
    });
  }

  /// Scroll position keyed by the stable chapter identity.
  Future<void> setScrollPositionByID(Site site, String id, String chapterID, int? position) {
    return customUpdate(
      "UPDATE chapters SET scroll_position = ? WHERE site = ? AND id = ? AND chapter_i_d = ?",
      variables: [
        Variable(position),
        Variable.withInt(site.index),
        Variable.withString(id),
        Variable.withString(chapterID),
      ],
      updates: {chapters},
      updateKind: UpdateKind.update,
    );
  }

  /// Marks [chapterID] and every chapter at or before it in canonical order
  /// as read — the "Mark all read up to here" action feeding the EPUB export
  /// of the next unread chapters.
  Future<void> markReadUpTo(Site site, String id, String chapterID) {
    return transaction(() async {
      var all = await (select(chapters)
            ..where((c) => c.site.equals(site.index) & c.id.equals(id))
            ..orderBy(canonicalChapterOrder))
          .get();
      var idx = all.indexWhere((c) => c.chapterID == chapterID);
      if (idx == -1) {
        return;
      }
      for (var c in all.take(idx + 1)) {
        if (!c.isRead) {
          await (update(chapters)..whereSamePrimaryKey(c)).write(const ChaptersCompanion(isRead: Value(true)));
        }
      }
    });
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

  // ---- M3b EPUB export support -------------------------------------------
  // (Self-contained block added with schema v12; keeps merges with parallel
  // db.dart work simple.)

  /// The stored source HTML of a chapter (see [Chapters.rawHtml]), or null
  /// for chapters stored before schema v12.
  String? chapterRawHtml(Chapter c) {
    if (c.rawHtml != null) {
      return _utf8.decoder.convert(_gzip.decoder.convert(c.rawHtml!));
    }
    return null;
  }

  /// Like [nextUnreadChapters] but **including content-less placeholders**:
  /// chapters that are unread and still published upstream, whether or not
  /// their content has been downloaded. The EPUB exporter fetches the
  /// content-less ones on demand (or skips them when fetching is off).
  /// [nextUnreadChapters] itself keeps its downloaded-only semantics.
  Future<List<Chapter>> nextUnreadChaptersForExport(Site site, String id, int limit) {
    return (select(chapters)
          ..where((c) =>
              c.site.equals(site.index) &
              c.id.equals(id) &
              c.isRead.equals(false) &
              c.upstreamState.isNotInValues([ChapterUpstreamState.missingUpstream]))
          ..orderBy(canonicalChapterOrder)
          ..limit(limit))
        .get();
  }

  /// The image row registered for [url], if any. Used by the EPUB exporter
  /// to map `<img src>` in stored rawHtml onto stored blobs.
  Future<ChapterImage?> imageByUrl(String url) {
    return (select(chapterImages)..where((i) => i.url.equals(url))).getSingleOrNull();
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
  /// * An empty [toc] is treated as a *failed fetch* (e.g. a Cloudflare
  ///   interstitial) and ignored: the call is a no-op. A real TOC is never
  ///   empty for a published series, and honouring one would mark every
  ///   stored chapter `missingUpstream` and wipe the download queue.
  /// * Live TOC entries are upserted in TOC order (`position = index`,
  ///   `chapterNumber = parseChapterNumber(name)`); a name mismatch marks the
  ///   row `renamed` but **never touches its content or name** — name and
  ///   downloaded content must stay paired. Rows with **no content** (plain
  ///   placeholders or queued rows never downloaded) have nothing to pair
  ///   with, so they adopt the live title and stay `upstream`. A previously
  ///   missing chapter that reappears returns to `upstream`.
  /// * Local rows whose `chapterID` is absent from [toc] become
  ///   `missingUpstream` with `position = kNoPosition` and `queued = false`,
  ///   **keeping** their content, scroll position and name — so a deleted
  ///   chapter sorts after all live ones instead of being lost.
  ///
  /// The `lastReadChapterID` marker is a stable id and needs no adjustment.
  Future<void> reconcileChapters(Site site, String seriesId, List<ChapterData> toc) {
    return transaction(() async {
      if (toc.isEmpty) {
        // Failed/blocked fetch, not an empty series: keep all state.
        return;
      }
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
        var name = const Value<String>.absent();
        if (row.content == null && row.name != entry.name) {
          // Content-less placeholder (or queued, never downloaded): there
          // is no content to keep paired with the old name, so take the
          // live title instead of staying `renamed` forever.
          name = Value(entry.name);
          state = ChapterUpstreamState.upstream;
        }
        // `content` is deliberately untouched: for downloaded rows the local
        // `name` stays the discriminator of the renamed state until a
        // re-download.
        await (update(chapters)..whereSamePrimaryKey(row)).write(ChaptersCompanion(
              position: Value(i),
              chapterNumber: Value(parsed),
              upstreamState: Value(state),
              name: name,
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
  int get schemaVersion => 12;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(onCreate: (m) async {
      await m.createAll();
      await customStatement(_uniqueChapterIndexStatement);
    }, onUpgrade: (Migrator m, int from, int to) async {
      // The v11/v12 columns are added **first**: several historical data
      // steps below (from<4, from==6||7, from<6, from<10) read and rewrite
      // whole `chapters`/`series` rows through drift's *current* generated
      // row classes, so every current column must exist before any of them
      // runs. Each addColumn is guarded with a PRAGMA check because a
      // createTable below (from<5) already creates tables with the current
      // definition, and re-running migrations against partially-upgraded
      // databases must stay safe.
      if (from < 12 && !await columnExists("chapters", "raw_html")) {
        // M3b — raw source HTML for lossless EPUB export. Nullable column,
        // old chapters keep null and export falls back to the RichText tree.
        await m.addColumn(chapters, chapters.rawHtml);
      }
      if (from < 11) {
        // M1 — stable chapter identity. All new columns are defaulted or
        // nullable, so no table rebuild is needed. The *data* part of M1
        // (repair + index) runs at the end, after the historical steps.
        if (!await columnExists("chapters", "position")) {
          await m.addColumn(chapters, chapters.position);
        }
        if (!await columnExists("chapters", "chapter_number")) {
          await m.addColumn(chapters, chapters.chapterNumber);
        }
        if (!await columnExists("chapters", "upstream_state")) {
          await m.addColumn(chapters, chapters.upstreamState);
        }
        if (!await columnExists("chapters", "is_read")) {
          await m.addColumn(chapters, chapters.isRead);
        }
        if (!await columnExists("series", "last_read_chapter_i_d")) {
          await m.addColumn(seriesTable, seriesTable.lastReadChapterID);
        }
      }
      await transaction(() async {
        if (from < 2 && !await columnExists("series", "last_read_date")) {
          await m.addColumn(seriesTable, seriesTable.lastReadDate);
        }
        if (from < 3) {
          if (!await columnExists("series", "thumbnail_width")) {
            await m.addColumn(seriesTable, seriesTable.thumbnailWidth);
          }
          if (!await columnExists("series", "thumbnail_height")) {
            await m.addColumn(seriesTable, seriesTable.thumbnailHeight);
          }
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
      if (from < 5 && !await tableExists("images")) {
        await m.createTable(chapterImages);
      }
      if (from < 7 && !await columnExists("images", "should_download")) {
        // When upgrading from <5 the createTable above already used the
        // current definition (should_download included) — the guard keeps
        // this from failing with "duplicate column".
        await m.addColumn(chapterImages, chapterImages.shouldDownload);
      }
      // from == 6/7 must run *before* the from<6 HTML→RichText conversion
      // only for DBs that already hold RichText (v6+); a from<6 database
      // skips it and gets its spacing from RichTextDocument.html itself.
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
        // HTML → RichText. `addImage` below registers the chapter's images,
        // so the images table must exist (created by the from<5 step above).
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
        // M1 data repair (the columns were added at the start of this
        // strategy). Everything the legacy row shape needs (see the long
        // comment in [repairLegacyChapters]) is exactly what importing an
        // upstream payload needs too, so the repair lives in that one pure
        // function and the migration just applies it to the live table.
        var repair = repairLegacyChapters(await select(chapters).get());
        await delete(chapters).go();
        await batch((b) {
          b.insertAll(chapters, repair.kept);
        });

        // Promote lastRead to the stable chapterID when the slot is unique.
        var promoted = promoteLastReadMarkers(await select(seriesTable).get(), repair.kept);
        for (var s in await select(seriesTable).get()) {
          var chapterID = promoted[(s.site, s.id)];
          if (chapterID != null) {
            await (update(seriesTable)..whereSamePrimaryKey(s))
                .write(SeriesTableCompanion(lastReadChapterID: Value(chapterID)));
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

// ===========================================================================
// Legacy (upstream v10) library import — shared repair logic.
//
// The v10→v11 migration and AppDB.importLegacyV10Library both need the exact
// same set of repairs on v10-shaped chapter rows; they live here as pure
/// functions so the two paths can never diverge. Nothing in this section
// changes the schema or the migration order.
// ===========================================================================

/// Result of [repairLegacyChapters]: the surviving rows plus per-repair counts.
class LegacyChapterRepair {
  /// Repaired rows, one per `(site, id, chapterID)`.
  final List<Chapter> kept;

  /// Content-less `''`-chapterID dummy rows that were dropped.
  final int droppedBlank;

  /// Duplicate-`chapterID` rows that were dropped by the dedupe.
  final int deduped;

  const LegacyChapterRepair({required this.kept, required this.droppedBlank, required this.deduped});
}

/// Repairs a list of v10-shaped chapter rows into current-schema rows,
/// applying the exact rules the v10→v11 migration uses:
///
/// * Upstream v10's `dequeueChapter` stamped a dummy row (empty `chapterID`
///   and name, always content-less — it only ran when the slot had no
///   content) over every dequeued slot, so real v10 data holds several rows
///   per series with `chapterID == ''`. They carry no data: drop them, or
///   the unique `(site, id, chapterID)` index fails on the duplicate `''`
///   keys. A `''` row that somehow *has* content keeps it under a synthetic
///   unique id (`legacy-<number>` — unique within a series, since `number`
///   is part of the primary key) instead of being lost.
/// * Dedupe by `(site, id, chapterID)` (the v10 corruption where one
///   `chapterID` occupied several `number` slots — see `EXPANSION.md` M1):
///   keep the row with content (highest `number` among content-bearing
///   rows, so name+content+scrollPosition stay together), else the highest
///   `number`. Same rule as [AppDB.deduplicateChapters].
/// * `position = number` (best guess until the first reconcile: the legacy
///   TOC index was the position when the row was written).
/// * `chapterNumber = parseChapterNumber(name)`, null for unparseable
///   titles.
///
/// Pure form of the repair shared with the v10→v11 migration. Input rows may
/// carry whatever the current-schema defaults are for the v11 columns — the
/// function sets `position`, `chapterNumber` and the identity fixes itself.
LegacyChapterRepair repairLegacyChapters(List<Chapter> input) {
  var droppedBlank = 0;
  var identified = <Chapter>[];
  for (var c in input) {
    if (c.chapterID.isEmpty) {
      if (c.content == null) {
        droppedBlank++;
        continue;
      }
      identified.add(c.copyWith(chapterID: "legacy-${c.number}"));
    } else {
      identified.add(c);
    }
  }

  var kept = <Chapter>[];
  var deduped = 0;
  for (var group in groupBy(identified, (Chapter c) => (c.site, c.id, c.chapterID)).entries) {
    var rows = group.value.toList()
      ..sort((a, b) {
        var ca = a.content != null ? 1 : 0;
        var cb = b.content != null ? 1 : 0;
        if (ca != cb) {
          return cb.compareTo(ca); // content-bearing rows win
        }
        return b.number.compareTo(a.number); // newest write wins
      });
    kept.add(rows.first);
    deduped += rows.length - 1;
  }

  return LegacyChapterRepair(
    droppedBlank: droppedBlank,
    deduped: deduped,
    kept: [
      for (var c in kept)
        c.copyWith(position: c.number, chapterNumber: Value(parseChapterNumber(c.name))),
    ],
  );
}

/// For each series whose legacy numeric `lastRead` marker resolves to
/// exactly one repaired row with a non-empty `chapterID`, the `chapterID`
/// that marker should be promoted to. Shared by the v11 migration and the
/// v10 library import; keyed by `(site, series id)`.
Map<(Site, String), String> promoteLastReadMarkers(List<Series> series, List<Chapter> repaired) {
  var out = <(Site, String), String>{};
  for (var s in series) {
    var last = s.lastRead;
    if (last == null) {
      continue;
    }
    var rows = repaired.where((c) => c.site == s.site && c.id == s.id && c.number == last).toList();
    if (rows.length == 1 && rows.single.chapterID.isNotEmpty) {
      out[(s.site, s.id)] = rows.single.chapterID;
    }
  }
  return out;
}

/// Per-repair counts returned by [AppDB.importLegacyLibrary].
class LegacyImportReport {
  /// The upstream DB schema the payload was announced/imported at (2..10).
  final int sourceSchema;
  final int series;
  final int chapters;
  final int chaptersWithContent;
  final int droppedBlankRows;
  final int dedupedRows;
  final int lastReadMarkersPromoted;

  const LegacyImportReport({
    required this.sourceSchema,
    required this.series,
    required this.chapters,
    required this.chaptersWithContent,
    required this.droppedBlankRows,
    required this.dedupedRows,
    required this.lastReadMarkersPromoted,
  });

  @override
  String toString() =>
      "format $sourceSchema: $series series, $chapters chapters ($chaptersWithContent with content), "
      "$droppedBlankRows blank rows dropped, $dedupedRows duplicates removed, "
      "$lastReadMarkersPromoted last-read markers promoted";
}

// ===========================================================================
// Upstream (original StoryReader) schema 2..10 DDL + payload inserts.
//
// The upstream commits that shipped each schemaVersion (from
// `git log -L '/int get schemaVersion/,+1:lib/db.dart' upstream/main`), used
// to transcribe the drift-generated `CREATE TABLE` statements per version:
//   2:  e013160 "Init"                      (GitHub release 0.9.0)
//   3:  c410d8c RoyalRoad + thumbnail size  (chapters.name NOT NULL)
//   4:  b10af17 content compression         (GitHub release 0.9.1)
//   5:  fd57983 images table
//   6:  f135d26 RichText conversion         (content becomes RichText JSON)
//   7:  bcccb17 images.should_download
//   8:  dea7d96, 9: 42d10a1, 10: b53552e    (data-only migrations)
// ===========================================================================

/// The `CREATE TABLE` statements of the original upstream StoryReader at
/// schema [n] (2..10), in drift's snake_case column naming (drift-generated
/// DDL for `chapterID` is `chapter_i_d`). Column names, order, nullability
/// and primary keys match the upstream table definitions of that version:
///
/// * `series` gains `thumbnail_width`/`thumbnail_height` at v3.
/// * `chapters.name` becomes `NOT NULL` at v3; `content` is raw HTML `TEXT`
///   until v3 and gzip-compressed `BLOB` from v4 (the fork's from<4 migration
///   step does exactly that conversion).
/// * `images` exists from v5 and gains `should_download` at v7.
///
/// Only used to build throwaway databases that [AppDB] then migrates to the
/// current schema — it is never applied to a user database.
List<String> upstreamSchemaDdl(int n) {
  if (n < 2 || n > 10) {
    throw FormatException("Unsupported upstream schema version: $n");
  }
  final seriesDims = n >= 3 ? ", thumbnail_width INTEGER, thumbnail_height INTEGER" : "";
  final name = n >= 3 ? "name TEXT NOT NULL" : "name TEXT";
  final content = n >= 4 ? "content BLOB" : "content TEXT";
  return [
    "CREATE TABLE series (site INTEGER NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, "
        "description TEXT NOT NULL, thumbnail BLOB, last_read INTEGER, last_read_date INTEGER"
        "$seriesDims, PRIMARY KEY (id, site))",
    "CREATE TABLE chapters (site INTEGER NOT NULL, id TEXT NOT NULL, number INTEGER NOT NULL, "
        "chapter_i_d TEXT NOT NULL, $name, $content, scroll_position INTEGER, "
        "queued INTEGER NOT NULL, PRIMARY KEY (site, id, number))",
    if (n >= 5)
      "CREATE TABLE images (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, "
          "image BLOB${n >= 7 ? ", should_download INTEGER NOT NULL DEFAULT true" : ""})",
  ];
}

String _seriesInsertStatement(int n) =>
    "INSERT INTO series (site, id, name, description, thumbnail, last_read, last_read_date"
    "${n >= 3 ? ", thumbnail_width, thumbnail_height" : ""}) VALUES ("
    "${List.filled(n >= 3 ? 9 : 7, "?").join(", ")})";

List<Object?> _seriesInsertArgs(Map<String, dynamic> j, int n) => [
      j["site"] as int,
      j["id"] as String,
      j["name"] as String,
      j["description"] as String,
      _legacyBlob(j["thumbnail"]),
      j["lastRead"] as int?,
      // Drift stores DateTime columns as unix SECONDS (toJson emits millis —
      // convert here so drift reads the same instant back).
      _legacySeconds(j["lastReadDate"]),
      if (n >= 3) j["thumbnailWidth"] as int?,
      if (n >= 3) j["thumbnailHeight"] as int?,
    ];

String _chapterInsertStatement(int n) =>
    "INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, "
    "queued) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";

List<Object?> _chapterInsertArgs(Map<String, dynamic> j, int n) => [
      j["site"] as int,
      j["id"] as String,
      j["number"] as int,
      // v2-era placeholder rows could carry a NULL chapterID; treat it as ''.
      j["chapterID"] as String? ?? "",
      // v2's chapters.name was nullable and the old app left it NULL on
      // placeholder rows; the later table rebuilds require NOT NULL.
      j["name"] as String? ?? "",
      _chapterContentValue(j["content"], n),
      j["scrollPosition"] as int?,
      _legacyBool(j["queued"], false) ? 1 : 0,
    ];

/// `content` per schema: TEXT (the raw HTML string) below v4, gzip BLOB
/// from v4 on. Accepts both the JSON string and the blob int-array shape
/// regardless of schema, to be forgiving about serializer variants.
Object? _chapterContentValue(dynamic v, int n) {
  if (v == null) {
    return null;
  }
  if (n < 4) {
    if (v is String) {
      return v;
    }
    return _utf8.decode(_legacyBlob(v)!);
  }
  return _legacyBlob(v);
}

String _imageInsertStatement(int n) => n >= 7
    ? "INSERT INTO images (id, url, image, should_download) VALUES (?, ?, ?, ?)"
    : "INSERT INTO images (id, url, image) VALUES (?, ?, ?)";

List<Object?> _imageInsertArgs(Map<String, dynamic> j, int n) => [
      j["id"] as int,
      j["url"] as String,
      _legacyBlob(j["image"]),
      if (n >= 7) _legacyBool(j["shouldDownload"], true) ? 1 : 0,
    ];

// v10 JSON value helpers. Drift's default ValueSerializer (verified in both
// the upstream-pinned drift 2.20.0 and this fork's drift 2.28.0) encodes
// blobs as plain JSON int arrays and DateTimes as epoch millis; some older/
// newer drift variants use base64 strings / ISO-8601 — accept both shapes.

Uint8List? _legacyBlob(dynamic v) {
  if (v == null) {
    return null;
  }
  if (v is Uint8List) {
    return v;
  }
  if (v is List) {
    return Uint8List.fromList(v.cast<int>());
  }
  if (v is String) {
    return base64Decode(v);
  }
  throw FormatException("Unsupported blob encoding: ${v.runtimeType}");
}

DateTime? _legacyDateTime(dynamic v) {
  if (v == null) {
    return null;
  }
  if (v is int) {
    return DateTime.fromMillisecondsSinceEpoch(v);
  }
  return DateTime.parse(v.toString());
}

/// Drift's DB representation of a DateTime column is unix *seconds*; the
/// share JSON carries `toJson()` millis (or an ISO string). Convert to the
/// storage form used when inserting into the temp upstream database.
int? _legacySeconds(dynamic v) {
  var d = _legacyDateTime(v);
  return d == null ? null : d.millisecondsSinceEpoch ~/ 1000;
}

bool _legacyBool(dynamic v, bool fallback) {
  if (v == null) {
    return fallback;
  }
  if (v is bool) {
    return v;
  }
  return (v as int) != 0;
}
