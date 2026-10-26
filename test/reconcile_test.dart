import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/series_data.dart';

final _content1 = Uint8List.fromList([1, 2, 3, 4]);
final _content2 = Uint8List.fromList([5, 6, 7, 8]);
final _content3 = Uint8List.fromList([9, 10, 11, 12]);
final _contentX = Uint8List.fromList([42, 42]);

const _series = 'series';
const _site = Site.scribbleHub;

Future<AppDB> _newDb() async {
  final db = AppDB(NativeDatabase.memory());
  return db;
}

Future<void> _seed(
  AppDB db,
  String chapterID,
  String name,
  int number, {
  Uint8List? content,
  int? scroll,
  int? position,
  bool queued = false,
  bool isRead = false,
  ChapterUpstreamState upstreamState = ChapterUpstreamState.upstream,
}) async {
  await db.into(db.chapters).insert(ChaptersCompanion.insert(
        site: _site,
        id: _series,
        number: number,
        chapterID: chapterID,
        name: name,
        content: Value(content),
        scrollPosition: Value(scroll),
        queued: queued,
        position: Value(position ?? number),
        upstreamState: Value(upstreamState),
        isRead: Value(isRead),
      ));
}

Future<List<Chapter>> _all(AppDB db) => (db.select(db.chapters)
      ..orderBy([(c) => OrderingTerm.asc(c.chapterID)]))
    .get();

/// Minimal QueryExecutorUser so a test can drive a raw drift executor before
/// any drift database (and thus any migration) touches the file.
class _RawUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 0;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {}
}

void main() {
  late AppDB db;

  setUp(() async {
    db = await _newDb();
  });

  tearDown(() async {
    await db.close();
  });

  group('reconcileChapters', () {
    test('(a) dropping the middle chapter retains it after the live ones', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1, scroll: 11);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2, scroll: 22);
      await _seed(db, 'c3', 'Chapter Three', 2, content: _content3, scroll: 33);

      await db.reconcileChapters(_site, _series, [
        ChapterData('c1', 'Chapter One'),
        ChapterData('c3', 'Chapter Three'),
      ]);

      var rows = await _all(db);
      expect(rows.length, 3);
      var c1 = rows.firstWhere((c) => c.chapterID == 'c1');
      var c2 = rows.firstWhere((c) => c.chapterID == 'c2');
      var c3 = rows.firstWhere((c) => c.chapterID == 'c3');

      // Survivors keep content + scroll position and take the live positions.
      expect(c1.content, _content1);
      expect(c1.scrollPosition, 11);
      expect(c1.position, 0);
      expect(c1.upstreamState, ChapterUpstreamState.upstream);
      expect(c3.content, _content3);
      expect(c3.scrollPosition, 33);
      expect(c3.position, 1);
      expect(c3.chapterNumber, 3);

      // The dropped chapter keeps its content/scroll/name, is unqueued, and
      // sorts after every live chapter.
      expect(c2.content, _content2);
      expect(c2.scrollPosition, 22);
      expect(c2.name, 'Chapter Two');
      expect(c2.queued, isFalse);
      expect(c2.upstreamState, ChapterUpstreamState.missingUpstream);
      expect(c2.position, kNoPosition);

      var listed = await db.chaptersForFuture(SeriesData(site: _site, id: _series));
      expect(listed.map((c) => c.chapterID), ['c1', 'c3', 'c2']);

      // Reconciling again is a no-op.
      await db.reconcileChapters(_site, _series, [
        ChapterData('c1', 'Chapter One'),
        ChapterData('c3', 'Chapter Three'),
      ]);
      expect((await _all(db)).length, 3);
    });

    test('(b) a reappearing chapter returns to upstream', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2);

      await db.reconcileChapters(_site, _series, [ChapterData('c1', 'Chapter One')]);
      var c2 = (await _all(db)).firstWhere((c) => c.chapterID == 'c2');
      expect(c2.upstreamState, ChapterUpstreamState.missingUpstream);

      await db.reconcileChapters(_site, _series, [
        ChapterData('c1', 'Chapter One'),
        ChapterData('c2', 'Chapter Two'),
      ]);
      c2 = (await _all(db)).firstWhere((c) => c.chapterID == 'c2');
      expect(c2.upstreamState, ChapterUpstreamState.upstream);
      expect(c2.position, 1);
      expect(c2.content, _content2);

      // A brand-new TOC entry is inserted as an upstream placeholder.
      await db.reconcileChapters(_site, _series, [
        ChapterData('c1', 'Chapter One'),
        ChapterData('c2', 'Chapter Two'),
        ChapterData('c4', 'Chapter Four'),
      ]);
      var rows = await _all(db);
      expect(rows.length, 3);
      var c4 = rows.firstWhere((c) => c.chapterID == 'c4');
      expect(c4.upstreamState, ChapterUpstreamState.upstream);
      expect(c4.position, 2);
      expect(c4.chapterNumber, 4);
      expect(c4.content, isNull);
    });

    test('(c) a rename sets renamed and leaves content byte-identical', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1, scroll: 7);

      await db.reconcileChapters(_site, _series, [
        ChapterData('c1', 'Chapter One (Author Cut)'),
      ]);

      var c1 = (await _all(db)).single;
      expect(c1.upstreamState, ChapterUpstreamState.renamed);
      expect(c1.content, _content1); // byte-identical
      expect(c1.scrollPosition, 7);
      // The local name stays the discriminator until a re-download.
      expect(c1.name, 'Chapter One');

      // Name matches again upstream -> back to plain upstream.
      await db.reconcileChapters(_site, _series, [ChapterData('c1', 'Chapter One')]);
      expect((await _all(db)).single.upstreamState, ChapterUpstreamState.upstream);
    });

    test('(f) an empty TOC never wipes stored state', () async {
      // A Cloudflare-blocked or otherwise failed TOC fetch hands reconcile an
      // empty list. That must not mark everything missingUpstream and clear
      // the download queue.
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1, scroll: 4, queued: true);
      await _seed(db, 'c2', 'Chapter Two', 1, queued: true);

      await db.reconcileChapters(_site, _series, const []);

      var rows = await _all(db);
      expect(rows.length, 2);
      var c1 = rows.firstWhere((c) => c.chapterID == 'c1');
      expect(c1.upstreamState, ChapterUpstreamState.upstream);
      expect(c1.queued, isTrue);
      expect(c1.position, 0);
      expect(c1.content, _content1);
      var c2 = rows.firstWhere((c) => c.chapterID == 'c2');
      expect(c2.upstreamState, ChapterUpstreamState.upstream);
      expect(c2.queued, isTrue);
      expect(c2.position, 1);
    });

    test('(g) content-less placeholders adopt renamed titles', () async {
      // Placeholder inserted by an earlier reconcile, never downloaded.
      await _seed(db, 'c1', 'Chapter One', 0);
      // Queued row, not downloaded yet.
      await _seed(db, 'c2', 'Chapter Two', 1, queued: true);
      // Downloaded row: its name must stay paired with its content.
      await _seed(db, 'c3', 'Chapter Three', 2, content: _content3);

      await db.reconcileChapters(_site, _series, [
        ChapterData('c1', 'Chapter One (Rewritten)'),
        ChapterData('c2', 'Chapter Two (Rewritten)'),
        ChapterData('c3', 'Chapter Three (Renamed)'),
      ]);

      var rows = await _all(db);
      var c1 = rows.firstWhere((c) => c.chapterID == 'c1');
      expect(c1.name, 'Chapter One (Rewritten)');
      expect(c1.upstreamState, ChapterUpstreamState.upstream);
      expect(c1.content, isNull);

      var c2 = rows.firstWhere((c) => c.chapterID == 'c2');
      expect(c2.name, 'Chapter Two (Rewritten)');
      expect(c2.upstreamState, ChapterUpstreamState.upstream);
      expect(c2.queued, isTrue); // renaming must not clear the queue

      var c3 = rows.firstWhere((c) => c.chapterID == 'c3');
      expect(c3.name, 'Chapter Three'); // downloaded: local name kept
      expect(c3.upstreamState, ChapterUpstreamState.renamed);
    });

    test('lastReadChapterID survives a deletion unchanged', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2);
      await db.addSeriesIfNeeded(_site, _series, 'S', 'D');
      await db.setLastRead(_site, _series, 1);
      var series = await db
          .select(db.seriesTable)
          .getSingle();
      expect(series.lastReadChapterID, 'c2');

      await db.reconcileChapters(_site, _series, [ChapterData('c1', 'Chapter One')]);
      series = await db.select(db.seriesTable).getSingle();
      expect(series.lastReadChapterID, 'c2');
      var last = await db.lastReadChapter(_site, _series);
      expect(last?.chapterID, 'c2');
      expect(last?.content, _content2);
    });
  });

  group('deduplicateChapters (v10 repair)', () {
    test('(d) one row per chapterID survives, preferring content + highest number', () async {
      // The v11 unique index forbids duplicates, so simulate the corrupted
      // v10 shape by dropping it first — exactly the state the 10 -> 11
      // migration runs against.
      await db.customStatement('DROP INDEX chapters_chapter_key');

      // Old shifted slot (no content) + new correct slot (content, scroll).
      await _seed(db, 'x', 'Stale Name', 4);
      await _seed(db, 'x', 'Chapter Five', 5, content: _contentX, scroll: 9);
      // Two contentless slots: newest write wins.
      await _seed(db, 'y', 'Older', 0);
      await _seed(db, 'y', 'Newer', 1);
      // Unrelated row stays untouched.
      await _seed(db, 'z', 'Chapter One', 2, content: _content1);

      var deleted = await db.deduplicateChapters();
      expect(deleted, 2);

      var rows = await _all(db);
      expect(rows.length, 3);
      var x = rows.firstWhere((c) => c.chapterID == 'x');
      expect(x.number, 5);
      expect(x.name, 'Chapter Five');
      expect(x.content, _contentX);
      expect(x.scrollPosition, 9);
      var y = rows.firstWhere((c) => c.chapterID == 'y');
      expect(y.number, 1);
      expect(y.name, 'Newer');

      // With the unique index restored, duplicates are impossible again.
      await db.customStatement(
          'CREATE UNIQUE INDEX chapters_chapter_key ON chapters (site, id, chapter_i_d)');
      await expectLater(_seed(db, 'x', 'Duplicate', 42), throwsA(isA<Exception>()));
    });
  });

  group('v10 -> v11 migration', () {
    test('upgrading a real v10 database dedupes, backfills and adds the index', () async {
      final dir = Directory.systemTemp.createTempSync('storyreader_mig');
      final file = File('${dir.path}/db.sqlite');

      // Build a v10-shaped database with the exact drift v10 schema.
      final legacy = NativeDatabase(file);
      await legacy.ensureOpen(_RawUser());
      Future<void> legacyRun(String sql) => legacy.runCustom(sql, []);
      await legacyRun('PRAGMA user_version = 10');
      await legacyRun('''
        CREATE TABLE series (site INTEGER NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
          description TEXT NOT NULL, thumbnail BLOB, last_read INTEGER, last_read_date INTEGER,
          thumbnail_width INTEGER, thumbnail_height INTEGER, PRIMARY KEY (id, site))''');
      await legacyRun('''
        CREATE TABLE chapters (site INTEGER NOT NULL, id TEXT NOT NULL, number INTEGER NOT NULL,
          chapter_i_d TEXT NOT NULL, name TEXT NOT NULL, content BLOB, scroll_position INTEGER,
          queued INTEGER NOT NULL, PRIMARY KEY (site, id, number))''');
      await legacyRun('''
        CREATE TABLE images (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE,
          image BLOB, should_download INTEGER NOT NULL DEFAULT true)''');

      // Corrupted v10 state: chapterID 'x' occupies two number slots, one of
      // them content-bearing; series.last_read points at the unique 'z' slot.
      // Upstream v10's `dequeueChapter` also stamped dummy rows with an EMPTY
      // chapterID over every content-less slot it dequeued, so real v10 DBs
      // hold several '' rows — they must not break the unique index.
      await legacyRun('INSERT INTO series (site, id, name, description, last_read) '
          "VALUES (0, 'series', 'S', 'D', 2)");
      await legacyRun('INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, queued) '
          "VALUES (0, 'series', 4, 'x', 'Stale', NULL, NULL, 0)");
      await legacyRun('INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, queued) '
          "VALUES (0, 'series', 5, 'x', 'Chapter Five', X'2A2A', 9, 0)");
      await legacyRun('INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, queued) '
          "VALUES (0, 'series', 2, 'z', 'Chapter Two', X'0102', 5, 0)");
      await legacyRun('INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, queued) '
          "VALUES (0, 'series', 0, '', '', NULL, NULL, 0)");
      await legacyRun('INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, queued) '
          "VALUES (0, 'series', 1, '', '', NULL, NULL, 1)");
      // A '' chapterID that somehow carries content: kept under a synthetic
      // unique id rather than dropped.
      await legacyRun('INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, queued) '
          "VALUES (0, 'series', 3, '', 'Chapter Four', X'0303', 6, 0)");
      // Content-less row whose title carries no number: the chapterNumber
      // backfill must not drop rows it cannot parse.
      await legacyRun('INSERT INTO chapters (site, id, number, chapter_i_d, name, content, scroll_position, queued) '
          "VALUES (0, 'series', 6, 'p', 'Prologue', NULL, NULL, 0)");
      await legacy.close();

      // Opening the v11 AppDB on that file runs the 10 -> 11 migration.
      db = AppDB(NativeDatabase(file));
      var rows = await _all(db);

      // Deduped: one row per chapterID, content-bearing slot kept. The two
      // content-less '' dummies are gone; the '' row with content survived
      // under a synthetic id; the unparseable 'Prologue' row survived the
      // chapterNumber backfill.
      expect(rows.map((c) => c.chapterID), ['legacy-3', 'p', 'x', 'z']);
      expect(rows.firstWhere((c) => c.chapterID == 'p').chapterNumber, isNull);
      var legacyRow = rows.firstWhere((c) => c.chapterID == 'legacy-3');
      expect(legacyRow.number, 3);
      expect(legacyRow.content, Uint8List.fromList([3, 3]));
      expect(legacyRow.scrollPosition, 6);
      var x = rows.firstWhere((c) => c.chapterID == 'x');
      expect(x.number, 5);
      expect(x.content, _contentX);
      expect(x.scrollPosition, 9);

      // Backfills: position = number, chapterNumber parsed from the title.
      expect(x.position, 5);
      expect(x.chapterNumber, 5);
      var z = rows.firstWhere((c) => c.chapterID == 'z');
      expect(z.position, 2);
      expect(z.upstreamState, ChapterUpstreamState.upstream);
      expect(z.isRead, isFalse);

      // lastRead promoted to the stable chapterID (slot was unique).
      var s = await db.select(db.seriesTable).getSingle();
      expect(s.lastRead, 2);
      expect(s.lastReadChapterID, 'z');

      // Unique index is in place.
      await expectLater(_seed(db, 'z', 'Dup', 42), throwsA(isA<Exception>()));

      dir.deleteSync(recursive: true);
    });
  });

  group('nextUnreadChapters / setRead', () {
    test('(e) canonical order + limit, excluding read and missingUpstream', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2);
      await _seed(db, 'c3', 'Chapter Three', 2, content: _content3);
      // Deleted-but-retained: content present, not unread.
      await _seed(db, 'c0', 'Chapter Zero', 3,
          content: _contentX, position: kNoPosition, upstreamState: ChapterUpstreamState.missingUpstream);
      // No content: not unread either.
      await _seed(db, 'c5', 'Chapter Five', 4);

      expect(
          (await db.nextUnreadChapters(_site, _series, 10)).map((c) => c.chapterID),
          ['c1', 'c2', 'c3']);
      expect(
          (await db.nextUnreadChapters(_site, _series, 2)).map((c) => c.chapterID),
          ['c1', 'c2']);

      await db.setRead(_site, _series, 'c1', true);
      expect(
          (await db.nextUnreadChapters(_site, _series, 10)).map((c) => c.chapterID),
          ['c2', 'c3']);

      await db.setRead(_site, _series, 'c1', false);
      expect(
          (await db.nextUnreadChapters(_site, _series, 10)).map((c) => c.chapterID),
          ['c1', 'c2', 'c3']);
    });
  });
}
