/// Pure-Dart parsing of a book's own chapter number out of a chapter title.
///
/// Deliberately conservative: only numbers at the very *start* of the title
/// (optionally after a leading keyword like "Chapter") are considered, so a
/// number buried in prose ("He Ran 578 Miles", "The Two Towers") never parses.
library;

/// A leading chapter keyword, e.g. "Chapter ", "Ch. ", "Chap. ".
final RegExp _leadingKeyword =
    RegExp(r'^(?:chapter|chap\.|ch\.)\s*#?\s*', caseSensitive: false);

/// Digits at the start of the (keyword-stripped) title, not glued to letters
/// (so "4th" does not match) and not longer than 4 digits.
final RegExp _leadingDigits = RegExp(r'^#?(\d{1,4})(?![0-9A-Za-z])');

/// Tokens allowed to trail a prefix-less word number before it is still
/// considered the chapter number (separators, e.g. "Twelve - Interlude").
final RegExp _separator = RegExp(r'^[:.,\-–—]');

final RegExp _wordToken = RegExp(r"[A-Za-z]+");

const Map<String, int> _ones = {
  'zero': 0,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
};

const Map<String, int> _tens = {
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
};

/// Parses the book's own chapter number from a chapter title, or null when the
/// title carries no parseable number.
///
/// Handles, e.g.: `Chapter 578 - Title`, `578: Title`, `578 - Title`,
/// `Five Hundred and Seventy-Eight`, `Chapter Twelve: Something`.
int? parseChapterNumber(String title) => _parseNumberWithEnd(title)?.$1;

/// A compact on-screen label for a chapter: "Chapter 721" when the book's own
/// number is known (preferring the stored [chapterNumber], falling back to
/// parsing [name]), otherwise the title itself.
String chapterShortLabel(String name, int? chapterNumber) {
  final n = chapterNumber ?? parseChapterNumber(name);
  return n == null ? name.trim() : 'Chapter $n';
}

/// The part of the title *after* the leading chapter number and separator,
/// e.g. "Contains Status- Ginneka 2, Eri 11?" for
/// "Seven Hundred And Twenty-One – Contains Status- Ginneka 2, Eri 11?".
///
/// Returns null when the title carries no parseable number or is *only* the
/// number. The split point must come from the title itself: a stored number
/// whose title no longer starts with it (renamed upstream) yields no subtitle.
String? chapterSubtitle(String name, int? chapterNumber) {
  final parsed = _parseNumberWithEnd(name);
  if (parsed == null) {
    return null;
  }
  var rest = name.trim().substring(parsed.$2).trim();
  if (rest.isEmpty) {
    return null;
  }
  final sep = _separator.matchAsPrefix(rest);
  if (sep != null) {
    rest = rest.substring(sep.end).trim();
  }
  return rest.isEmpty ? null : rest;
}

/// [parseChapterNumber] plus the character count of the trimmed title
/// consumed by the number (keyword + digits/words), so callers can find the
/// subtitle boundary. Returns `(value, endOffset)` or null.
(int, int)? _parseNumberWithEnd(String title) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final keyword = _leadingKeyword.matchAsPrefix(trimmed);
  final hasKeyword = keyword != null;
  final offset = keyword?.end ?? 0;
  final rest = trimmed.substring(offset);
  if (rest.isEmpty) {
    return null;
  }

  // Digits right at the front: "578: Title", "578 - Title", "Chapter 578".
  final digits = _leadingDigits.matchAsPrefix(rest);
  if (digits != null) {
    return (int.parse(digits.group(1)!), offset + digits.end);
  }

  // Word number at the front: "Five Hundred and Seventy-Eight",
  // "Chapter Twelve: Something". Hyphens act as token separators.
  final tokens = _wordToken.allMatches(rest).toList();
  final parsed = _parseWordNumber(tokens.map((m) => m[0]!.toLowerCase()).toList());
  if (parsed == null) {
    return null;
  }
  final (value, consumed) = parsed;
  if (consumed == 0) {
    return null;
  }

  if (!hasKeyword) {
    // Without a "Chapter" keyword the number must *be* the title, or be
    // followed only by a separator: "Twelve - Interlude" parses,
    // "Two Towers" or "A Hundred Years Later" do not.
    final tail = rest.substring(tokens[consumed - 1].end).trim();
    if (tail.isNotEmpty && !_separator.hasMatch(tail)) {
      return null;
    }
  }
  return (value, offset + tokens[consumed - 1].end);
}

/// Greedy word-number grammar for 0..9999:
/// `[<one> thousand] [[and] [<one> hundred]] [and] (<tens> [<one>] | <one>)`.
/// Thousand multipliers are limited to 1..9 (or "a"/"an"), so "Ten Thousand"
/// stays unparseable and the value can never leave 0..9999.
/// Returns `(value, tokensConsumed)` or null when no number starts the list.
(int, int)? _parseWordNumber(List<String> tokens) {
  int i = 0;
  int total = 0;
  bool any = false;

  // Words that may multiply a scale word: "a"/"an" (=1) or a unit number
  // up to [max] ("seven hundred" -> max 19 keeps "fifteen hundred" = 1500).
  bool isMultiplier(String t, int max) =>
      t == 'a' || t == 'an' || (_ones.containsKey(t) && _ones[t]! > 0 && _ones[t]! <= max);
  int multiplierValue(String t) => t == 'a' || t == 'an' ? 1 : _ones[t]!;

  // "<one> thousand" (or bare "thousand"): "Two Thousand",
  // "One Thousand and Twelve".
  if (i + 1 < tokens.length &&
      isMultiplier(tokens[i], 9) &&
      tokens[i + 1] == 'thousand') {
    total += multiplierValue(tokens[i]) * 1000;
    i += 2;
    any = true;
  } else if (i < tokens.length && tokens[i] == 'thousand') {
    total += 1000;
    i += 1;
    any = true;
  }

  if (any && i < tokens.length && tokens[i] == 'and') {
    i += 1; // "One Thousand and Twelve"
  }

  // "<one> hundred" (or bare "hundred").
  if (i + 1 < tokens.length &&
      isMultiplier(tokens[i], 19) &&
      tokens[i + 1] == 'hundred') {
    total += multiplierValue(tokens[i]) * 100;
    i += 2;
    any = true;
  } else if (i < tokens.length && tokens[i] == 'hundred') {
    total += 100;
    i += 1;
    any = true;
  }

  if (any && i < tokens.length && tokens[i] == 'and') {
    i += 1;
  }

  if (i < tokens.length && _tens.containsKey(tokens[i])) {
    total += _tens[tokens[i]]!;
    i += 1;
    any = true;
    // "twenty two" / "twenty-two" (hyphens already split into tokens).
    if (i < tokens.length && _ones.containsKey(tokens[i])) {
      total += _ones[tokens[i]]!;
      i += 1;
    }
  } else if (i < tokens.length && _ones.containsKey(tokens[i])) {
    total += _ones[tokens[i]]!;
    i += 1;
    any = true;
  }

  if (!any || total > 9999) {
    return null;
  }
  return (total, i);
}
