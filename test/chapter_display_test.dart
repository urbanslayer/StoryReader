import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/pages/chapter_display.dart';

// The display widgets are DB/router-free, so they pump in isolation inside
// a bare MaterialApp.

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  const longTitle =
      "Seven Hundred And Twenty-One – Contains Status- Ginneka 2, Eri 11?";

  testWidgets('app bar title shows the compact Chapter N label', (t) async {
    await t.pumpWidget(wrap(ChapterAppBarTitle(name: longTitle, chapterNumber: 721)));
    expect(find.textContaining("Chapter 721"), findsOneWidget);
    expect(find.textContaining("Ginneka"), findsNothing);
  });

  testWidgets('app bar title falls back to the name when unnumbered',
      (t) async {
    await t.pumpWidget(wrap(ChapterAppBarTitle(
        name: "Prologue", chapterNumber: null)));
    expect(find.textContaining("Prologue"), findsOneWidget);
  });

  testWidgets('app bar title tap invokes the callback', (t) async {
    var tapped = 0;
    await t.pumpWidget(wrap(ChapterAppBarTitle(
        name: longTitle, chapterNumber: 721, onTap: () => tapped++)));
    await t.tap(find.textContaining("Chapter 721"));
    expect(tapped, 1);
  });

  testWidgets('heading shows short label plus full wrapping title',
      (t) async {
    await t.pumpWidget(wrap(ChapterHeading(name: longTitle, chapterNumber: 721)));
    expect(find.textContaining("Chapter 721"), findsOneWidget);
    // Full title is present in the heading, not truncated to one line.
    var heading = t.widget<Text>(find.text(longTitle));
    // Headline size (headlineSmall = 24sp), not body text: wraps at the
    // content width.
    expect((heading.style?.fontSize ?? 0) >= 24, isTrue);
  });

  testWidgets('heading without a number shows just the name', (t) async {
    await t.pumpWidget(wrap(ChapterHeading(name: "Prologue", chapterNumber: null)));
    expect(find.text("Prologue"), findsOneWidget);
  });

  testWidgets('list prefix renders the number', (t) async {
    await t.pumpWidget(wrap(const ChapterNumberPrefix(721)));
    expect(find.text("721"), findsOneWidget);
  });
}
