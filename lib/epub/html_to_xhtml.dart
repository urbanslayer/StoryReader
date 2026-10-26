/// Sanitize untrusted site HTML (ScribbleHub / RoyalRoad chapter fragments)
/// into well-formed XHTML fragments fit for an EPUB spine.
///
/// Pure Dart: depends only on `package:html` for parsing. No network, no
/// flutter, no drift. [sanitizeHtmlToXhtml] is the public entry point.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'xhtml_util.dart';

/// Elements removed together with everything they contain.
const Set<String> _dropEntirely = {
  'script',
  'style',
  'iframe',
  'form',
  'input',
  'button',
  'noscript',
  'object',
  'embed',
  'applet',
  'audio',
  'video',
  'source',
  'track',
  'canvas',
  'map',
  'area',
  'select',
  'option',
  'optgroup',
  'textarea',
  'fieldset',
  'legend',
  'label',
  'link',
  'meta',
  'base',
  'head',
  'title',
  'marquee',
  'blink',
};

/// Tags kept as-is (block).
const Set<String> _blockKeep = {
  'p',
  'blockquote',
  'pre',
  'code',
  'ul',
  'ol',
  'li',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'th',
  'td',
  'caption',
  'aside',
};

/// Tags kept as-is (inline).
const Set<String> _inlineKeep = {
  'b',
  'strong',
  'i',
  'em',
  'u',
  's',
  'del',
  'sup',
  'sub',
};

class _Sanitizer {
  final String? Function(String src)? resolveImage;
  final List<String> footnotes = [];

  _Sanitizer(this.resolveImage);

  String renderChildren(dom.NodeList nodes, {bool forceVisible = false}) {
    final sb = StringBuffer();
    for (final n in nodes) {
      sb.write(renderNode(n, forceVisible: forceVisible));
    }
    return sb.toString();
  }

  String renderNode(dom.Node node, {bool forceVisible = false}) {
    if (node is dom.Text) {
      return escapeXmlText(node.text);
    }
    if (node is dom.Comment) {
      return '';
    }
    if (node is! dom.Element) {
      return '';
    }

    final tag = (node.localName ?? 'div').toLowerCase();
    final classes = node.classes;

    // --- Site-specific structures (before generic rules so that footnote
    // --- content hidden by inline styles is still captured).
    if (tag == 'sup' && classes.contains('modern-footnotes-footnote')) {
      return _modernFootnote(node);
    }
    if (tag == 'span' && classes.contains('footnote') && !classes.contains('footnote-content')) {
      return _legacyFootnote(node);
    }
    if (classes.contains('sp-wrap') || classes.contains('spoiler-wrap')) {
      return _spoiler(node);
    }
    if (tag == 'div' && classes.contains('wi_authornotes')) {
      return _authorNoteSh(node);
    }
    if (tag == 'div' && classes.contains('author-note')) {
      return _authorNoteGeneric(node);
    }
    if ((tag == 'div' || tag == 'p') && classes.contains('wi_news')) {
      return _announcement(node);
    }

    // --- Unconditional drops.
    if (_dropEntirely.contains(tag)) {
      return '';
    }

    // --- Inline display:none content is dropped (RoyalRoad "hidden" blocks).
    if (!forceVisible && styleHasDisplayNone(node.attributes['style'])) {
      return '';
    }

    switch (tag) {
      case 'br':
        return '<br/>';
      case 'hr':
        return '<hr/>';
      case 'img':
        return _image(node);
      case 'a':
        return _anchor(node);
      case 'span':
      case 'div':
        return _spanOrDiv(node, tag);
      case 'font':
        return _font(node);
      case 'strike':
        return _wrap(node, 's');
      case 'ol':
        final start = int.tryParse(node.attributes['start'] ?? '');
        final startAttr = (start != null && start != 1) ? ' start="$start"' : '';
        return '<ol$startAttr${_baseAttrs(node, tag)}>${renderChildren(node.nodes)}</ol>';
      default:
        if (_blockKeep.contains(tag) || _inlineKeep.contains(tag)) {
          var extra = '';
          if (tag == 'td' || tag == 'th') {
            final cs = int.tryParse(node.attributes['colspan'] ?? '');
            final rs = int.tryParse(node.attributes['rowspan'] ?? '');
            if (cs != null && cs > 1) extra += ' colspan="$cs"';
            if (rs != null && rs > 1) extra += ' rowspan="$rs"';
          }
          return '<$tag$extra${_baseAttrs(node, tag)}>${renderChildren(node.nodes)}</$tag>';
        }
        // Structural or unknown container: keep the content, drop the tag.
        return renderChildren(node.nodes, forceVisible: forceVisible);
    }
  }

  String _baseAttrs(dom.Element e, String tag) {
    final style = filterStyle(
      e.attributes['style'],
      tag: tag,
      extraProps: legacyAttrStyles({
        for (final key in ['align', 'valign', 'bgcolor', 'width'])
          key: e.attributes[key],
      }, tag),
    );
    final classes = sanitizeClasses(e.attributes['class']);
    return styleClassAttrs(style, classes);
  }

  String _wrap(dom.Element e, String tag) {
    return '<$tag${_baseAttrs(e, tag)}>${renderChildren(e.nodes)}</$tag>';
  }

  String _spanOrDiv(dom.Element e, String tag) {
    final attrs = _baseAttrs(e, tag);
    if (attrs.trim().isEmpty) {
      // Nothing presentational to preserve: unwrap to keep the flow clean.
      return renderChildren(e.nodes);
    }
    return '<$tag$attrs>${renderChildren(e.nodes)}</$tag>';
  }

  String _font(dom.Element e) {
    final extra = <String, String>{};
    final color = e.attributes['color'];
    if (color != null && RegExp(r'^#?[0-9A-Fa-f]{3,8}$').hasMatch(color.trim())) {
      final v = color.trim();
      extra['color'] = v.startsWith('#') ? v : '#$v';
    }
    final style = filterStyle(e.attributes['style'], tag: 'span', extraProps: extra);
    final classes = sanitizeClasses(e.attributes['class']);
    final attrs = styleClassAttrs(style, classes);
    if (attrs.trim().isEmpty) return renderChildren(e.nodes);
    return '<span$attrs>${renderChildren(e.nodes)}</span>';
  }

  String _anchor(dom.Element e) {
    final inner = renderChildren(e.nodes);
    final raw = e.attributes['href']?.trim();
    final uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      // javascript:, relative, fragment or malformed links: keep the text.
      return inner;
    }
    final style = filterStyle(e.attributes['style'], tag: 'a');
    final classes = sanitizeClasses(e.attributes['class']);
    return '<a href="${escapeXmlAttr(uri.toString())}"${styleClassAttrs(style, classes)}>$inner</a>';
  }

  String _image(dom.Element e) {
    final src = (e.attributes['src'] ?? '').trim();
    final alt = (e.attributes['alt'] ?? e.attributes['title'] ?? '').trim();
    final href = src.isEmpty ? null : resolveImage?.call(src);
    if (href != null && href.isNotEmpty) {
      return '<img src="${escapeXmlAttr(href)}" alt="${escapeXmlAttr(alt)}"/>';
    }
    // Not available in the book: alt-text / link placeholder, never a
    // broken <img>.
    final label = alt.isNotEmpty ? alt : src;
    final uri = src.isEmpty ? null : Uri.tryParse(src);
    final linkable = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (linkable) {
      return '<span class="image-placeholder">[Image: <a href="${escapeXmlAttr(uri.toString())}">${escapeXmlText(label)}</a>]</span>';
    }
    return '<span class="image-placeholder">[Image: ${escapeXmlText(label.isEmpty ? 'unavailable' : label)}]</span>';
  }

  // --- ScribbleHub / RoyalRoad structures ----------------------------------

  String _footnoteMarker(String noteHtml) {
    footnotes.add(noteHtml);
    final n = footnotes.length;
    return '<sup class="footnote-ref" id="fnref-$n"><a epub:type="noteref" href="#fn-$n">[$n]</a></sup>';
  }

  String _modernFootnote(dom.Element e) {
    dom.Element? note;
    for (final c in e.children) {
      if (c.classes.contains('modern-footnotes-footnote__note')) {
        note = c;
        break;
      }
    }
    if (note == null) {
      // No note body: degrade to the marker text itself.
      return '<sup class="footnote-ref">${escapeXmlText(e.text.trim())}</sup>';
    }
    return _footnoteMarker(renderChildren(note.nodes, forceVisible: true));
  }

  String _legacyFootnote(dom.Element e) {
    dom.Element? note;
    for (final c in e.children) {
      if (c.classes.contains('footnote-content') || c.classes.contains('footnote-body')) {
        note = c;
        break;
      }
    }
    if (note == null) {
      return '<sup class="footnote-ref">${escapeXmlText(e.text.trim())}</sup>';
    }
    return _footnoteMarker(renderChildren(note.nodes, forceVisible: true));
  }

  String _spoiler(dom.Element e) {
    dom.Element? body;
    for (final c in e.children) {
      final cs = c.classes;
      if (cs.contains('sp-body') || cs.contains('spoiler-body')) {
        body = c;
        break;
      }
    }
    String inner;
    if (body != null) {
      inner = renderChildren(body.nodes);
    } else {
      // Drop the "Spoiler Show (Click Me)" header, keep everything else.
      final sb = StringBuffer();
      for (final c in e.nodes) {
        if (c is dom.Element) {
          final cs = c.classes;
          if (cs.contains('sp-head') || cs.contains('spoiler-head')) continue;
        }
        sb.write(renderNode(c));
      }
      inner = sb.toString();
    }
    return '<aside class="spoiler"><p class="spoiler-label">Spoiler</p>$inner</aside>';
  }

  String _authorNoteSh(dom.Element e) {
    dom.Element? title;
    dom.Element? body;
    for (final c in e.children) {
      if (title == null && c.classes.contains('wi_authornotes_title')) title = c;
      if (body == null && c.classes.contains('wi_authornotes_body')) body = c;
    }
    final sb = StringBuffer('<aside class="author-note">');
    if (title != null) {
      sb.write('<p class="author-note-title">${escapeXmlText(title.text.trim())}</p>');
    }
    sb.write(renderChildren((body ?? e).nodes));
    sb.write('</aside>');
    return sb.toString();
  }

  String _authorNoteGeneric(dom.Element e) {
    // RoyalRoad: <div class="author-note"> with arbitrary nesting.
    final sb = StringBuffer('<aside class="author-note">');
    for (final c in e.nodes) {
      if (c is dom.Element && c.classes.contains('author-note-header')) {
        sb.write('<p class="author-note-title">${escapeXmlText(c.text.trim())}</p>');
        continue;
      }
      sb.write(renderNode(c));
    }
    sb.write('</aside>');
    return sb.toString();
  }

  String _announcement(dom.Element e) {
    final sb = StringBuffer('<aside class="announcement">');
    if (e.children.length >= 2) {
      // ScribbleHub: first child is the head/date/title, second the body.
      sb.write('<p class="announcement-title">${escapeXmlText(e.children.first.text.trim())}</p>');
      sb.write(renderChildren(e.children[1].nodes));
    } else {
      sb.write(renderChildren(e.nodes));
    }
    sb.write('</aside>');
    return sb.toString();
  }
}

/// Sanitize an HTML chapter fragment into a well-formed XHTML body fragment.
///
/// Every `img` is routed through [resolveImage]: it receives the source `src`
/// and returns the in-book href (e.g. `../images/img-12.png`) when the image
/// is bundled, or `null` to emit an alt-text/link placeholder instead.
///
/// The result escapes all text, quotes attributes, self-closes void elements,
/// converts HTML named entities (e.g. `&nbsp;`) to literal characters, keeps
/// `rowspan`/`colspan` and the allow-listed inline styles, and drops scripts,
/// forms, event handlers, `javascript:` URLs and `display:none` content.
/// Footnotes discovered in the source are collected into a
/// `<section epub:type="footnotes">` block appended at the end of the
/// fragment, referenced by `<a epub:type="noteref">` markers.
String sanitizeHtmlToXhtml(String html, {String? Function(String src)? resolveImage}) {
  final fragment = html_parser.parseFragment(html);
  final sanitizer = _Sanitizer(resolveImage);
  final body = sanitizer.renderChildren(fragment.nodes);
  final sb = StringBuffer(body);
  if (sanitizer.footnotes.isNotEmpty) {
    sb.write('<section epub:type="footnotes">');
    for (var i = 0; i < sanitizer.footnotes.length; i++) {
      final n = i + 1;
      sb.write(
        '<aside epub:type="footnote" id="fn-$n">${sanitizer.footnotes[i]}'
        '<p class="footnote-backref"><a href="#fnref-$n">[back]</a></p></aside>',
      );
    }
    sb.write('</section>');
  }
  return sb.toString();
}
