// The v10 legacy library import: a realistic upstream share payload (hand-
// built from the v10 table definitions in `git show a6f954d:lib/db.dart`, in
// the post-jsonDecode shape drift's default ValueSerializer produces — blobs
// as JSON int arrays, DateTimes as epoch millis; both legacy alternates
// (base64 blob, ISO date) are exercised too) must import into a current AppDB
// with all the v11 migration repairs applied. Plus a round-trip test that the
// fork's own share JSON still imports unchanged via replaceDB.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/db.dart';
import 'package:story_reader/series_data.dart';

final _thumbA = Uint8List.fromList([10, 11, 12]);
final _thumbB = Uint8List.fromList([4, 5, 6]);
final _dupContent = Uint8List.fromList([9, 9]);
final _legacyContent = Uint8List.fromList([3, 3]);
final _ch12Content = Uint8List.fromList([7]);
final _bContent = Uint8List.fromList([8]);
final _imageBytes = Uint8List.fromList([1, 2, 3]);

const _siteA = Site.scribbleHub;
const _idA = '623932';
const _siteB = Site.royalRoad;
const _idB = '999';

/// v10-era drift `toJson()` shape (post-`json.decode`): series rows have no
/// `lastReadChapterID`, chapter rows no `position`/`chapterNumber`/
/// `upstreamState`/`isRead`.
Map<String, dynamic> _v10Series(
  Site site,
  String id,
  String name, {
  int? lastRead,
  Object? thumbnail,
  Object? lastReadDate,
}) =>
    {
      "site": site.index,
      "id": id,
      "name": name,
      "description": "desc of $name",
      "thumbnail": thumbnail,
      "lastRead": lastRead,
      "lastReadDate": lastReadDate,
      "thumbnailWidth": 100,
      "thumbnailHeight": 150,
    };

Map<String, dynamic> _v10Chapter(
  Site site,
  String id,
  int number,
  String chapterID,
  String name, {
  Object? content,
  int? scroll,
  bool queued = false,
}) =>
    {
      "site": site.index,
      "id": id,
      "number": number,
      "chapterID": chapterID,
      "name": name,
      "content": content,
      "scrollPosition": scroll,
      "queued": queued,
    };

Map<String, dynamic> _v10Payload() => {
      "series": [
        // Series A: blob as JSON int array, date as epoch millis (drift's
        // default serializer). lastRead=1 resolves uniquely to 'p'.
        _v10Series(_siteA, _idA, 'On Astral Tides',
            lastRead: 1, thumbnail: _thumbA, lastReadDate: 1697000000000),
        // Series B: legacy alternates — base64 blob, ISO-8601 date.
        _v10Series(_siteB, _idB, 'A Royal Tale',
            thumbnail: base64Encode(_thumbB), lastReadDate: '2023-10-06T12:00:00.000Z'),
      ],
      "chapters": [
        // Two v10 `dequeueChapter` dummy rows: '' chapterID, no content.
        _v10Chapter(_siteA, _idA, 5, '', ''),
        _v10Chapter(_siteA, _idA, 6, '', ''),
        // A '' row that *has* content: kept as 'legacy-3'.
        _v10Chapter(_siteA, _idA, 3, '', 'Old Chapter', content: _legacyContent, scroll: 6),
        // Corrupted duplicate: 'p' in two slots; the content-bearing one
        // (number 1, also the lastRead slot) must survive.
        _v10Chapter(_siteA, _idA, 0, 'p', 'Chapter One'),
        _v10Chapter(_siteA, _idA, 1, 'p', 'Chapter Two', content: _dupContent, scroll: 21),
        // Duplicate with no content: highest number wins.
        _v10Chapter(_siteA, _idA, 7, 'q', 'Placeholder A', queued: true),
        _v10Chapter(_siteA, _idA, 8, 'q', 'Placeholder B'),
        // Plain row with a parseable title.
        _v10Chapter(_siteA, _idA, 2, 'r', 'Chapter 12', content: _ch12Content),
        // Series B chapter.
        _v10Chapter(_siteB, _idB, 0, 'b1', 'Chapter 1', content: _bContent, queued: true),
      ],
      "chapterImages": [
        {"id": 1, "url": "https://example.com/img.png", "image": _imageBytes, "shouldDownload": true},
        {"id": 2, "url": "https://example.com/gone.png", "image": null, "shouldDownload": false},
      ],
    };

void main() {
  late AppDB db;

  setUp(() async {
    db = AppDB(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('importLegacyV10Library', () {
    test('converts the v10 payload applying all v11 migration repairs', () async {
      // Pre-existing junk must be wiped (replace semantics).
      await db.addSeriesIfNeeded(Site.royalRoad, 'junk', 'Junk', 'gone');

      // Round-trip through encode/decode like the real transfer does.
      final payload = jsonDecode(jsonEncode(_v10Payload())) as Map<String, dynamic>;
      final report = await db.importLegacyV10Library(payload);

      expect(report.series, 2);
      expect(report.chapters, 5);
      expect(report.chaptersWithContent, 4);
      expect(report.droppedBlankRows, 2);
      expect(report.dedupedRows, 2);
      expect(report.lastReadMarkersPromoted, 1);

      var rows = await db.select(db.chapters).get();
      expect(rows.map((c) => c.chapterID).toSet(), {'legacy-3', 'p', 'q', 'r', 'b1'});

      // The '' content-less dummies are gone; the '' content row kept its
      // bytes under the synthetic id.
      var legacy = rows.firstWhere((c) => c.chapterID == 'legacy-3');
      expect(legacy.number, 3);
      expect(legacy.content, _legacyContent);
      expect(legacy.scrollPosition, 6);

      // Dedupe kept the content-bearing 'p' slot (and its scroll position),
      // dropped the content-less 'q' placeholder.
      var p = rows.firstWhere((c) => c.chapterID == 'p');
      expect(p.number, 1);
      expect(p.content, _dupContent);
      expect(p.scrollPosition, 21);
      expect(rows.firstWhere((c) => c.chapterID == 'q').number, 8);

      // position = number and chapterNumber = parseChapterNumber(name).
      for (var c in rows) {
        expect(c.position, c.number, reason: 'position backfill for ${c.chapterID}');
      }
      expect(rows.firstWhere((c) => c.chapterID == 'r').chapterNumber, 12);
      expect(rows.firstWhere((c) => c.chapterID == 'b1').chapterNumber, 1);
      expect(p.chapterNumber, 2);
      expect(rows.every((c) => c.upstreamState == ChapterUpstreamState.upstream), isTrue);
      expect(rows.firstWhere((c) => c.chapterID == 'b1').queued, isTrue);

      // lastRead=1 promoted to the stable chapterID and resolves.
      var sA = await (db.select(db.seriesTable)
            ..where((s) => s.site.equals(_siteA.index) & s.id.equals(_idA)))
          .getSingle();
      expect(sA.lastReadChapterID, 'p');
      var last = await db.lastReadChapter(_siteA, _idA);
      expect(last?.chapterID, 'p');
      expect(last?.content, _dupContent);

      // Series fields: blob/dates survive both encodings.
      expect(sA.thumbnail, _thumbA);
      expect(sA.lastReadDate, DateTime.fromMillisecondsSinceEpoch(1697000000000));
      var sB = await (db.select(db.seriesTable)
            ..where((s) => s.site.equals(_siteB.index) & s.id.equals(_idB)))
          .getSingle();
      expect(sB.thumbnail, _thumbB); // base64 string input
      // Drift round-trips DateTime through epoch millis, so it comes back in
      // local time — compare the instant, not the representation.
      expect(sB.lastReadDate?.toUtc(), DateTime.parse('2023-10-06T12:00:00.000Z'));
      expect(sB.lastReadChapterID, isNull);
      expect(await db.hasSeries(Site.royalRoad, 'junk'), isFalse);

      // Chapter images survive, bytes intact.
      var images = await db.select(db.chapterImages).get();
      expect(images.length, 2);
      expect(images.firstWhere((i) => i.id == 1).image, _imageBytes);
      expect(images.firstWhere((i) => i.id == 2).image, isNull);
      expect(images.firstWhere((i) => i.id == 2).shouldDownload, isFalse);
    });

    test('imported library lists and reads in canonical order', () async {
      await db.importLegacyV10Library(_v10Payload());
      var listed = (await db
              .chaptersForFuture(SeriesData(site: _siteA, id: _idA)))
          .map((c) => c.chapterID)
          .toList();
      // Canonical order: position ASC (p@1, r@2, legacy-3@3).
      expect(listed, ['p', 'r', 'legacy-3']);
    });
  });

  group('fork-to-fork share payload', () {
    test('current-schema share JSON still round-trips through replaceDB', () async {
      var source = AppDB(NativeDatabase.memory());
      addTearDown(() => source.close());
      await source.addSeriesIfNeeded(_siteA, _idA, 'S', 'D', _thumbA, 100, 150);
      await source.into(source.chapters).insert(ChaptersCompanion.insert(
          site: _siteA,
          id: _idA,
          number: 0,
          chapterID: 'c1',
          name: 'Chapter One',
          content: Value(_dupContent),
          scrollPosition: const Value(42),
          queued: false,
          position: const Value(0),
          chapterNumber: const Value(1),
          isRead: const Value(true)));
      var imgId = await source.addImage('https://example.com/a.png');
      await source.setImageData(imgId, _imageBytes);
      await source.setLastReadChapter(_siteA, _idA, 'c1');

      // Exactly the body the fork's share server sends.
      var body = jsonEncode({
        "series": (await source.select(source.seriesTable).get()).map((s) => s.toJson()).toList(),
        "chapters": (await source.select(source.chapters).get()).map((c) => c.toJson()).toList(),
        "chapterImages":
            (await source.select(source.chapterImages).get()).map((i) => i.toJson()).toList(),
      });
      var data = jsonDecode(body) as Map<String, dynamic>;

      await db.replaceDB(
          (data["series"] as List<dynamic>)
              .map((s) => Series.fromJson(s as Map<String, dynamic>))
              .toList(),
          (data["chapters"] as List<dynamic>)
              .map((c) => Chapter.fromJson(c as Map<String, dynamic>))
              .toList(),
          (data["chapterImages"] as List<dynamic>)
              .map((i) => ChapterImage.fromJson(i as Map<String, dynamic>))
              .toList());

      expect(await source.select(source.seriesTable).get(), await db.select(db.seriesTable).get());
      expect(await source.select(source.chapters).get(), await db.select(db.chapters).get());
      expect(
          await source.select(source.chapterImages).get(), await db.select(db.chapterImages).get());
      expect((await db.lastReadChapter(_siteA, _idA))?.chapterID, 'c1');
    });
  });
}
