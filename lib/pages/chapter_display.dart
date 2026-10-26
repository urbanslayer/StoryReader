import 'package:flutter/material.dart';
import 'package:story_reader/chapter_number.dart';
import 'package:story_reader/prefs.dart';

/// Display-only widgets for chapter titles: a compact "Chapter N" label for
/// the reading app bar, a wrapping full-title heading for the top of the
/// chapter content, and a fixed-width number prefix for chapter lists.
///
/// Deliberately free of DB/router imports so they can be pumped in isolation.

/// Resolve the number to show for a chapter: the stored book chapter number,
/// falling back to parsing the title.
int? displayChapterNumber(String name, int? stored) =>
    stored ?? parseChapterNumber(name);

/// Fixed-width leading chapter number for chapter list rows (muted, bold),
/// so the numbers form a tidy column regardless of digit count.
class ChapterNumberPrefix extends StatelessWidget {
  final int number;

  const ChapterNumberPrefix(this.number, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 48,
      child: Padding(
        padding: const EdgeInsets.only(right: 8.0),
        child: Text(
          '$number',
          textAlign: TextAlign.end,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Centred app bar title for the read page: the compact "Chapter N" label
/// (or the name itself when no number is known), one line with ellipsis.
/// [onTap] (e.g. showing the full title) is supplied by the caller.
class ChapterAppBarTitle extends StatelessWidget {
  final String name;
  final int? chapterNumber;
  final VoidCallback? onTap;

  const ChapterAppBarTitle({
    super.key,
    required this.name,
    required this.chapterNumber,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Text(
        chapterShortLabel(name, chapterNumber),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge,
      ),
    );
  }
}

/// Heading rendered as the first item of the chapter content: the full
/// chapter title wrapping freely, with the compact "Chapter N" label above
/// it in a smaller muted style when the number is known. Honours the same
/// max text width constraint as the body paragraphs.
class ChapterHeading extends StatelessWidget {
  final String name;
  final int? chapterNumber;

  const ChapterHeading({super.key, required this.name, required this.chapterNumber});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final number = displayChapterNumber(name, chapterNumber);
    final label = number == null ? null : 'Chapter $number';
    final width = Preferences.maxTextWidth.value.toDouble();
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 8.0, left: 8.0, right: 8.0),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: width, maxWidth: width),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (label != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4.0),
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              Text(name, softWrap: true, style: theme.textTheme.headlineSmall),
              const Divider(),
            ],
          ),
        ),
      ),
    );
  }
}
