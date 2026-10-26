// M3a: EPUB 3 builder, HTML→XHTML sanitizer and RichText→XHTML fallback.
// Hermetic: fixtures on disk, no network. epubcheck is invoked only if it
// is on PATH (skipped with a reason otherwise).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:story_reader/epub/epub_builder.dart';
import 'package:story_reader/epub/html_to_xhtml.dart';
import 'package:story_reader/epub/rich_text_to_xhtml.dart';
import 'package:story_reader/rich_text_tree.dart';

String _fixture(String name) =>
    File('test/fixtures/epub/$name').readAsStringSync();

final String shFixture = _fixture('sh_chapter.html');
final String rrFixture = _fixture('rr_chapter.html');

// 1x1 transparent PNG (real file, base64).
final Uint8List pngBytes = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

// --- strict XML well-formedness checker ------------------------------------
//
// package:html is deliberately lenient, so we verify well-formedness with an
// independent, strict scanner: tags must be balanced and properly nested,
// void elements self-closed, attributes double-quoted, and text may contain
// only the predefined XML entities (&amp; &lt; &gt; &quot; &apos;) or numeric
// character references — no HTML named entities like &nbsp;.
final RegExp _xmlTag = RegExp(
    r'^<(/?)([A-Za-z][A-Za-z0-9:._-]*)((?:\s+[A-Za-z_:][A-Za-z0-9:._-]*\s*=\s*"[^"]*")*)\s*(/?)>$');
final RegExp _xmlEntities = RegExp(r'&(?:amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);');
const Set<String> _xmlVoid = {
  'br', 'hr', 'img', 'wbr', 'input', 'meta', 'link', 'col', 'base', 'area',
  'source', 'track', 'embed', 'param',
};

void expectStrictXml(String xml, {String label = 'xml'}) {
  final stack = <String>[];
  final failures = <String>[];
  var i = 0;
  void checkText(String text) {
    var pos = 0;
    while (true) {
      final amp = text.indexOf('&', pos);
      if (amp < 0) break;
      final m = _xmlEntities.matchAsPrefix(text, amp);
      if (m == null) {
        failures.add('raw & at ...${text.substring(amp, amp + 20 > text.length ? text.length : amp + 20)}...');
        break;
      }
      pos = m.end;
    }
    if (text.contains('<')) failures.add('raw < in text');
    if (RegExp('[\x00-\x08\x0B\x0C\x0E-\x1F]').hasMatch(text)) {
      failures.add('illegal XML control char in text');
    }
  }

  while (i < xml.length) {
    final lt = xml.indexOf('<', i);
    if (lt < 0) {
      checkText(xml.substring(i));
      break;
    }
    checkText(xml.substring(i, lt));
    if (xml.startsWith('<!--', lt)) {
      failures.add('comment not allowed at offset $lt');
      i = xml.length;
      break;
    }
    if (xml.startsWith('<?', lt)) {
      final end = xml.indexOf('>', lt);
      if (end < 0) {
        failures.add('unterminated PI');
        return;
      }
      i = end + 1;
      continue;
    }
    if (xml.startsWith('<!', lt)) {
      final end = xml.indexOf('>', lt);
      if (end < 0) {
        failures.add('unterminated declaration');
        return;
      }
      i = end + 1;
      continue;
    }
    final match = _xmlTag.matchAsPrefix(xml.substring(lt));
    if (match == null) {
      failures.add('malformed tag/unquoted attribute at offset $lt: '
          '${xml.substring(lt, lt + 40 > xml.length ? xml.length : lt + 40)}');
      return;
    }
    final closing = match[1] == '/';
    final tag = match[2]!;
    final selfClosed = match[4] == '/';
    if (closing) {
      if (stack.isEmpty || stack.removeLast() != tag) {
        failures.add('closing </$tag> does not match open stack $stack');
        return;
      }
    } else if (selfClosed) {
      // fine
    } else if (_xmlVoid.contains(tag.toLowerCase())) {
      failures.add('void element <$tag> not self-closed at offset $lt');
    } else {
      stack.add(tag);
    }
    i = lt + match.end;
  }
  if (stack.isNotEmpty) failures.add('unclosed tags: $stack');
  expect(failures, isEmpty, reason: 'expected well-formed XML ($label)');
}

String wrapFragment(String fragment) =>
    '<root xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '$fragment</root>';

// --- tests ------------------------------------------------------------------

void main() {
  group('imageMediaType', () {
    test('sniffs magic bytes', () {
      expect(imageMediaType(pngBytes), 'image/png');
      expect(imageMediaType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])), 'image/jpeg');
      expect(imageMediaType(Uint8List.fromList(utf8.encode('GIF89a....'))), 'image/gif');
      final webp = Uint8List.fromList([...utf8.encode('RIFF'), 4, 0, 0, 0, ...utf8.encode('WEBP')]);
      expect(imageMediaType(webp), 'image/webp');
      expect(imageMediaType(Uint8List.fromList(utf8.encode('<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>'))), 'image/svg+xml');
      expect(imageMediaType(Uint8List.fromList([1, 2, 3, 4, 5])), 'application/octet-stream');
    });
  });

  group('sanitizeHtmlToXhtml (ScribbleHub fixture)', () {
    late String out;
    late String unresolved;

    setUpAll(() {
      out = sanitizeHtmlToXhtml(shFixture, resolveImage: (src) {
        if (src.contains('chapter-chart')) return '../images/img-7.png';
        return null;
      });
      unresolved = sanitizeHtmlToXhtml(shFixture, resolveImage: (src) => null);
    });

    test('output is well-formed XHTML and parses in package:html', () {
      expectStrictXml(wrapFragment(out), label: 'SH sanitized');
      final reparsed = html_parser.parseFragment(out);
      expect(reparsed.querySelectorAll('table'), hasLength(1));
      expect(reparsed.querySelector('aside.author-note'), isNotNull);
    });

    test('table keeps rowspan/colspan and allow-listed styles', () {
      expect(out, contains('colspan="3"'));
      expect(out, contains('rowspan="2"'));
      expect(out, contains('border: 1px solid black'));
      expect(out, contains('text-align: center'));
      expect(out, contains('text-align: right'));
      expect(out, contains('background-color: #cccccc'));
      expect(out, contains('background-color: #eeeeee'));
      expect(out, contains('border-collapse: collapse'));
      expect(out, contains('width: 500px')); // width kept on table
      expect(out, contains('<thead>'));
      expect(out, contains('<tbody>'));
      expect(out, contains('<th'));
    });

    test('script, onclick, display:none and javascript: are gone', () {
      expect(out, isNot(contains('should never appear')));
      expect(out, isNot(contains('<script')));
      expect(out, isNot(contains('onclick')));
      expect(out, isNot(contains('alert(')));
      expect(out, isNot(contains('must vanish')));
      expect(out, isNot(contains('javascript:')));
      expect(out, isNot(contains('<style')));
      // The honest text of the click-handler paragraph survives.
      expect(out, contains('honest text'));
      // Dead link keeps its text but loses the href.
      expect(out, contains('this dead link'));
      expect(out, isNot(contains('void(0)')));
      expect(out, contains('<a href="https://example.org/extra">'));
    });

    test('&nbsp; entities become literal characters, not named entities', () {
      expect(out, isNot(contains('&nbsp;')));
      expect(out, contains('\u00A0'));
      expect(out, isNot(contains('&copy;')));
    });

    test('lists preserved as real ul/ol with correct items', () {
      expect(out, contains('<ul>'));
      expect(out, contains('<ol>'));
      expect(out, contains('<li>First bullet item</li>'));
      expect(out, contains('<li>Second bullet item</li>'));
      expect(out, contains('<li>Third ordered item</li>'));
      final count = '<li>'.allMatches(out).length;
      expect(count, 5);
    });

    test('images rewritten through resolveImage, placeholder when unresolved', () {
      expect(out, contains('<img src="../images/img-7.png" alt="Chapter chart placeholder"/>'));
      expect(unresolved, isNot(contains('<img')));
      expect(unresolved, contains('image-placeholder'));
      expect(unresolved, contains('Chapter chart placeholder'));
      expect(unresolved, contains('https://example.com/images/chapter-chart.png'));
    });

    test('author note and announcement become asides', () {
      expect(out, contains('<aside class="author-note">'));
      expect(out, contains('Author: Placeholder Person'));
      expect(out, contains('Please rate and review this sample text.'));
      expect(out, contains('<aside class="announcement">'));
      expect(out, contains('Lorem news update'));
      expect(out, contains('News body lorem ipsum.'));
    });

    test('spoiler body rendered visibly with a Spoiler label', () {
      expect(out, contains('<aside class="spoiler">'));
      expect(out, contains('<p class="spoiler-label">Spoiler</p>'));
      expect(out, contains('The butler did it'));
      expect(out, isNot(contains('Click Me')));
    });

    test('footnotes become noteref markers + end-of-chapter asides', () {
      expect(out, contains('epub:type="noteref"'));
      expect(out, contains('href="#fn-1"'));
      expect(out, contains('href="#fn-2"'));
      expect(out, contains('<section epub:type="footnotes">'));
      expect(out, contains('<aside epub:type="footnote" id="fn-1">'));
      expect(out, contains('Supporting note about the lorem text.'));
      expect(out, contains('Second supporting note, older markup.'));
    });

    test('inline formatting and allowed styles preserved', () {
      expect(out, contains('<b>bold</b>'));
      expect(out, contains('<strong>strong</strong>'));
      expect(out, contains('<i>italic</i>'));
      expect(out, contains('<em>cursive</em>'));
      expect(out, contains('<u>underlined</u>'));
      expect(out, contains('<s>struck</s>'));
      expect(out, contains('<sup>superscript</sup>'));
      expect(out, contains('<sub>subscript</sub>'));
      expect(out, contains('<blockquote>'));
      expect(out, contains('<code>monospaced token</code>'));
      expect(out, contains('style="text-align: center; color: #ff0000; font-weight: bold"'));
    });
  });

  group('sanitizeHtmlToXhtml (RoyalRoad fixture)', () {
    late String out;

    setUpAll(() {
      out = sanitizeHtmlToXhtml(rrFixture, resolveImage: (src) => '../images/img-9.webp');
    });

    test('well-formed', () {
      expectStrictXml(wrapFragment(out), label: 'RR sanitized');
    });

    test('styled table retained, author note becomes aside', () {
      expect(out, contains('<table class="conTable"'));
      expect(out, contains('width: 120px'));
      expect(out, contains('background-color: #111111'));
      expect(out, contains('color: #ffffff'));
      expect(out, contains('colspan="2"'));
      expect(out, contains('<aside class="author-note">'));
      expect(out, contains('thanks for reading the sample'));
      expect(out, contains('color: rgb(0, 128, 0)'));
      expect(out, contains('<img src="../images/img-9.webp"'));
    });
  });

  group('richTextToXhtml', () {
    test('fallback rendering of RichTextDocument.html(SH fixture)', () {
      final doc = RichTextDocument.html(html_parser.parseFragment(shFixture).nodes);
      final out = richTextToXhtml(doc, resolveImage: (id, url) => '../images/img-$id.png');
      expectStrictXml(wrapFragment(out), label: 'richText from SH');
      // formatting survives the lossy store (addSpacing may prefix spaces)
      expect(out, contains('<strong>'));
      expect(out, contains('strong</strong>'));
      expect(out, contains('<em>'));
      // tables keep spans
      expect(out, contains('<table>'));
      expect(out, contains('colspan="3"'));
      expect(out, contains('rowspan="2"'));
      // notes/announcements are asides
      expect(out, contains('<aside class="author-note">'));
      expect(out, contains('Please rate and review this sample text.'));
      expect(out, contains('<aside class="announcement">'));
      // flattened lists render as stored ("●" bullets)
      expect(out, contains('●'));
      // images routed through resolveImage
      expect(out, contains('<img src="../images/img-'));
    });

    test('hand-built document: dividers, links, code, footnote refs', () {
      final doc = RichTextDocument(
        [RichTextSpan([RichTextText('A supporting note.')])],
        [
          RichTextParagraph([
            RichTextText('Body says '),
            RichTextBold([RichTextText('loud')]),
            RichTextText(' stuff'),
            RichTextFootnoteReference(0),
          ]),
          RichTextDivider(),
          RichTextCodeBlock([RichTextText('code & <raw>')]),
          RichTextParagraph([
            RichTextLink([RichTextText('http site')], 'https://example.com/x'),
            RichTextLink([RichTextText('bad site')], 'javascript:alert(1)'),
            RichTextBreak(),
            RichTextImage(11, 'https://example.com/i.png'),
          ]),
        ],
      );
      final out = richTextToXhtml(doc, resolveImage: (id, url) => '../images/img-$id.png');
      expectStrictXml(wrapFragment(out), label: 'richText hand-built');
      expect(out, contains('<sup class="footnote-ref" id="fnref-1"><a epub:type="noteref" href="#fn-1">[1]</a></sup>'));
      expect(out, contains('<aside epub:type="footnote" id="fn-1">'));
      expect(out, contains('A supporting note.'));
      expect(out, contains('<hr/>'));
      expect(out, contains('<pre>code &amp; &lt;raw&gt;</pre>'));
      expect(out, contains('<a href="https://example.com/x">http site</a>'));
      expect(out, isNot(contains('javascript:')));
      expect(out, contains('<img src="../images/img-11.png"'));
      expect(out, contains('<br/>'));
      final unresolved = richTextToXhtml(doc);
      expect(unresolved, isNot(contains('<img')));
      expect(unresolved, contains('image-placeholder'));
    });
  });

  group('buildEpub', () {
    late EpubBook book;
    late Uint8List bytes;
    late Archive archive;
    late String opf;

    setUpAll(() {
      final shBody = sanitizeHtmlToXhtml(shFixture,
          resolveImage: (src) => src.contains('chapter-chart') ? '../images/img-7.png' : null);
      final rrBody = sanitizeHtmlToXhtml(rrFixture, resolveImage: (src) => null);
      final rtBody = richTextToXhtml(
          RichTextDocument.html(html_parser.parseFragment(rrFixture).nodes),
          resolveImage: (id, url) => '../images/img-9.png');
      book = EpubBook(
        title: 'The & <Great> Book',
        author: 'Lorem Ipsum',
        identifier: 'urn:storyreader:scribblehub:623932:1-3',
        description: 'Test & validation book.',
        cover: pngBytes,
        modified: DateTime.utc(2026, 10, 26, 12, 0, 0),
        chapters: [
          EpubChapter('Chapter & One <Draft>', shBody),
          EpubChapter('Chapter Two', rrBody),
          EpubChapter('Chapter Three', rtBody),
        ],
        images: [
          EpubImage('img-7', pngBytes),
          EpubImage('img-9', pngBytes),
          // Undetectable type: must be dropped.
          EpubImage('img-bad', Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])),
        ],
      );
      bytes = buildEpub(book);
      archive = ZipDecoder().decodeBytes(bytes);
      opf = utf8.decode(archive.find('OEBPS/content.opf')!.readBytes()!);
    });

    test('mimetype is the first entry, stored, byte-exact', () {
      final files = archive.files.toList();
      expect(files.first.name, 'mimetype');
      expect(files.first.isCompressed, isFalse);
      expect(files.first.compression, CompressionType.none);
      expect(utf8.decode(files.first.readBytes()!), 'application/epub+zip');
      // And literally first in the raw zip: local header + stored method.
      expect(bytes.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04]);
      final method = bytes[8] | (bytes[9] << 8);
      expect(method, 0);
      expect(bytes.sublist(30, 38), utf8.encode('mimetype'));
      expect(bytes.sublist(38, 58), utf8.encode('application/epub+zip'));
    });

    test('every manifest item exists in the zip; images present; bad one dropped', () {
      final names = archive.files.map((f) => f.name).toSet();
      expect(names, containsAll(['META-INF/container.xml', 'OEBPS/content.opf',
          'OEBPS/nav.xhtml', 'OEBPS/toc.ncx', 'OEBPS/style.css',
          'OEBPS/text/ch-0001.xhtml', 'OEBPS/text/ch-0002.xhtml', 'OEBPS/text/ch-0003.xhtml',
          'OEBPS/images/img-7.png', 'OEBPS/images/img-9.png', 'OEBPS/images/cover.png']));
      expect(names.any((n) => n.contains('img-bad')), isFalse);
      expect(opf, isNot(contains('img-bad')));

      final hrefs = RegExp(r'<item [^>]*href="([^"]+)"').allMatches(opf).map((m) => m.group(1)!).toList();
      for (final href in hrefs) {
        expect(names, contains('OEBPS/$href'), reason: 'manifest item OEBPS/$href missing from zip');
      }
      expect(opf, contains('properties="cover-image"'));
      expect(opf, contains('media-type="image/png"'));
    });

    test('spine order matches chapter order; nav lists all chapters', () {
      final ids = RegExp(r'<itemref idref="([^"]+)"').allMatches(opf).map((m) => m.group(1)!).toList();
      final itemHref = {
        for (final m in RegExp(r'<item id="([^"]+)" href="([^"]+)"').allMatches(opf)) m.group(1)!: m.group(2)!,
      };
      expect(ids, ['ch-0001', 'ch-0002', 'ch-0003']);
      expect(ids.map((i) => itemHref[i]), ['text/ch-0001.xhtml', 'text/ch-0002.xhtml', 'text/ch-0003.xhtml']);

      final nav = utf8.decode(archive.find('OEBPS/nav.xhtml')!.readBytes()!);
      expect(nav, contains('epub:type="toc"'));
      expect(nav, contains('text/ch-0001.xhtml'));
      expect(nav, contains('text/ch-0002.xhtml'));
      expect(nav, contains('text/ch-0003.xhtml'));
      // Titles escaped, not broken XML
      expect(nav, contains('Chapter &amp; One &lt;Draft&gt;'));
      final ncx = utf8.decode(archive.find('OEBPS/toc.ncx')!.readBytes()!);
      expect(ncx, contains('playOrder="3"'));
      expect(ncx, contains('urn:storyreader:scribblehub:623932:1-3'));
    });

    test('all XML parts are well-formed; OPF metadata correct', () {
      for (final name in ['META-INF/container.xml', 'OEBPS/content.opf', 'OEBPS/nav.xhtml',
        'OEBPS/toc.ncx', 'OEBPS/text/ch-0001.xhtml', 'OEBPS/text/ch-0002.xhtml',
        'OEBPS/text/ch-0003.xhtml']) {
        expectStrictXml(utf8.decode(archive.find(name)!.readBytes()!), label: name);
      }
      expect(opf, contains('version="3.0"'));
      expect(opf, contains('<dc:identifier id="pub-id">urn:storyreader:scribblehub:623932:1-3</dc:identifier>'));
      expect(opf, contains('<dc:title>The &amp; &lt;Great&gt; Book</dc:title>'));
      expect(opf, contains('<dc:creator id="creator">Lorem Ipsum</dc:creator>'));
      expect(opf, contains('<dc:language>en</dc:language>'));
      expect(opf, contains('<meta property="dcterms:modified">2026-10-26T12:00:00Z</meta>'));
    });

    test('chapter content retained end-to-end (tables/images/notes)', () {
      final ch1 = utf8.decode(archive.find('OEBPS/text/ch-0001.xhtml')!.readBytes()!);
      expect(ch1, contains('rowspan="2"'));
      expect(ch1, contains('<img src="../images/img-7.png"'));
      expect(ch1, contains('<aside class="author-note">'));
      expect(ch1, contains('xmlns:epub="http://www.idpf.org/2007/ops"'));
    });

    test('epubcheck validates the book (skipped when not on PATH)', () async {
      final tmp = Directory.systemTemp.createTempSync('epubcheck');
      final file = File('${tmp.path}/sample.epub');
      try {
        file.writeAsBytesSync(bytes);
        ProcessResult res;
        try {
          res = await Process.run('epubcheck', [file.path], runInShell: true);
        } on ProcessException {
          markTestSkipped('epubcheck not on PATH — container validation skipped');
          return;
        }
        final out = '${res.stdout}\n${res.stderr}';
        printOnFailure('epubcheck output:\n$out');
        expect(out, isNot(contains('[FATAL]')));
        expect(out, isNot(matches(RegExp(r'^\s*Fatal', multiLine: true))));
        expect(out, isNot(matches(RegExp(r'\bERROR\b'))));
        expect(res.exitCode, 0, reason: 'epubcheck exit code:\n$out');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('100-chapter book builds in sane time', () {
      final sw = Stopwatch()..start();
      final big = EpubBook(
        title: 'Big Book',
        author: 'Lorem',
        identifier: 'urn:storyreader:scribblehub:623932:1-100',
        modified: DateTime.utc(2026, 10, 26),
        chapters: [
          for (var i = 1; i <= 100; i++)
            EpubChapter('Chapter $i', '<p>Body paragraph $i with <b>emphasis</b>.</p>')
        ],
        images: [EpubImage('img-cover', pngBytes)],
      );
      final bigBytes = buildEpub(big);
      sw.stop();
      final bigArchive = ZipDecoder().decodeBytes(bigBytes);
      expect(bigArchive.files.where((f) => f.name.startsWith('OEBPS/text/')), hasLength(100));
      final nav = utf8.decode(bigArchive.find('OEBPS/nav.xhtml')!.readBytes()!);
      expect('<li>'.allMatches(nav).length, 100);
      expect(sw.elapsedMilliseconds, lessThan(5000),
          reason: 'building 100 chapters took ${sw.elapsedMilliseconds} ms');
    });
  });
}
