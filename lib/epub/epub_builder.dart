/// Pure-Dart EPUB 3 container builder. No flutter, no drift, no network.
///
/// [buildEpub] serializes an [EpubBook] into an EPUB 3 zip:
/// `mimetype` (stored, first), `META-INF/container.xml`,
/// `OEBPS/content.opf`, `OEBPS/nav.xhtml`, `OEBPS/toc.ncx`, `OEBPS/style.css`,
/// `OEBPS/text/ch-0001.xhtml` … and `OEBPS/images/<key>.<ext>`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'xhtml_util.dart' show escapeXmlText, escapeXmlAttr;

/// A binary image to bundle. [key] is the stable in-book id, e.g.
/// `img-<chapterImages.id>`; the file lands at `OEBPS/images/<key>.<ext>`
/// with the extension sniffed from the bytes.
class EpubImage {
  final String key;
  final Uint8List bytes;
  const EpubImage(this.key, this.bytes);
}

/// One spine chapter. [xhtmlBody] must already be a sanitized, well-formed
/// XHTML body fragment (see `sanitizeHtmlToXhtml` / `richTextToXhtml`).
class EpubChapter {
  final String title;
  final String xhtmlBody;
  const EpubChapter(this.title, this.xhtmlBody);
}

/// The full book description handed to [buildEpub].
class EpubBook {
  final String title;
  final String author;
  final String language;

  /// e.g. `urn:storyreader:scribblehub:623932:<first>-<last>`
  final String identifier;
  final String? description;

  /// Optional cover image bytes (media type sniffed).
  final Uint8List? cover;
  final DateTime modified;
  final List<EpubChapter> chapters;
  final List<EpubImage> images;

  const EpubBook({
    required this.title,
    required this.author,
    required this.identifier,
    this.language = 'en',
    this.description,
    this.cover,
    required this.modified,
    this.chapters = const [],
    this.images = const [],
  });
}

const String _mimetype = 'application/epub+zip';

const Map<String, String> _mediaExtensions = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/svg+xml': 'svg',
};

/// Sniff an image's media type from its magic bytes.
///
/// Recognizes jpeg, png, gif, webp and svg. Anything else returns
/// `application/octet-stream`; [buildEpub] drops such images (callers should
/// also treat them as unresolvable in `resolveImage` so alt-text placeholders
/// are emitted instead of broken references).
String imageMediaType(Uint8List bytes) {
  bool startsWithBytes(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWithBytes([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWithBytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'image/png';
  if (startsWithBytes('GIF87a'.codeUnits) || startsWithBytes('GIF89a'.codeUnits)) {
    return 'image/gif';
  }
  if (startsWithBytes('RIFF'.codeUnits) &&
      bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  // SVG: textual; allow a BOM, whitespace and an XML prologue before <svg.
  if (bytes.isNotEmpty) {
    var start = 0;
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) start = 3;
    final head = String.fromCharCodes(bytes.sublist(start, bytes.length < start + 1024 ? bytes.length : start + 1024));
    var s = head.trimLeft();
    if (s.startsWith('<')) {
      // Skip prologue / comments / doctype.
      final re = RegExp(r'^(?:<\?xml[^>]*\?>|<!--.*?-->|<!DOCTYPE[^>]*>|\s)+', dotAll: true);
      s = s.replaceFirst(re, '');
      if (s.startsWith('<svg') || s.startsWith('<SVG')) return 'image/svg+xml';
    }
  }
  return 'application/octet-stream';
}

String _w3cdtf(DateTime d) {
  final u = d.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

String _lang(String l) => RegExp(r'^[A-Za-z0-9-]{1,35}$').hasMatch(l) ? l : 'en';

String _safeKey(String key) {
  final cleaned = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  return cleaned.isEmpty ? 'image' : cleaned;
}

String _safeId(String key) {
  final cleaned = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
  if (cleaned.isEmpty || RegExp(r'^[0-9]').hasMatch(cleaned)) return 'i-$cleaned';
  return cleaned;
}

const String _styleCss = '''
body {
  margin: 1em 1.5em;
  line-height: 1.5;
}
h1.chapter-title {
  margin: 0 0 1em;
  font-size: 1.4em;
}
p {
  margin: 0 0 0.8em;
}
blockquote {
  margin: 0.8em 1.5em;
  padding-left: 0.8em;
  border-left: 2px solid #888888;
}
pre {
  margin: 0.8em 0;
  padding: 0.6em;
  font-family: monospace;
  font-size: 0.9em;
  white-space: pre-wrap;
  border: 1px solid #cccccc;
  overflow-wrap: break-word;
}
code {
  font-family: monospace;
}
table {
  border-collapse: collapse;
  margin: 0.8em 0;
}
th, td {
  border: 1px solid #444444;
  padding: 2px 6px;
  vertical-align: top;
}
th {
  background-color: #e8e8e8;
}
img {
  max-width: 100%;
  height: auto;
}
figure {
  margin: 0.8em 0;
}
aside.author-note {
  margin: 1.2em 0;
  padding: 0.6em 0.9em;
  border: 1px solid #999999;
  border-radius: 4px;
  background-color: #f5f5f5;
}
p.author-note-title, p.announcement-title {
  font-weight: bold;
}
aside.announcement {
  margin: 1.2em 0;
  padding: 0.6em 0.9em;
  border: 1px solid #666699;
  background-color: #eef;
}
aside.spoiler {
  margin: 1.2em 0;
  padding: 0.6em 0.9em;
  border: 1px dashed #999999;
}
p.spoiler-label {
  font-weight: bold;
  font-style: italic;
  margin: 0 0 0.4em;
}
span.image-placeholder {
  font-style: italic;
  color: #666666;
}
section[epub\\|type="footnotes"] {
  margin-top: 2em;
  border-top: 1px solid #cccccc;
}
aside.footnote, section.footnotes aside {
  margin: 0.6em 0;
  font-size: 0.9em;
}
p.footnote-backref {
  margin: 0;
}
''';

class _ManifestItem {
  final String id;
  final String href;
  final String mediaType;
  final String? properties;
  const _ManifestItem(this.id, this.href, this.mediaType, [this.properties]);
}

Uint8List _xhtmlPage({
  required String lang,
  required String title,
  required String body,
  String styleHref = '../style.css',
}) {
  final sb = StringBuffer();
  sb.write('<?xml version="1.0" encoding="utf-8"?>\n');
  sb.write('<!DOCTYPE html>\n');
  sb.write('<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="${escapeXmlAttr(lang)}" lang="${escapeXmlAttr(lang)}">\n');
  sb.write('<head><title>${escapeXmlText(title)}</title>');
  sb.write('<link rel="stylesheet" type="text/css" href="$styleHref"/>');
  sb.write('</head>\n<body>\n');
  sb.write(body);
  sb.write('\n</body>\n</html>\n');
  return Uint8List.fromList(utf8.encode(sb.toString()));
}

/// Serialize [book] into EPUB 3 zip bytes.
Uint8List buildEpub(EpubBook book) {
  final lang = _lang(book.language);
  final modified = book.modified;
  final entries = <String, Uint8List>{}; // zip name → bytes (insertion order)
  final storedNames = <String>{};
  final manifest = <_ManifestItem>[];

  var lastMod = modified.toUtc().millisecondsSinceEpoch ~/ 1000;
  if (lastMod < 315532800) lastMod = 315532800; // zip epoch: 1980-01-01

  void addFile(String name, Uint8List bytes, {bool store = false}) {
    entries[name] = bytes;
    if (store) storedNames.add(name);
  }

  // 1. mimetype: FIRST entry, STORED, exact bytes.
  addFile('mimetype', Uint8List.fromList(utf8.encode(_mimetype)), store: true);

  // 2. META-INF/container.xml
  addFile(
    'META-INF/container.xml',
    Uint8List.fromList(utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles>\n'
      '</container>\n',
    )),
  );

  // 3. Chapters.
  final spineItems = <_ManifestItem>[];
  for (var i = 0; i < book.chapters.length; i++) {
    final ch = book.chapters[i];
    final num = (i + 1).toString().padLeft(4, '0');
    final file = 'text/ch-$num.xhtml';
    final body = '<h1 class="chapter-title">${escapeXmlText(ch.title)}</h1>\n${ch.xhtmlBody}';
    addFile(file, _xhtmlPage(lang: lang, title: ch.title, body: body));
    final item = _ManifestItem('ch-$num', file, 'application/xhtml+xml');
    manifest.add(item);
    spineItems.add(item);
  }

  // 4. Cover.
  if (book.cover != null && book.cover!.isNotEmpty) {
    final media = imageMediaType(book.cover!);
    final ext = _mediaExtensions[media];
    if (ext != null) {
      const file = 'images/cover';
      addFile('$file.$ext', book.cover!);
      manifest.add(_ManifestItem('cover-image', '$file.$ext', media, 'cover-image'));
    }
  }

  // 5. Images (dedupe by key, drop undetectable types).
  final seenKeys = <String>{};
  for (final img in book.images) {
    final key = _safeKey(img.key);
    if (!seenKeys.add(key)) continue;
    final media = imageMediaType(img.bytes);
    final ext = _mediaExtensions[media];
    if (ext == null) continue; // application/octet-stream → dropped
    final file = 'images/$key.$ext';
    addFile(file, img.bytes);
    manifest.add(_ManifestItem(_safeId(key), file, media));
  }

  // 6. style.css
  manifest.add(const _ManifestItem('css', 'style.css', 'text/css'));
  addFile('style.css', Uint8List.fromList(utf8.encode(_styleCss)));

  // 7. nav.xhtml (EPUB 3).
  final navSb = StringBuffer();
  navSb.write('<nav epub:type="toc" id="toc">\n<h1>Table of Contents</h1>\n<ol>\n');
  for (var i = 0; i < spineItems.length; i++) {
    final item = spineItems[i];
    navSb.write('<li><a href="${escapeXmlAttr(item.href)}">${escapeXmlText(book.chapters[i].title)}</a></li>\n');
  }
  navSb.write('</ol>\n</nav>\n');
  manifest.insert(0, const _ManifestItem('nav', 'nav.xhtml', 'application/xhtml+xml', 'nav'));
  addFile(
    'nav.xhtml',
    _xhtmlPage(lang: lang, title: 'Table of Contents', body: navSb.toString(), styleHref: 'style.css'),
  );

  // 8. toc.ncx (legacy readers).
  final ncxSb = StringBuffer();
  ncxSb.write('<?xml version="1.0" encoding="UTF-8"?>\n');
  ncxSb.write('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n');
  ncxSb.write('<head>\n'
      '<meta name="dtb:uid" content="${escapeXmlAttr(book.identifier)}"/>\n'
      '<meta name="dtb:depth" content="1"/>\n'
      '<meta name="dtb:totalPageCount" content="0"/>\n'
      '<meta name="dtb:maxPageNumber" content="0"/>\n'
      '</head>\n');
  ncxSb.write('<docTitle><text>${escapeXmlText(book.title)}</text></docTitle>\n');
  ncxSb.write('<navMap>\n');
  for (var i = 0; i < spineItems.length; i++) {
    final item = spineItems[i];
    ncxSb.write('<navPoint id="np-${i + 1}" playOrder="${i + 1}">'
        '<navLabel><text>${escapeXmlText(book.chapters[i].title)}</text></navLabel>'
        '<content src="${escapeXmlAttr(item.href)}"/></navPoint>\n');
  }
  ncxSb.write('</navMap>\n</ncx>\n');
  manifest.insert(1, const _ManifestItem('ncx', 'toc.ncx', 'application/x-dtbncx+xml'));
  addFile('toc.ncx', Uint8List.fromList(utf8.encode(ncxSb.toString())));

  // 9. content.opf.
  final opf = StringBuffer();
  opf.write('<?xml version="1.0" encoding="utf-8"?>\n');
  opf.write('<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="pub-id" xml:lang="${escapeXmlAttr(lang)}">\n');
  opf.write('<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n');
  opf.write('<dc:identifier id="pub-id">${escapeXmlText(book.identifier)}</dc:identifier>\n');
  opf.write('<dc:title>${escapeXmlText(book.title)}</dc:title>\n');
  if (book.author.trim().isNotEmpty) {
    opf.write('<dc:creator id="creator">${escapeXmlText(book.author.trim())}</dc:creator>\n');
  }
  opf.write('<dc:language>${escapeXmlText(lang)}</dc:language>\n');
  if (book.description != null && book.description!.trim().isNotEmpty) {
    opf.write('<dc:description>${escapeXmlText(book.description!.trim())}</dc:description>\n');
  }
  opf.write('<dc:date>${_w3cdtf(modified)}</dc:date>\n');
  opf.write('<meta property="dcterms:modified">${_w3cdtf(modified)}</meta>\n');
  opf.write('</metadata>\n<manifest>\n');
  for (final item in manifest) {
    opf.write('<item id="${escapeXmlAttr(item.id)}" href="${escapeXmlAttr(item.href)}" '
        'media-type="${escapeXmlAttr(item.mediaType)}"'
        '${item.properties != null ? ' properties="${escapeXmlAttr(item.properties!)}"' : ''}/>\n');
  }
  opf.write('</manifest>\n<spine toc="ncx">\n');
  for (final item in spineItems) {
    opf.write('<itemref idref="${escapeXmlAttr(item.id)}"/>\n');
  }
  opf.write('</spine>\n</package>\n');
  addFile('content.opf', Uint8List.fromList(utf8.encode(opf.toString())));

  // Zip it: mimetype + container keep their names, everything else lives
  // under OEBPS/. Insertion order above guarantees mimetype is first.
  final zip = Archive();
  entries.forEach((name, bytes) {
    final zipName = (name == 'mimetype' || name.startsWith('META-INF/')) ? name : 'OEBPS/$name';
    final af = ArchiveFile(zipName, bytes.length, bytes);
    af.lastModTime = lastMod;
    if (storedNames.contains(name)) af.compression = CompressionType.none;
    zip.add(af);
  });
  return ZipEncoder().encodeBytes(zip);
}
