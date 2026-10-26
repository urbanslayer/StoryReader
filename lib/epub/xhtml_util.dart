/// Internal shared helpers for the EPUB library: XML escaping and inline
/// CSS filtering. Not part of the public API surface.
library;

/// Characters XML cannot carry, even in UTF-8 documents.
final RegExp _illegalXmlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

/// Characters that are fine in text nodes but must be quoted in attributes.
String escapeXmlText(String s) {
  final cleaned = s.replaceAll(_illegalXmlChars, '');
  return cleaned.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

/// Escapes a string for use inside a double-quoted attribute value.
String escapeXmlAttr(String s) {
  final cleaned = s.replaceAll(_illegalXmlChars, '');
  return cleaned
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

/// Inline style properties the sanitizer keeps. `width` is further restricted
/// by the caller to table/td/th only.
const Set<String> _allowedStyleProps = {
  'text-align',
  'font-weight',
  'font-style',
  'text-decoration',
  'color',
  'background-color',
  'vertical-align',
};

/// Value must be plain: no url(), no expressions, no quotes/angles.
final RegExp _safeStyleValue = RegExp(r'^[A-Za-z0-9#%(),./ *+-]+$');

bool _isAllowedProp(String prop, String? tag) {
  if (prop == 'border-image' || prop == 'border-image-*') return false;
  if (prop == 'width') return tag == 'table' || tag == 'td' || tag == 'th';
  if (_allowedStyleProps.contains(prop)) return true;
  if (prop == 'border' || prop.startsWith('border-')) return true;
  if (prop == 'padding' || prop.startsWith('padding-')) return true;
  return false;
}

bool _isSafeValue(String value) {
  final lower = value.toLowerCase();
  if (lower.contains('url')) return false;
  if (lower.contains('expression')) return false;
  if (lower.contains('javascript')) return false;
  if (lower.contains('behavior')) return false;
  return _safeStyleValue.hasMatch(value);
}

/// Parse a `style` attribute and return only the allow-listed declarations,
/// or null when nothing survives. [extraProps] are already-sanitized
/// declarations contributed by legacy attributes (align/valign/bgcolor/width).
String? filterStyle(String? style, {String? tag, Map<String, String> extraProps = const {}}) {
  final out = <String, String>{};
  if (style != null) {
    for (final decl in style.split(';')) {
      final colon = decl.indexOf(':');
      if (colon <= 0) continue;
      final prop = decl.substring(0, colon).trim().toLowerCase();
      final value = decl.substring(colon + 1).trim();
      if (value.isEmpty || !_isAllowedProp(prop, tag) || !_isSafeValue(value)) continue;
      out[prop] = value;
    }
  }
  extraProps.forEach((prop, value) {
    if (!_isAllowedProp(prop, tag)) return;
    if (!_isSafeValue(value)) return;
    out.putIfAbsent(prop, () => value);
  });
  if (out.isEmpty) return null;
  return out.entries.map((e) => '${e.key}: ${e.value}').join('; ');
}

/// True when the style attribute sets `display: none` (or contains it among
/// multiple declarations).
bool styleHasDisplayNone(String? style) {
  if (style == null) return false;
  for (final decl in style.split(';')) {
    final colon = decl.indexOf(':');
    if (colon <= 0) continue;
    final prop = decl.substring(0, colon).trim().toLowerCase();
    final value = decl.substring(colon + 1).trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (prop == 'display' && value == 'none') return true;
  }
  return false;
}

/// Keep plain CSS class tokens (used for style hooks like `author-note`).
String? sanitizeClasses(String? classes) {
  if (classes == null) return null;
  final kept = classes
      .split(RegExp(r'\s+'))
      .where((c) => c.length <= 64 && RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$').hasMatch(c))
      .take(16)
      .toList();
  if (kept.isEmpty) return null;
  return kept.join(' ');
}

/// Turn a legacy HTML width value (`120` or `120px`) into a CSS px value.
String? normalizeWidthAttr(String? raw) {
  if (raw == null) return null;
  final v = raw.trim();
  if (RegExp(r'^\d+(\.\d+)?$').hasMatch(v)) return '${v}px';
  if (RegExp(r'^\d+(\.\d+)?px$').hasMatch(v)) return v;
  if (RegExp(r'^\d+(\.\d+)?%$').hasMatch(v)) return v;
  return null;
}

const Set<String> _legacyAlignValues = {'left', 'right', 'center', 'justify'};

/// Convert legacy presentational attributes (align/valign/bgcolor/width) to
/// the equivalent allow-listed inline style declarations.
Map<String, String> legacyAttrStyles(Map<String, String?> attrs, String tag) {
  final extra = <String, String>{};
  final align = attrs['align']?.trim().toLowerCase();
  if (align != null && _legacyAlignValues.contains(align)) {
    extra['text-align'] = align;
  }
  final valign = attrs['valign']?.trim().toLowerCase();
  if (valign != null && const {'top', 'middle', 'bottom', 'baseline'}.contains(valign)) {
    extra['vertical-align'] = valign;
  }
  final bgcolor = attrs['bgcolor'];
  if (bgcolor != null && RegExp(r'^#?[0-9A-Fa-f]{3,8}$').hasMatch(bgcolor.trim())) {
    final v = bgcolor.trim();
    extra['background-color'] = v.startsWith('#') ? v : '#$v';
  }
  if (tag == 'table' || tag == 'td' || tag == 'th') {
    final w = normalizeWidthAttr(attrs['width']);
    if (w != null) extra['width'] = w;
  }
  return extra;
}

/// Build the attribute string for `style` + `class` (both optional).
String styleClassAttrs(String? style, String? classes) {
  final sb = StringBuffer();
  if (style != null) sb.write(' style="${escapeXmlAttr(style)}"');
  if (classes != null) sb.write(' class="${escapeXmlAttr(classes)}"');
  return sb.toString();
}
