import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/chapter_number.dart';

void main() {
  group('digit titles', () {
    test('Chapter keyword + digits', () {
      expect(parseChapterNumber("Chapter 578 - Title"), 578);
      expect(parseChapterNumber("chapter 578"), 578);
      expect(parseChapterNumber("Ch. 12: Dawn"), 12);
      expect(parseChapterNumber("Chap. 7 - Interlude"), 7);
      expect(parseChapterNumber("Chapter #33"), 33);
    });

    test('bare leading digits', () {
      expect(parseChapterNumber("578: Title"), 578);
      expect(parseChapterNumber("578 - Title"), 578);
      expect(parseChapterNumber("578"), 578);
      expect(parseChapterNumber(" 0"), 0);
    });
  });

  group('word titles', () {
    test('hundreds + tens + units', () {
      expect(parseChapterNumber("Five Hundred and Seventy-Eight"), 578);
      expect(parseChapterNumber("One Hundred and One"), 101);
      expect(parseChapterNumber("Two Hundred Fifty Five"), 255);
      expect(parseChapterNumber("A Hundred and Six"), 106);
    });

    test('tens and units', () {
      expect(parseChapterNumber("Twenty-Two"), 22);
      expect(parseChapterNumber("Ninety-Nine"), 99);
      expect(parseChapterNumber("Zero"), 0);
      expect(parseChapterNumber("Fifteen"), 15);
    });

    test('keyword + word number', () {
      expect(parseChapterNumber("Chapter Twelve: Something"), 12);
      expect(parseChapterNumber("Chapter Twenty-Two"), 22);
      expect(parseChapterNumber("Chapter One More Thing"), 1);
    });

    test('word number followed by separator', () {
      expect(parseChapterNumber("Twelve - Interlude"), 12);
    });
  });

  group('must not parse', () {
    test('number buried in prose', () {
      expect(parseChapterNumber("He Ran 578 Miles"), isNull);
      expect(parseChapterNumber("The Battle of Chapter Sixteen"), isNull);
      expect(parseChapterNumber("On Astral Tides - Chapter 100"), isNull);
      expect(parseChapterNumber("Interlude 578"), isNull);
    });

    test('leading words that are not numbers', () {
      expect(parseChapterNumber("Prologue"), isNull);
      expect(parseChapterNumber("The Two Towers"), isNull);
      expect(parseChapterNumber("A Hundred Years Later"), isNull);
      expect(parseChapterNumber("Three Hundred Thousand"), isNull);
      expect(parseChapterNumber("Author's Note"), isNull);
    });

    test('degenerate input', () {
      expect(parseChapterNumber(""), isNull);
      expect(parseChapterNumber("   "), isNull);
      expect(parseChapterNumber("Chapter"), isNull);
      expect(parseChapterNumber("4th Chapter"), isNull);
    });
  });
}
