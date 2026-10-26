// M1b: the chapterID-keyed DB API the UI now uses everywhere, the
// Previous/Next navigation rule, and the user-facing bug scenario (author
// deletes a middle chapter -> reading position, retention and navigation
// stay correct).

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/series_data.dart';

final _content1 = Uint8List.fromList([1]);
final _content2 = Uint8List.fromList([2]);
final _content3 = Uint8List.fromList([3]);
final _content4 = Uint8List.fromList([4]);
final _content5 = Uint8List.fromList([5]);

const _series = '623932';
const _site = Site.scribbleHub;

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

void main() {
  late AppDB db;

  setUp(() async {
    db = AppDB(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<Chapter>> downloaded() =>
      db.chaptersForFuture(SeriesData(site: _site, id: _series));

  group('chapterStatusByID', () {
    test('tracks online -> queued -> downloaded by chapterID, not position', () async {
      expect(await db.chapterStatusByID(_site, _series, 'c1').first, ChapterStatus.online);

      await _seed(db, 'c1', 'Chapter One', 0, queued: true);
      expect(await db.chapterStatusByID(_site, _series, 'c1').first, ChapterStatus.queued);

      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2);
      expect(await db.chapterStatusByID(_site, _series, 'c2').first, ChapterStatus.downloaded);

      // A deletion upstream shifts positions; the identity lookup is immune:
      // c1 keeps its status even after reconcile moves everything down.
      await db.into(db.chapters).insert(ChaptersCompanion.insert(
          site: _site, id: _series, number: 2, chapterID: 'c3', name: 'Chapter Three', queued: false));
      await db.reconcileChapters(_site, _series, [
        ChapterData('c2', 'Chapter Two'),
        ChapterData('c3', 'Chapter Three'),
      ]);
      expect(await db.chapterStatusByID(_site, _series, 'c2').first, ChapterStatus.downloaded);
      expect(await db.chapterStatusByID(_site, _series, 'c3').first, ChapterStatus.online);
    });
  });

  group('deleteChapterByID', () {
    test('removes the row and clears a lastReadChapterID pointing at it', () async {
      await db.addSeriesIfNeeded(_site, _series, 'S', 'D');
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2);
      await db.setLastReadChapter(_site, _series, 'c2');

      await db.deleteChapterByID(_site, _series, 'c2');

      expect((await downloaded()).map((c) => c.chapterID), ['c1']);
      var s = await db.select(db.seriesTable).getSingle();
      expect(s.lastReadChapterID, isNull);
      expect(await db.lastReadChapter(_site, _series), isNull);
    });

    test('leaves the marker when it points at another chapter', () async {
      await db.addSeriesIfNeeded(_site, _series, 'S', 'D');
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2);
      await db.setLastReadChapter(_site, _series, 'c1');

      await db.deleteChapterByID(_site, _series, 'c2');
      expect((await db.lastReadChapter(_site, _series))?.chapterID, 'c1');
    });
  });

  group('dequeueChapterByID', () {
    test('clears queued only while the row has no content', () async {
      await _seed(db, 'c1', 'Chapter One', 0, queued: true);
      await _seed(db, 'c2', 'Chapter Two', 1, queued: true, content: _content2);

      await db.dequeueChapterByID(_site, _series, 'c1');
      await db.dequeueChapterByID(_site, _series, 'c2');

      var rows = await (db.select(db.chapters)).get();
      expect(rows.firstWhere((c) => c.chapterID == 'c1').queued, isFalse);
      // Downloaded rows are not "queued"; the guard keeps behaviour of the
      // legacy dequeueChapter.
      expect(rows.firstWhere((c) => c.chapterID == 'c2').queued, isTrue);
    });
  });

  group('missingUpstreamChapters', () {
    test('lists retained deleted chapters with content, in canonical order', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2);
      // Deleted upstream, still stored, plus one deleted-but-never-downloaded.
      await _seed(db, 'c9', 'Chapter Nine', 9, content: _content5,
          position: kNoPosition, upstreamState: ChapterUpstreamState.missingUpstream);
      await _seed(db, 'c8', 'Chapter Eight', 8,
          position: kNoPosition, upstreamState: ChapterUpstreamState.missingUpstream);

      var removed = await db.missingUpstreamChapters(SeriesData(site: _site, id: _series)).first;
      expect(removed.map((c) => c.chapterID), ['c9']);
    });
  });

  group('setScrollPositionByID', () {
    test('writes the scroll position of the identified chapter', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1, scroll: 5);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2, scroll: 7);

      await db.setScrollPositionByID(_site, _series, 'c2', 1234);

      var rows = await (db.select(db.chapters)).get();
      expect(rows.firstWhere((c) => c.chapterID == 'c2').scrollPosition, 1234);
      expect(rows.firstWhere((c) => c.chapterID == 'c1').scrollPosition, 5);

      await db.setScrollPositionByID(_site, _series, 'c2', null);
      rows = await (db.select(db.chapters)).get();
      expect(rows.firstWhere((c) => c.chapterID == 'c2').scrollPosition, isNull);
    });
  });

  group('markReadUpTo', () {
    test('marks every chapter at or before in canonical order', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1);
      await _seed(db, 'c2', 'Chapter Two', 1, content: _content2);
      await _seed(db, 'c3', 'Chapter Three', 2, content: _content3);
      // Retained-removed: sorts after all live chapters in canonical order.
      await _seed(db, 'cx', 'Chapter X', 3, content: _content5,
          position: kNoPosition, upstreamState: ChapterUpstreamState.missingUpstream);

      await db.markReadUpTo(_site, _series, 'c2');
      var rows = await (db.select(db.chapters)).get();
      expect(rows.firstWhere((c) => c.chapterID == 'c1').isRead, isTrue);
      expect(rows.firstWhere((c) => c.chapterID == 'c2').isRead, isTrue);
      expect(rows.firstWhere((c) => c.chapterID == 'c3').isRead, isFalse);
      expect(rows.firstWhere((c) => c.chapterID == 'cx').isRead, isFalse);

      // Up to the retained chapter = everything (it sorts last).
      await db.markReadUpTo(_site, _series, 'cx');
      rows = await (db.select(db.chapters)).get();
      expect(rows.every((c) => c.isRead), isTrue);

      // Unknown id: no-op.
      await db.markReadUpTo(_site, _series, 'nope');
    });

    test('feeds nextUnreadChapters: exporting starts after the marked point', () async {
      for (var (i, id) in ['c1', 'c2', 'c3', 'c4', 'c5'].indexed) {
        await _seed(db, id, 'Chapter $id', i, content: Uint8List.fromList([i]));
      }
      await db.markReadUpTo(_site, _series, 'c3');
      expect((await db.nextUnreadChapters(_site, _series, 100)).map((c) => c.chapterID), ['c4', 'c5']);
    });
  });

  group('hasSeries', () {
    test('reflects library membership', () async {
      expect(await db.hasSeries(_site, _series), isFalse);
      await db.addSeriesIfNeeded(_site, _series, 'S', 'D');
      expect(await db.hasSeries(_site, _series), isTrue);
      // A different site with the same id is not in the library.
      expect(await db.hasSeries(Site.royalRoad, _series), isFalse);
    });
  });

  group('navigation rule (chapterAfter / chapterBefore)', () {
    Future<void> seedLive(String id, String name, int pos) =>
        _seed(db, id, name, pos, content: Uint8List.fromList([pos]), position: pos);

    test('live chapters step contiguously', () async {
      await seedLive('c1', 'Chapter One', 0);
      await seedLive('c2', 'Chapter Two', 1);
      await seedLive('c3', 'Chapter Three', 2);
      var list = await downloaded();
      expect(chapterAfter(list, 'c1')?.chapterID, 'c2');
      expect(chapterAfter(list, 'c3'), isNull);
      expect(chapterBefore(list, 'c2')?.chapterID, 'c1');
      expect(chapterBefore(list, 'c1'), isNull);
      expect(chapterAfter(list, 'ghost'), isNull);
    });

    test('Next skips retained-removed rows from a live chapter', () async {
      await seedLive('c1', 'Chapter One', 0);
      await seedLive('c3', 'Chapter Three', 1);
      await seedLive('c4', 'Chapter Four', 2);
      // Deleted upstream: retained content, sorts after all live chapters.
      await _seed(db, 'c2', 'Chapter Two', 3, content: _content2,
          position: kNoPosition, upstreamState: ChapterUpstreamState.missingUpstream);

      var list = await downloaded();
      expect(list.map((c) => c.chapterID), ['c1', 'c3', 'c4', 'c2']);

      // Mid-book Next never falls into the retained section.
      expect(chapterAfter(list, 'c1')?.chapterID, 'c3');
      expect(chapterAfter(list, 'c3')?.chapterID, 'c4');
      // ...and Previous from the first live chapter never back-jumps into it.
      expect(chapterBefore(list, 'c1'), isNull);
      // Last live chapter has no live successor: the retained block is not
      // "the next chapter".
      expect(chapterAfter(list, 'c4'), isNull);
    });

    test('inside the retained section navigation pages through it', () async {
      await seedLive('c1', 'Chapter One', 0);
      // Retained rows with null chapterNumber tie-break on name:
      // 'Chapter Nine' < 'Chapter Two', so c9 sorts before c2.
      await _seed(db, 'c2', 'Chapter Two', 2, content: _content2,
          position: kNoPosition, upstreamState: ChapterUpstreamState.missingUpstream);
      await _seed(db, 'c9', 'Chapter Nine', 1, content: _content1,
          position: kNoPosition, upstreamState: ChapterUpstreamState.missingUpstream);

      var list = await downloaded();
      expect(list.map((c) => c.chapterID), ['c1', 'c9', 'c2']);

      // Current is live: skip the retained block.
      expect(chapterAfter(list, 'c1'), isNull);
      // Current is retained: walk the block and leave backwards into live.
      expect(chapterBefore(list, 'c9')?.chapterID, 'c1');
      expect(chapterAfter(list, 'c9')?.chapterID, 'c2');
      expect(chapterBefore(list, 'c2')?.chapterID, 'c9');
      expect(chapterAfter(list, 'c2'), isNull);
    });

    test('renamed chapters are navigated normally', () async {
      await _seed(db, 'c1', 'Chapter One', 0, content: _content1,
          upstreamState: ChapterUpstreamState.renamed);
      await seedLive('c2', 'Chapter Two', 1);
      var list = await downloaded();
      expect(chapterAfter(list, 'c1')?.chapterID, 'c2');
      expect(chapterBefore(list, 'c2')?.chapterID, 'c1');
    });
  });

  group('user bug scenario: deleted chapter mid-book', () {
    test('reading position, retention and navigation survive the deletion', () async {
      await db.addSeriesIfNeeded(_site, _series, 'On Astral Tides', 'D');
      // Five downloaded chapters, reading the 4th.
      await _seed(db, 'a1', 'Chapter One', 0, content: _content1, scroll: 100);
      await _seed(db, 'a2', 'Chapter Two', 1, content: _content2, scroll: 200);
      await _seed(db, 'a3', 'Chapter Three', 2, content: _content3, scroll: 300);
      await _seed(db, 'a4', 'Chapter Four', 3, content: _content4, scroll: 400);
      await _seed(db, 'a5', 'Chapter Five', 4, content: _content5, scroll: 500);
      await db.setLastReadChapter(_site, _series, 'a4');

      // The author deletes "Chapter Two" upstream.
      await db.reconcileChapters(_site, _series, [
        ChapterData('a1', 'Chapter One'),
        ChapterData('a3', 'Chapter Three'),
        ChapterData('a4', 'Chapter Four'),
        ChapterData('a5', 'Chapter Five'),
      ]);

      // Continue still resolves to Chapter Four by chapterID.
      var last = await db.lastReadChapter(_site, _series);
      expect(last?.chapterID, 'a4');
      expect(last?.scrollPosition, 400);

      // Chapter Two is retained offline and still readable.
      var list = await downloaded();
      var a2 = list.firstWhere((c) => c.chapterID == 'a2');
      expect(a2.content, _content2);
      expect(a2.scrollPosition, 200);
      expect(a2.upstreamState, ChapterUpstreamState.missingUpstream);
      expect((await db.missingUpstreamChapters(SeriesData(site: _site, id: _series)).first)
          .map((c) => c.chapterID), ['a2']);

      // Canonical order: live chapters keep their live positions, the
      // retained chapter sorts last.
      expect(list.map((c) => c.chapterID), ['a1', 'a3', 'a4', 'a5', 'a2']);

      // Navigation among live chapters skips the retained chapter:
      // Next from the 1st goes to the 3rd (the book's 3rd, TOC position 1).
      expect(chapterAfter(list, 'a1')?.chapterID, 'a3');
      expect(chapterAfter(list, 'a3')?.chapterID, 'a4');
      expect(chapterBefore(list, 'a4')?.chapterID, 'a3');
      // The reading position's neighbours are the live ones, unchanged.
      expect(chapterAfter(list, 'a4')?.chapterID, 'a5');
      expect(chapterAfter(list, 'a5'), isNull);
      // From the retained chapter you can walk back into the live book.
      expect(chapterBefore(list, 'a2')?.chapterID, 'a5');

      // Statuses key on chapterID: Chapter Two stays "downloaded" even
      // though its old TOC slot now holds Chapter Three.
      expect(await db.chapterStatusByID(_site, _series, 'a2').first, ChapterStatus.downloaded);
      expect(await db.chapterStatusByID(_site, _series, 'a3').first, ChapterStatus.downloaded);

      // The old chapter's scroll position survived the shift.
      var s = await db.select(db.seriesTable).getSingle();
      expect(s.lastReadChapterID, 'a4');
    });
  });
}
