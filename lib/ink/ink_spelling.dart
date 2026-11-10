import 'dart:ui';

import '../export/pdf_ink_text.dart';
import '../spelling/spell_checker.dart';
import 'ink_clusters.dart';

/// A word in the handwriting of a page that the dictionaries do not know, and where it is written.
class InkMisspelling {
  final int page;

  /// The block of writing it is in ([InkCluster.key]).
  final String key;
  final String word;

  /// In the units of the page: the line of writing it is on, narrowed to the word.
  final Rect rect;

  const InkMisspelling(this.page, this.key, this.word, this.rect);

  @override
  String toString() => 'InkMisspelling($word, $rect)';
}

/// How wide a letter is written, to tell where a word is in a line (the reader keeps no box per word): narrow letters take less.
double _width(String c) {
  if ('iIl.,;:\'’!|jt ()'.contains(c)) return 0.5;
  if ('fr'.contains(c)) return 0.7;
  if ('mwMW'.contains(c)) return 1.5;
  return 1;
}

/// The words of the readings [blocks] (what was read of each block of writing, null where it was not read yet) that [checker] does not
/// know, with where they are. A word is placed by its share of the line, so the box is near the word, not exact. Words of up to
/// two letters are left alone: handwriting is misread in them too often to say anything.
List<InkMisspelling> misspelledInk(Iterable<({InkCluster block, String? text})> blocks, SpellChecker checker) {
  if (!checker.active) return const [];
  final out = <InkMisspelling>[];
  for (final b in blocks) {
    final text = b.text;
    if (text == null || text.trim().isEmpty) continue;
    for (final line in inkTextLines(b.block, text)) {
      final weights = [for (var i = 0; i < line.text.length; i++) _width(line.text[i])];
      final total = weights.fold(0.0, (a, b) => a + b);
      if (total <= 0) continue;
      double before(int unit) => weights.take(unit).fold(0.0, (a, b) => a + b);

      for (final r in checker.misspellings(line.text)) {
        if (r.end - r.start < 3) continue;
        final left = line.box.left + line.box.width * before(r.start) / total;
        final right = line.box.left + line.box.width * before(r.end) / total;
        out.add(InkMisspelling(b.block.page, b.block.key, line.text.substring(r.start, r.end), Rect.fromLTRB(left, line.box.top, right, line.box.bottom)));
      }
    }
  }
  return out;
}
