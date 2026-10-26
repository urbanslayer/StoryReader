/// Render the stored [RichTextDocument] (the lossy in-app chapter format) to
/// a well-formed XHTML body fragment — the fallback path for chapters with no
/// raw HTML. Lists are already flattened into text spans by the stored format
/// ("●" / "0."), so they are emitted verbatim inside paragraphs.
library;

import '../rich_text_tree.dart';
import 'xhtml_util.dart';

bool _producesBlock(RichTextElement e) {
  switch (e) {
    case RichTextParagraph():
    case RichTextTable():
    case RichTextAnnouncement():
    case RichTextAuthorNote():
    case RichTextCodeBlock():
    case RichTextDivider():
      return true;
    case RichTextSpan():
      return e.children.any(_producesBlock);
    default:
      return false;
  }
}

class _Renderer {
  final String? Function(int imageId, String url)? resolveImage;
  final int footnoteCount;

  _Renderer(this.resolveImage, this.footnoteCount);

  String footnoteRef(int index) {
    if (index < 0 || index >= footnoteCount) {
      return escapeXmlText('[${index + 1}]');
    }
    final n = index + 1;
    return '<sup class="footnote-ref" id="fnref-$n"><a epub:type="noteref" href="#fn-$n">[$n]</a></sup>';
  }

  String image(RichTextImage img) {
    final href = resolveImage?.call(img.image, img.url);
    if (href != null && href.isNotEmpty) {
      return '<img src="${escapeXmlAttr(href)}" alt="${escapeXmlAttr(img.url)}"/>';
    }
    final uri = Uri.tryParse(img.url);
    final linkable = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (linkable) {
      return '<span class="image-placeholder">[Image: <a href="${escapeXmlAttr(uri.toString())}">${escapeXmlText(img.url)}</a>]</span>';
    }
    return '<span class="image-placeholder">[Image: ${escapeXmlText(img.url.isEmpty ? 'unavailable' : img.url)}]</span>';
  }

  String inline(RichTextElement e) {
    switch (e) {
      case RichTextText():
        return escapeXmlText(e.content);
      case RichTextSpan():
        return e.children.map(inline).join();
      case RichTextBold():
        return '<strong>${e.children.map(inline).join()}</strong>';
      case RichTextCursive():
        return '<em>${e.children.map(inline).join()}</em>';
      case RichTextLink():
        final inner = e.children.map(inline).join();
        final uri = Uri.tryParse(e.url);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return inner;
        }
        return '<a href="${escapeXmlAttr(uri.toString())}">$inner</a>';
      case RichTextBreak():
        return '<br/>';
      case RichTextImage():
        return image(e);
      case RichTextFootnoteReference():
        return footnoteRef(e.footnote);
      case RichTextCodeBlock():
        return '<code>${e.children.map(inline).join()}</code>';
      case RichTextDivider():
        return '<hr/>';
      case RichTextParagraph():
        // Nested paragraph: flatten (the stored format can produce these).
        return e.children.map(inline).join();
      default:
        // Block-ish element reached in inline position: flatten children.
        return e.getChildren().map(inline).join();
    }
  }

  void block(RichTextElement e, StringBuffer sb) {
    switch (e) {
      case RichTextParagraph():
        if (e.children.any(_producesBlock)) {
          // Paragraphs cannot hold block content in XHTML: split into a run
          // of paragraphs around each block child.
          final run = <RichTextElement>[];
          void flush() {
            if (run.isEmpty) return;
            final inner = run.map(inline).join();
            if (inner.trim().isNotEmpty) sb.write('<p>$inner</p>');
            run.clear();
          }

          for (final c in e.children) {
            if (_producesBlock(c)) {
              flush();
              block(c, sb);
            } else {
              run.add(c);
            }
          }
          flush();
        } else {
          final inner = e.children.map(inline).join();
          sb.write('<p>$inner</p>');
        }
      case RichTextSpan():
        for (final c in e.children) {
          if (_producesBlock(c)) {
            block(c, sb);
          } else {
            final inner = inline(c);
            if (inner.trim().isNotEmpty) sb.write('<p>$inner</p>');
          }
        }
      case RichTextCodeBlock():
        sb.write('<pre>${e.children.map(inline).join()}</pre>');
      case RichTextDivider():
        sb.write('<hr/>');
      case RichTextBreak():
        sb.write('<p><br/></p>');
      case RichTextImage():
        sb.write('<p class="image">${image(e)}</p>');
      case RichTextAnnouncement():
        sb.write('<aside class="announcement">');
        if (e.title.trim().isNotEmpty) {
          sb.write('<p class="announcement-title">${escapeXmlText(e.title.trim())}</p>');
        }
        for (final c in e.children) {
          block(c, sb);
        }
        sb.write('</aside>');
      case RichTextAuthorNote():
        sb.write('<aside class="author-note">');
        for (final c in e.children) {
          block(c, sb);
        }
        sb.write('</aside>');
      case RichTextTable():
        sb.write(_table(e));
      case RichTextLink():
        sb.write('<p>${inline(e)}</p>');
      default:
        final inner = inline(e);
        if (inner.trim().isNotEmpty) sb.write('<p>$inner</p>');
    }
  }

  /// Rebuild a table grid from the stored flat cell list (row, col, rowSpan,
  /// colSpan per cell). Cells occupy a rectangle; later rows skip columns
  /// covered by rowspans from above, mirroring the original DOM layout.
  String _table(RichTextTable t) {
    if (t.cells.isEmpty) return '<table><tbody></tbody></table>';
    final byRow = <int, List<RichTextTableCell>>{};
    var maxRow = 0;
    for (final c in t.cells) {
      byRow.putIfAbsent(c.row, () => []).add(c);
      if (c.row > maxRow) maxRow = c.row;
    }
    final starts = <String, RichTextTableCell>{};
    final covered = <String>{};
    var maxCol = 0;
    for (var r = 0; r <= maxRow; r++) {
      final cells = byRow[r];
      if (cells == null) continue;
      final sorted = [...cells]..sort((a, b) => a.col.compareTo(b.col));
      var next = 0;
      bool free(int col) => !covered.contains('$r:$col');

      for (final c in sorted) {
        while (!free(next)) {
          next++;
        }
        final rs = c.rowSpan < 1 ? 1 : c.rowSpan;
        final cs = c.colSpan < 1 ? 1 : c.colSpan;
        starts['$r:$next'] = c;
        for (var rr = r; rr < r + rs; rr++) {
          for (var cc = next; cc < next + cs; cc++) {
            covered.add('$rr:$cc');
          }
        }
        next += cs;
        if (next > maxCol) maxCol = next;
      }
    }
    final sb = StringBuffer('<table><tbody>');
    for (var r = 0; r <= maxRow; r++) {
      sb.write('<tr>');
      var c = 0;
      while (c < maxCol) {
        final key = '$r:$c';
        if (!covered.contains(key)) {
          c++;
          continue;
        }
        final cell = starts[key];
        if (cell == null) {
          c++;
          continue; // covered by a rowspan from above
        }
        final rs = cell.rowSpan < 1 ? 1 : cell.rowSpan;
        final cs = cell.colSpan < 1 ? 1 : cell.colSpan;
        sb.write('<td${rs > 1 ? ' rowspan="$rs"' : ''}${cs > 1 ? ' colspan="$cs"' : ''}>');
        block(cell.child, sb);
        sb.write('</td>');
        c += cs;
      }
      sb.write('</tr>');
    }
    sb.write('</tbody></table>');
    return sb.toString();
  }
}

/// Render a stored [RichTextDocument] to an XHTML body fragment.
///
/// [resolveImage] receives the stored global image id and source url and
/// returns the in-book href (e.g. `../images/img-12.png`) or `null` to emit
/// an alt-text/link placeholder instead of a broken `<img>`.
///
/// Footnote references become `<sup><a epub:type="noteref" href="#fn-N">`;
/// the document's footnotes are emitted as
/// `<aside epub:type="footnote" id="fn-N">` asides in a
/// `<section epub:type="footnotes">` appended at the end of the fragment.
String richTextToXhtml(RichTextDocument doc,
    {String? Function(int imageId, String url)? resolveImage}) {
  final renderer = _Renderer(resolveImage, doc.footnotes.length);
  final sb = StringBuffer();
  for (final e in doc.document) {
    renderer.block(e, sb);
  }
  if (doc.footnotes.isNotEmpty) {
    sb.write('<section epub:type="footnotes">');
    for (var i = 0; i < doc.footnotes.length; i++) {
      final n = i + 1;
      final noteSb = StringBuffer();
      renderer.block(doc.footnotes[i], noteSb);
      sb.write(
        '<aside epub:type="footnote" id="fn-$n">$noteSb'
        '<p class="footnote-backref"><a href="#fnref-$n">[back]</a></p></aside>',
      );
    }
    sb.write('</section>');
  }
  return sb.toString();
}
