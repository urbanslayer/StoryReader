// M3b: raw-HTML capture (schema v12) + the EPUB export service.
// Hermetic: in-memory drift DB (plus one file-backed v11->v12 migration
// fixture), fake TOC/chapter fetchers, no network. The one "missing image"
// case points at 127.0.0.1:9 (connection refused immediately). epubcheck is
// invoked only when it is on PATH.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:story_reader/db.dart';
import 'package:story_reader/epub/export_service.dart';
import 'package:story_reader/rich_text_tree.dart';
import 'package:story_reader/series_data.dart';
import 'package:story_reader/sh.dart';
import 'package:story_reader/sh_toc.dart' show SiteBlocked;

const _site = Site.scribbleHub;
const _seriesId = 'series';

final Uint8List pngBytes = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

final String rawTableHtml = '<table><tbody>'
    '<tr><td colspan="2">Wide</td></tr>'
    '<tr><td rowspan="2">Tall</td><td>x</td></tr><tr><td>y</td></tr>'
    '</tbody></table><h2>A heading</h2>';

RichTextDocument docFrom(String html) =>
    RichTextDocument.html(html_parser.parseFragment(html).nodes);

/// Minimal QueryExecutorUser to create a raw v11-shaped file before any
/// drift database touches it.
class _RawUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 0;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {}
}

Future<AppDB> _db() async {
  final db = AppDB(NativeDatabase.memory());
  await db.addSeriesIfNeeded(_site, _seriesId, 'Test Series', 'A test description.',
      pngBytes, 1, 1);
  return db;
}

/// Seed a chapter row. With [contentHtml] the row starts queued (like a
/// download) and content/rawHtml blobs are written through the real
/// `saveChapter` path; without it the row stays a content-less placeholder.
Future<void> _seedChapter(
  AppDB db,
  String chapterID,
  String name,
  int number, {
  String? contentHtml,
  String? rawHtml,
  bool isRead = false,
  int? position,
  ChapterUpstreamState upstreamState = ChapterUpstreamState.upstream,
}) async {
  await db.into(db.chapters).insert(ChaptersCompanion.insert(
        site: _site,
        id: _seriesId,
        number: number,
        chapterID: chapterID,
        name: name,
        queued: contentHtml != null,
        position: Value(position ?? number),
        upstreamState: Value(upstreamState),
        isRead: Value(isRead),
      ));
  if (contentHtml != null) {
    await db.saveChapter(_site, _seriesId, number, chapterID, docFrom(contentHtml), name,
        rawHtml: rawHtml);
  }
}

Future<Archive> _archive(Uint8List bytes) async => ZipDecoder().decodeBytes(bytes);

Future<String> _file(Archive zip, String name) async =>
    utf8.decode(zip.find(name)!.readBytes()!);

void main() {
  late AppDB db;

  setUp(() async => db = await _db());
  tearDown(() async => db.close());

  group('v11 -> v12 migration', () {
    test('adds raw_html and keeps every v11 row', () async {
      final dir = Directory.systemTemp.createTempSync('storyreader_v12');
      final file = File('${dir.path}/db.sqlite');
      final legacy = NativeDatabase(file);
      await legacy.ensureOpen(_RawUser());
      Future<void> sql(String s) => legacy.runCustom(s, []);
      await sql('PRAGMA user_version = 11');
      await sql('''CREATE TABLE series (site INTEGER NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
          description TEXT NOT NULL, thumbnail BLOB, last_read INTEGER, last_read_date INTEGER,
          thumbnail_width INTEGER, thumbnail_height INTEGER, last_read_chapter_i_d TEXT,
          PRIMARY KEY (id, site))''');
      await sql('''CREATE TABLE chapters (site INTEGER NOT NULL, id TEXT NOT NULL, number INTEGER NOT NULL,
          chapter_i_d TEXT NOT NULL, name TEXT NOT NULL, content BLOB, scroll_position INTEGER,
          queued INTEGER NOT NULL, position INTEGER NOT NULL DEFAULT 9223372036854775807,
          chapter_number INTEGER, upstream_state INTEGER NOT NULL DEFAULT 0,
          is_read INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (site, id, number))''');
      await sql('''CREATE TABLE images (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE,
          image BLOB, should_download INTEGER NOT NULL DEFAULT true)''');
      await sql('CREATE UNIQUE INDEX chapters_chapter_key ON chapters (site, id, chapter_i_d)');
      await sql("INSERT INTO series (site, id, name, description) VALUES (0, 'series', 'Old', 'D')");
      await sql("INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, queued, position, chapter_number, upstream_state, is_read)"
          " VALUES (0, 'series', 2, 'z', 'Chapter Two', X'0102', 5, 0, 2, 2, 0, 1)");
      await legacy.close();

      db = AppDB(NativeDatabase(file));

      // Column added.
      final cols = (await db
              .customSelect("SELECT name FROM pragma_table_info('chapters')", readsFrom: {db.chapters})
              .get())
          .map((r) => r.read<String>('name'))
          .toList();
      expect(cols, contains('raw_html'));

      // Row kept byte-identical, read state and everything intact.
      final row = await (db.select(db.chapters)).getSingle();
      expect(row.chapterID, 'z');
      expect(row.content, Uint8List.fromList([1, 2]));
      expect(row.scrollPosition, 5);
      expect(row.position, 2);
      expect(row.chapterNumber, 2);
      expect(row.isRead, isTrue);
      expect(row.rawHtml, isNull);

      // And the column is writable through the normal save path (the row is
      // content-bearing, so the exporter-style caller must re-queue it).
      final s = await (db.select(db.seriesTable)).getSingle();
      expect(s.name, 'Old');
      await (db.update(db.chapters)..where((c) => c.chapterID.equals('z')))
          .write(const ChaptersCompanion(queued: Value(true)));
      await db.saveChapter(_site, 'series', 2, 'z', docFrom('<p>hi</p>'), 'Chapter Two',
          rawHtml: '<p>hi</p>');
      expect(db.chapterRawHtml((await (db.select(db.chapters)).getSingle())), '<p>hi</p>');
      dir.deleteSync(recursive: true);
    });
  });

  group('rawHtml capture at parse time', () {
    test('parseScribbleHubChapter stores #chp_raw inner HTML + outside notes', () {
      final page = '''
        <html><body>
          <div class="chapter-title">Chapter One</div>
          <div id="chp_raw"><p>Prose.</p><table><tr><td colspan="2">m</td></tr></table></div>
          <div class="wi_authornotes"><div class="wi_authornotes_body"><p>Note outside.</p></div></div>
        </body></html>''';
      final data = parseScribbleHubChapter(page, 'c1');
      expect(data.rawHtml, contains('Prose.'));
      expect(data.rawHtml, contains('colspan="2"'));
      expect(data.rawHtml, isNot(contains('id="chp_raw"'))); // inner HTML only
      expect(data.rawHtml, contains('Note outside.'));
    });
  });

  group('exportNextUnread selection', () {
    test('next N unread in canonical order: skips read + missingUpstream, '
        'includes (and reports) content-less placeholders', () async {
      await _seedChapter(db, 'c1', 'Chapter One', 0, contentHtml: '<p>1</p>', isRead: true);
      await _seedChapter(db, 'c2', 'Chapter Two', 1, contentHtml: '<p>2</p>');
      await _seedChapter(db, 'c3', 'Chapter Three', 2); // placeholder
      await _seedChapter(db, 'c4', 'Chapter Four', 3, contentHtml: '<p>4</p>');
      await _seedChapter(db, 'cx', 'Removed Chapter', 9,
          contentHtml: '<p>x</p>',
          position: kNoPosition,
          upstreamState: ChapterUpstreamState.missingUpstream);

      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 10, fetchMissing: false, fetchToc: () async => null);
      expect(result.exportedChapterIDs, ['c2', 'c4']);
      expect(result.skippedUnavailable, ['Chapter Three']);
      expect(result.markAsRead, isTrue);
    });

    test('limit applies to the selection', () async {
      for (var i = 1; i <= 5; i++) {
        await _seedChapter(db, 'c$i', 'Chapter $i', i - 1, contentHtml: '<p>$i</p>');
      }
      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 2, fetchMissing: false, fetchToc: () async => null);
      expect(result.exportedChapterIDs, ['c1', 'c2']);
    });

    test('refreshes the TOC first so placeholders join the export', () async {
      await _seedChapter(db, 'c1', 'Chapter One', 0, contentHtml: '<p>1</p>');
      final result = await exportNextUnread(
        db, _site, _seriesId,
        limit: 10,
        fetchToc: () async => [ChapterData('c1', 'Chapter One'), ChapterData('c2', 'Chapter Two')],
        fetchChapter: (c) async => ChapterData(c.chapterID, c.name, docFrom('<p>fetched</p>'), '<p>fetched</p>'),
      );
      expect(result.exportedChapterIDs, ['c1', 'c2']);
      final c2 = await (db.select(db.chapters)..where((c) => c.chapterID.equals('c2'))).getSingle();
      expect(c2.content, isNotNull); // downloaded into the library
      expect(c2.queued, isFalse);
      expect(db.chapterRawHtml(c2), '<p>fetched</p>');
    });

    test('a failing TOC refresh continues with stored rows', () async {
      await _seedChapter(db, 'c1', 'Chapter One', 0, contentHtml: '<p>1</p>');
      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 10, fetchToc: () async => throw SiteBlocked('https://x', siteName: 'S'));
      expect(result.exportedChapterIDs, ['c1']);
    });

    test('throws when nothing is exportable', () async {
      await _seedChapter(db, 'c1', 'Chapter One', 0, isRead: true);
      await expectLater(
          exportNextUnread(db, _site, _seriesId, fetchToc: () async => null),
          throwsA(isA<ExportException>()));
      // Placeholder + fetch failing for all: also an error, not an empty book.
      await _seedChapter(db, 'c2', 'Chapter Two', 1);
      await expectLater(
          exportNextUnread(db, _site, _seriesId,
              fetchToc: () async => null, fetchChapter: (c) async => throw Exception('dead')),
          throwsA(isA<ExportException>()));
    });

    test('unfetchable chapter skipped and reported; SiteBlocked stops the rest', () async {
      await _seedChapter(db, 'c1', 'Chapter One', 0, contentHtml: '<p>1</p>');
      await _seedChapter(db, 'c2', 'Chapter Two', 1);
      final r1 = await exportNextUnread(db, _site, _seriesId, fetchToc: () async => null,
          fetchChapter: (c) async => throw Exception('404'));
      expect(r1.exportedChapterIDs, ['c1']);
      expect(r1.skippedUnavailable, ['Chapter Two']);
      // Row untouched (no content), dequeued so the download loop can retry.
      final c2 = await (db.select(db.chapters)..where((c) => c.chapterID.equals('c2'))).getSingle();
      expect(c2.content, isNull);
      expect(c2.queued, isFalse);

      await _seedChapter(db, 'c3', 'Chapter Three', 2);
      var calls = 0;
      final r2 = await exportNextUnread(db, _site, _seriesId, fetchToc: () async => null,
          fetchChapter: (c) async {
            calls++;
            throw SiteBlocked('https://x', siteName: 'S');
          });
      expect(r2.exportedChapterIDs, ['c1']);
      expect(r2.skippedUnavailable, ['Chapter Two', 'Chapter Three']);
      expect(calls, 1); // blocked site is not hammered for the rest
    });
  });

  group('exported book content', () {
    test('rawHtml path keeps table spans and headings; RichText fallback otherwise', () async {
      await _seedChapter(db, 'c1', 'Chapter One', 0,
          contentHtml: '<table><tr><td colspan="2">Wide</td></tr><tr><td rowspan="2">Tall</td><td>x</td></tr><tr><td>y</td></tr></table><h2>A heading</h2>',
          rawHtml: rawTableHtml);
      await _seedChapter(db, 'c2', 'Chapter Two', 1, contentHtml: rawTableHtml); // no rawHtml

      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 10, fetchMissing: false, fetchToc: () async => null);
      final zip = await _archive(result.bytes);
      final ch1 = await _file(zip, 'OEBPS/text/ch-0001.xhtml');
      expect(ch1, contains('rowspan="2"'));
      expect(ch1, contains('<h2>A heading</h2>')); // lost by the RichText store
      final ch2 = await _file(zip, 'OEBPS/text/ch-0002.xhtml');
      expect(ch2, contains('<table>')); // fallback renders the stored tree
      expect(ch2, isNot(contains('<h2>')));
    });

    test('images from chapterImages are embedded; missing ones become placeholders', () async {
      final chartUrl = 'https://example.com/chart.png';
      final missingUrl = 'https://127.0.0.1:9/nope.png'; // refused instantly
      await _seedChapter(db, 'c1', 'Chapter One', 0,
          contentHtml: '<p>1</p>',
          rawHtml: '<p>1</p><img src="$chartUrl" alt="chart"><img src="$missingUrl" alt="gone">');
      final id = await db.addImage(chartUrl);
      await db.setImageData(id, pngBytes);

      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 10, fetchMissing: false, fetchToc: () async => null);
      expect(result.imagesEmbedded, 1);
      expect(result.imagesMissing, 1);
      final zip = await _archive(result.bytes);
      expect(zip.find('OEBPS/images/img-$id.png'), isNotNull);
      final ch = await _file(zip, 'OEBPS/text/ch-0001.xhtml');
      expect(ch, contains('<img src="../images/img-$id.png" alt="chart"/>'));
      expect(ch, contains('image-placeholder'));
      expect(ch, contains('gone'));
    });

    test('RichText-path images resolve by stored id', () async {
      final url = 'https://example.com/tree.png';
      // Content goes through the real saveChapter path, which registers the
      // doc's imageSources via addImage and rewrites the node indices.
      await _seedChapter(db, 'c1', 'Chapter One', 0, contentHtml: '<p>1</p><img src="$url" alt="tree">');
      final img = await db.imageByUrl(url);
      expect(img, isNotNull);
      await db.setImageData(img!.id, pngBytes);
      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 10, fetchMissing: false, fetchToc: () async => null);
      expect(result.imagesEmbedded, 1);
      final zip = await _archive(result.bytes);
      expect(zip.find('OEBPS/images/img-${img.id}.png'), isNotNull);
      expect(await _file(zip, 'OEBPS/text/ch-0001.xhtml'), contains('../images/img-${img.id}.png'));
    });

    test('metadata, file name, identifier and cover', () async {
      await _seedChapter(db, 'c7', 'Chapter Seven', 6, contentHtml: '<p>7</p>');
      await _seedChapter(db, 'c8', 'Chapter Eight', 7, contentHtml: '<p>8</p>');
      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 10, fetchMissing: false, fetchToc: () async => null);
      expect(result.fileName, 'test-series_7-8.epub');
      final zip = await _archive(result.bytes);
      final opf = await _file(zip, 'OEBPS/content.opf');
      expect(opf, contains('<dc:title>Test Series — Chapter Seven … Chapter Eight</dc:title>'));
      expect(opf, contains('<dc:identifier id="pub-id">urn:storyreader:scribblehub:series:c7-c8</dc:identifier>'));
      expect(opf, contains('<dc:description>A test description.</dc:description>'));
      expect(opf, contains('properties="cover-image"')); // png thumbnail -> cover
      expect(zip.find('OEBPS/images/cover.png'), isNotNull);
    });

    test('markAsRead is NOT applied by the service; the helper applies it', () async {
      await _seedChapter(db, 'c1', 'Chapter One', 0, contentHtml: '<p>1</p>');
      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 10, fetchMissing: false, markAsRead: true, fetchToc: () async => null);
      var row = await (db.select(db.chapters)).getSingle();
      expect(row.isRead, isFalse); // the save (here: the caller) decides
      await result.markExportedChaptersRead(db, _site, _seriesId);
      row = await (db.select(db.chapters)).getSingle();
      expect(row.isRead, isTrue);

      final noMark = exportNextUnread(db, _site, _seriesId,
          limit: 10, fetchMissing: true, markAsRead: false, fetchToc: () async => null);
      await expectLater(noMark, throwsA(isA<ExportException>())); // c1 is read now
    });
  });

  group('naming helpers', () {
    test('exportFileName slugifies', () {
      expect(exportFileName('On Astral Tides!', 448, 547), 'on-astral-tides_449-548.epub');
      expect(exportFileName('???', 0, 0), 'story_1-1.epub');
    });
    test('exportBookTitle stays reasonable', () {
      expect(exportBookTitle('S', 'A', 'A'), 'S — A');
      expect(exportBookTitle('S', 'A', 'B'), 'S — A … B');
      final long = exportBookTitle('S' * 100, 'A' * 100, 'B' * 100);
      expect(long.length, lessThanOrEqualTo(60 + 3 + 40 + 3 + 40));
      expect(long, contains('…'));
    });
  });

  group('epubcheck', () {
    test('a service-produced 3-chapter book validates (skipped when epubcheck is missing)', () async {
      await _seedChapter(db, 'c1', 'Chapter One', 0,
          contentHtml: '<p>1</p>', rawHtml: '$rawTableHtml<p><b>bold</b></p>');
      await _seedChapter(db, 'c2', 'Chapter Two', 1, contentHtml: '<p>2</p>');
      final url = 'https://example.com/cover-chart.png';
      await _seedChapter(db, 'c3', 'Chapter Three', 2,
          contentHtml: '<p>3</p>', rawHtml: '<p>3</p><img src="$url" alt="cc">');
      final id = await db.addImage(url);
      await db.setImageData(id, pngBytes);

      final result = await exportNextUnread(db, _site, _seriesId,
          limit: 100, fetchMissing: false, fetchToc: () async => null);
      expect(result.exportedChapterIDs, ['c1', 'c2', 'c3']);

      final tmp = Directory.systemTemp.createTempSync('epubcheck_service');
      final file = File('${tmp.path}/${result.fileName}');
      try {
        file.writeAsBytesSync(result.bytes);
        ProcessResult res;
        try {
          res = await Process.run('epubcheck', [file.path], runInShell: true);
        } on ProcessException {
          markTestSkipped('epubcheck not on PATH — container validation skipped');
          return;
        }
        final out = '${res.stdout}\n${res.stderr}';
        printOnFailure('epubcheck output:\n$out');
        expect(res.exitCode, 0, reason: 'epubcheck:\n$out');
        expect(out, isNot(contains('[FATAL]')));
        expect(out, isNot(matches(RegExp(r'\bERROR\b'))));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
