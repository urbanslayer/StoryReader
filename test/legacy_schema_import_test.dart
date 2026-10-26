// Importing a library from ANY original-app schema (2..10): payload JSON
// (drift `toJson()` shapes, per each version's tables — see upstreamSchemaDdl
// for the DDL provenance) is inserted into a temp DB with the exact upstream
// DDL and run through the REAL migration chain up to schema 12. Schemas 2, 4,
// 6 and 10 are exercised here; 4 (GitHub release 0.9.1 — the version the
// user's original app almost certainly is) gets the fullest assertions. Plus a
// file-database test: a v4-schema DB on disk opens through AppDB and migrates
// to 12 cleanly.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' show parseFragment;
import 'package:story_reader/db.dart';
import 'package:story_reader/rich_text_tree.dart';
import 'package:story_reader/series_data.dart';

/// The upstream chapter codec (gzip raw-deflate, same as `AppDB._gzip`).
final _gzip = GZipCodec(level: 9, raw: true, gzip: false);

const _site = Site.scribbleHub;
const _id = '623932';
const _imgUrl = 'https://example.com/pic.png';

/// Chapter HTML containing a table and an image — the shapes the RichText
/// conversion must reproduce (and register the image for).
const _html = '''
<p>Hello there</p>
<table><tr><td>a</td><td>b</td></tr><tr><td colspan="2">wide</td></tr></table>
<img src="$_imgUrl">
<p>The End</p>
''';

Uint8List _gzipBytes(String s) => Uint8List.fromList(_gzip.encoder.convert(utf8.encode(s)));

/// The RichText JSON a v6+ app would have stored for [_html], with the image
/// pointing at images row id 1 (the payload's chapterImages entry).
String _richTextJson() {
  var doc = RichTextDocument.html(parseFragment(_html).nodes);
  doc.rewriteImageIndices([1]);
  return jsonEncode(doc.toJson());
}

/// Content payload for [schema]: raw HTML string below v4 (TEXT column),
/// gzip'd HTML bytes at v4 (v6 converts them to RichText), gzip'd RichText
/// JSON from v6 on.
Object? _contentFor(int schema) => switch (schema) {
      <4 => _html,
      4 => _gzipBytes(_html),
      _ => _gzipBytes(_richTextJson()),
    };

/// `series` toJson for this schema: v2 has no thumbnailWidth/Height keys.
Map<String, dynamic> _seriesJson(int schema) => {
      "site": _site.index,
      "id": _id,
      "name": "On Astral Tides",
      "description": "desc",
      "thumbnail": Uint8List.fromList([10, 11, 12]),
      "lastRead": 1,
      "lastReadDate": 1697000000000,
      if (schema >= 3) "thumbnailWidth": 100,
      if (schema >= 3) "thumbnailHeight": 150,
    };

Map<String, dynamic> _chapterJson(int schema, int number, String? chapterID, String? name,
        {Object? content, int? scroll, bool queued = false}) =>
    {
      "site": _site.index,
      "id": _id,
      "number": number,
      "chapterID": chapterID,
      "name": name,
      "content": content,
      "scrollPosition": scroll,
      "queued": queued,
    };

/// A realistic share payload for upstream schema [schema]:
/// * a corrupted duplicate ('p' in two slots; the content one at number 1,
///   also the lastRead slot, must win),
/// * a plain row 'r' (number 2),
/// * two blank placeholder rows — v2 shape carries NULL chapterID/name,
///   later shapes '' — which must be dropped.
/// v5+ payloads carry chapterImages (the v5 share server added the key);
/// the 0.9.1 (schema 4) share server sent only series+chapters.
Map<String, dynamic> _payload(int schema) {
  var content = _contentFor(schema);
  return {
    "series": [_seriesJson(schema)],
    "chapters": [
      _chapterJson(schema, 0, 'p', 'Chapter One'),
      _chapterJson(schema, 1, 'p', 'Chapter Two', content: content, scroll: 21),
      _chapterJson(schema, 2, 'r', 'Chapter 7'),
      if (schema == 2)
        // v2-era placeholder: name/chapterID were nullable and left NULL.
        _chapterJson(schema, 3, null, null)
      else
        _chapterJson(schema, 3, '', ''),
      _chapterJson(schema, 4, '', ''),
    ],
    if (schema >= 5)
      "chapterImages": [
        {
          "id": 1,
          "url": _imgUrl,
          "image": null,
          if (schema >= 7) "shouldDownload": true,
        },
      ],
  };
}

/// Common expectations for a payload of upstream schema [schema] imported
/// into [db] via the migration-chain path.
Future<void> _expectImported(AppDB db, int schema) async {
  var rows = await db.select(db.chapters).get();
  expect(rows.map((c) => c.chapterID).toSet(), {'p', 'r'},
      reason: 'blank rows dropped, duplicate merged (schema $schema)');

  var p = rows.firstWhere((c) => c.chapterID == 'p');
  expect(p.number, 1, reason: 'content-bearing duplicate slot wins');
  expect(p.name, 'Chapter Two');
  expect(p.scrollPosition, 21);
  expect(p.position, 1);
  expect(p.chapterNumber, 2);
  expect(p.upstreamState, ChapterUpstreamState.upstream);
  expect(p.isRead, isFalse);
  // rawHtml is only written by v12-era downloads; migrated content stays null.
  expect(p.rawHtml, isNull);

  var r = rows.firstWhere((c) => c.chapterID == 'r');
  expect(r.chapterNumber, 7);
  expect(r.position, 2);

  // The content is a valid RichText document carrying the table and the
  // image of the source HTML.
  var doc = db.chapterContents(p);
  expect(doc, isNotNull, reason: 'chapterContents decodes (schema $schema)');
  var kinds = <Type>{};
  var imageURLs = <String>[];
  doc!.visit((e) {
    kinds.add(e.runtimeType);
    if (e is RichTextImage) {
      imageURLs.add(e.url);
    }
  });
  expect(kinds, contains(RichTextTable), reason: 'table survived conversion');
  expect(imageURLs, contains(_imgUrl), reason: 'image element kept its url');

  // The image url is registered in the images table (from the payload at
  // v5+, registered by the HTML→RichText step at v2/v4).
  var img = await db.imageByUrl(_imgUrl);
  expect(img, isNotNull, reason: 'image registered (schema $schema)');

  // lastRead=1 promoted to the stable chapterID and resolves.
  var s = await (db.select(db.seriesTable)
        ..where((s) => s.site.equals(_site.index) & s.id.equals(_id)))
      .getSingle();
  expect(s.lastReadChapterID, 'p');
  expect(s.name, "On Astral Tides");
  expect(s.description, "desc");
  expect(s.thumbnail, Uint8List.fromList([10, 11, 12]));
  // Drift stores DateTime as unix seconds; the JSON millis round-trip is
  // second-exact for this value.
  expect(s.lastReadDate, DateTime.fromMillisecondsSinceEpoch(1697000000000));
  expect(s.thumbnailWidth, schema >= 3 ? 100 : isNull);
  expect(s.thumbnailHeight, schema >= 3 ? 150 : isNull);
  var last = await db.lastReadChapter(_site, _id);
  expect(last?.chapterID, 'p');

  // Library-level accessors work on the imported rows.
  var listed = (await db.chaptersForFuture(SeriesData(site: _site, id: _id)))
      .map((c) => c.chapterID)
      .toList();
  expect(listed, ['p'], reason: 'only content-bearing chapters list');
}

void main() {
  group('importLegacyLibrary through the migration chain', () {
    for (var schema in [2, 4, 6, 10]) {
      test('schema $schema payload imports with repairs and conversions', () async {
        var db = AppDB(NativeDatabase.memory());
        addTearDown(() => db.close());
        // Pre-existing junk must be wiped (replace semantics).
        await db.addSeriesIfNeeded(Site.royalRoad, 'junk', 'Junk', 'gone');

        // Round-trip through encode/decode like the real transfer does.
        var payload = jsonDecode(jsonEncode(_payload(schema))) as Map<String, dynamic>;
        var report = await db.importLegacyLibrary(payload, sourceSchema: schema);

        expect(report.sourceSchema, schema);
        expect(report.series, 1);
        expect(report.chapters, 2);
        expect(report.chaptersWithContent, 1);
        expect(report.droppedBlankRows, 2);
        expect(report.dedupedRows, 1);
        expect(report.lastReadMarkersPromoted, 1);

        await _expectImported(db, schema);
        expect(await db.hasSeries(Site.royalRoad, 'junk'), isFalse);
      });
    }

    test('schema 4: report/toString mentions the source format', () async {
      var db = AppDB(NativeDatabase.memory());
      addTearDown(() => db.close());
      var report = await db.importLegacyLibrary(
          jsonDecode(jsonEncode(_payload(4))) as Map<String, dynamic>,
          sourceSchema: 4);
      expect(report.toString(), startsWith("format 4:"));
    });

    test('importLegacyV10Library wrapper reports schema 10', () async {
      var db = AppDB(NativeDatabase.memory());
      addTearDown(() => db.close());
      var report = await db.importLegacyV10Library(
          jsonDecode(jsonEncode(_payload(10))) as Map<String, dynamic>);
      expect(report.sourceSchema, 10);
      await _expectImported(db, 10);
    });

    test('unsupported schema numbers are rejected', () async {
      var db = AppDB(NativeDatabase.memory());
      addTearDown(() => db.close());
      expect(() => db.migrateUpstreamPayload(_payload(10), 1), throwsFormatException);
      expect(() => db.migrateUpstreamPayload(_payload(10), 11), throwsFormatException);
    });
  });

  group('upstreamSchemaDdl', () {
    test('per-version shape (thumbnail dims at 3, BLOB content at 4, images at 5/7)', () {
      expect(upstreamSchemaDdl(2).join(), isNot(contains("thumbnail_width")));
      expect(upstreamSchemaDdl(2).join(), isNot(contains("CREATE TABLE images")));
      expect(upstreamSchemaDdl(2).join(), contains("content TEXT"));
      expect(upstreamSchemaDdl(2).join(), contains("name TEXT,"));
      expect(upstreamSchemaDdl(3).join(), contains("thumbnail_width"));
      expect(upstreamSchemaDdl(3).join(), contains("name TEXT NOT NULL"));
      expect(upstreamSchemaDdl(3).join(), contains("content TEXT"));
      expect(upstreamSchemaDdl(4).join(), contains("content BLOB"));
      expect(upstreamSchemaDdl(4).join(), isNot(contains("CREATE TABLE images")));
      expect(upstreamSchemaDdl(5).join(), contains("CREATE TABLE images"));
      expect(upstreamSchemaDdl(5).join(), isNot(contains("should_download")));
      expect(upstreamSchemaDdl(7).join(), contains("should_download"));
      expect(upstreamSchemaDdl(10).join(), contains("chapter_i_d"));
    });
  });

  group('file DB at upstream schema 4', () {
    test('opening AppDB on a v4-schema file migrates to 12', () async {
      var dir = Directory.systemTemp.createTempSync('storyreader_v4');
      addTearDown(() => dir.deleteSync(recursive: true));
      var file = File('${dir.path}/db.sqlite');

      // Build a schema-4 database with the exact upstream DDL (release 0.9.1:
      // gzip'd HTML content, no images table) before any AppDB touches it.
      var legacy = NativeDatabase(file);
      await legacy.ensureOpen(_RawUser());
      for (var stmt in upstreamSchemaDdl(4)) {
        await legacy.runCustom(stmt, []);
      }
      await legacy.runCustom('PRAGMA user_version = 4', []);
      await legacy.runCustom(
          'INSERT INTO series (site, id, name, description, thumbnail, last_read, '
          'last_read_date, thumbnail_width, thumbnail_height) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [_site.index, _id, 'S', 'D', [1, 2, 3], 0, 1697000000, 100, 150]);
      await legacy.runCustom(
          'INSERT INTO chapters (site, id, number, chapter_i_d, name, content, '
          'scroll_position, queued) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [_site.index, _id, 0, 'c1', 'Chapter 1', _gzipBytes(_html), 42, 0]);
      await legacy.close();

      var db = AppDB(NativeDatabase(file));
      addTearDown(() => db.close());

      // Drift upgraded 4 -> 12.
      var version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 12);

      // v11/v12 columns exist, images table was created (with should_download),
      // and the unique chapter index was added.
      expect(await db.columnExists('chapters', 'raw_html'), isTrue);
      expect(await db.columnExists('chapters', 'position'), isTrue);
      expect(await db.columnExists('series', 'last_read_chapter_i_d'), isTrue);
      expect(await db.tableExists('images'), isTrue);
      expect(await db.columnExists('images', 'should_download'), isTrue);
      var idx = await db
          .customSelect("SELECT 1 AS x FROM sqlite_master WHERE type = 'index' AND name = 'chapters_chapter_key'")
          .get();
      expect(idx, isNotEmpty);

      // Content was converted HTML -> RichText and the image registered.
      var c = await (db.select(db.chapters)..where((t) => t.chapterID.equals('c1')))
          .getSingle();
      expect(c.scrollPosition, 42);
      expect(c.position, 0);
      expect(c.chapterNumber, 1);
      var doc = db.chapterContents(c);
      expect(doc, isNotNull);
      expect(await db.imageByUrl(_imgUrl), isNotNull);
      expect(await db.lastReadChapter(_site, _id), isNotNull);
      expect((await db.lastReadChapter(_site, _id))?.chapterID, 'c1');
    });
  });
}

/// Minimal QueryExecutorUser so the test can drive a raw drift executor before
/// any drift database (and thus any migration) touches the file.
class _RawUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 0;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {}
}
