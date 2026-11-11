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

  /// Whether the word is spelled right: such a word is only marked when the person asks to see what was read (to check it was taken for writing).
  final bool correct;

  /// Whether the reader was unsure of the word (it may have misread it, whether or not it is spelled right): such a word is underlined in yellow.
  final bool unsure;

  const InkMisspelling(this.page, this.key, this.word, this.rect, {this.correct = false, this.unsure = false});

  @override
  String toString() => 'InkMisspelling($word, $rect)';
}

/// [word] as it is compared with the words the reader was unsure of: letters and digits only, in lower case (the reader's words keep the marks of
/// punctuation they were written with).
String _core(String word) => word.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '').toLowerCase();

/// How wide a letter is written, to tell where a word is in a line (the reader keeps no box per word): narrow letters take less.
double _width(String c) {
  if ('iIl.,;:\'’!|jt ()'.contains(c)) return 0.5;
  if ('fr'.contains(c)) return 0.7;
  if ('mwMW'.contains(c)) return 1.5;
  return 1;
}

final _maths = RegExp(r'\$\$?[^$]*\$?\$');
final _command = RegExp(r'\\[a-zA-Z]+|[{}^_$\\]');

/// [text] with the stretches of LaTeX between dollar signs blanked out (as long as they were, so that places in it stay where they
/// are), and how wide each place is written: a stretch of LaTeX as wide as the signs it stands for (`\frac{1}{2}` is three).
(String, List<double>) _withoutMaths(String text) {
  final weights = [for (var i = 0; i < text.length; i++) _width(text[i])];
  final masked = text.replaceAllMapped(_maths, (m) {
    final shown = m[0]!.replaceAll(_command, '').replaceAll(' ', '').length;
    for (var i = m.start; i < m.end; i++) {
      weights[i] = shown / (m.end - m.start);
    }
    return ' ' * (m.end - m.start);
  });
  return (masked, weights);
}

/// Every word of the readings [blocks] (what was read of each block of writing, null where it was not read yet) that [checker] checks (the ones it does not
/// know have [InkMisspelling.correct] false), with where they are. A word is placed by its share of the line, so the box is near the word, not exact. Words of up to
/// two letters are left alone: handwriting is misread in them too often to say anything. Words that are among [unsure] (the ones the reader
/// was not sure of, see [InkRecognizer.recognizeScored]) are marked so.
List<InkMisspelling> checkedInk(Iterable<({InkCluster block, String? text})> blocks, SpellChecker checker, {Set<String> unsure = const {}}) {
  if (!checker.active) return const [];
  final doubtful = {for (final w in unsure) _core(w)}..remove('');
  final out = <InkMisspelling>[];
  for (final b in blocks) {
    final text = b.text;
    if (text == null || text.trim().isEmpty) continue;
    for (final line in inkTextLines(b.block, text)) {
      // the maths the reader wrote as LaTeX ($...$) is not words: it is left out, and takes as much of the line as it has signs
      final (masked, weights) = _withoutMaths(line.text);
      final total = weights.fold(0.0, (a, b) => a + b);
      if (total <= 0) continue;
      double before(int unit) => weights.take(unit).fold(0.0, (a, b) => a + b);

      for (final (r, right) in checker.checked(masked)) {
        if (r.end - r.start < 3) continue;
        final left = line.box.left + line.box.width * before(r.start) / total;
        final rightEdge = line.box.left + line.box.width * before(r.end) / total;
        final word = line.text.substring(r.start, r.end);
        out.add(InkMisspelling(b.block.page, b.block.key, word, Rect.fromLTRB(left, line.box.top, rightEdge, line.box.bottom), correct: right, unsure: doubtful.contains(_core(word))));
      }
    }
  }
  return out;
}

/// The words of [checkedInk] that are not spelled right.
List<InkMisspelling> misspelledInk(Iterable<({InkCluster block, String? text})> blocks, SpellChecker checker) => [
      for (final m in checkedInk(blocks, checker))
        if (!m.correct) m,
    ];
