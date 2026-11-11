import 'dart:math' as math;
import 'dart:ui';

import '../models/canvas_models.dart';
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

  /// The strokes the word is written with, when they are known exactly (empty: only the box is).
  final List<DrawingStroke> strokes;

  const InkMisspelling(this.page, this.key, this.word, this.rect, {this.correct = false, this.unsure = false, this.strokes = const []});

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
final _token = RegExp(r'\$\$?[^$]*\$?\$|\S+');
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
    for (final line in _linesOf(b.block, text)) {
      // the maths the reader wrote as LaTeX ($...$) is not words: it is left out, and takes as much of the line as it has signs
      final (masked, weights) = _withoutMaths(line.text);
      final total = weights.fold(0.0, (a, b) => a + b);
      if (total <= 0) continue;
      double before(int unit) => weights.take(unit).fold(0.0, (a, b) => a + b);

      // when the line has as many written words as the text has words (a stretch of maths is one), each word is laid over the
      // strokes it is written with; otherwise it is placed by its share of the line
      final tokens = [for (final t in _token.allMatches(line.text)) (start: t.start, end: t.end)];
      final exact = line.words.isNotEmpty && line.words.length == tokens.length;
      // (otherwise the words of the text are matched to the written ones, in order, by where each word should start and where the
      // gaps between the written words are)
      final groups = exact || line.words.length < tokens.length || tokens.isEmpty
          ? null
          : _groupsOf([for (final t in tokens) line.box.left + line.box.width * before(t.start) / total], [for (final w in line.words) w.box], line.box.height);

      for (final (r, right) in checker.checked(masked)) {
        if (r.end - r.start < 3) continue;
        var left = line.box.left + line.box.width * before(r.start) / total;
        var rightEdge = line.box.left + line.box.width * before(r.end) / total;
        var strokes = const <DrawingStroke>[];
        Rect? own; // the written word(s) it is laid over, when known
        if (exact) {
          final i = tokens.indexWhere((t) => r.start >= t.start && r.start < t.end);
          if (i >= 0) {
            final t = tokens[i], w = line.words[i].box;
            own = w;
            final span = before(t.end) - before(t.start);
            if (span > 0) {
              left = w.left + w.width * (before(r.start) - before(t.start)) / span;
              rightEdge = w.left + w.width * (before(math.min(r.end, t.end)) - before(t.start)) / span;
              // (the whole word, but for a mark of punctuation: all of its strokes)
              if (r.start - t.start <= 1 && t.end - r.end <= 1) strokes = line.words[i].strokes;
            }
          }
        }
        if (!exact && groups != null) {
          final i = tokens.indexWhere((t) => r.start >= t.start && r.start < t.end);
          if (i >= 0 && groups[i + 1] > groups[i]) {
            final t = tokens[i], first = line.words[groups[i]].box, last = line.words[groups[i + 1] - 1].box;
            own = first.expandToInclude(last);
            final span = before(t.end) - before(t.start), width = last.right - first.left;
            if (span > 0) {
              left = first.left + width * (before(r.start) - before(t.start)) / span;
              rightEdge = first.left + width * (before(math.min(r.end, t.end)) - before(t.start)) / span;
              if (r.start - t.start <= 1 && t.end - r.end <= 1) strokes = [for (var w = groups[i]; w < groups[i + 1]; w++) ...line.words[w].strokes];
            }
          }
        }
        // the foot of the mark is the foot of the writing under it, not of the whole line (a stray stroke or a long descender
        // elsewhere in the line would pull it down)
        var top = line.box.top, bottom = line.box.bottom;
        final under = own != null ? [own] : [for (final w in line.words) if (w.box.right > left && w.box.left < rightEdge) w.box];
        if (under.isNotEmpty) {
          top = under.map((w) => w.top).reduce(math.min);
          bottom = under.map((w) => w.bottom).reduce(math.max);
        }
        final word = line.text.substring(r.start, r.end);
        out.add(InkMisspelling(b.block.page, b.block.key, word, Rect.fromLTRB(left, top, rightEdge, bottom), correct: right, unsure: doubtful.contains(_core(word)), strokes: strokes));
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

/// Which written words each word of the text lies over: entry i to i + 1 of the result are the written words (by number) of word i
/// of the text, [starts] being where each one starts as estimated from its letters. The cuts between words are put at gaps between
/// the written words, as near their estimated places as can be, in order; big gaps are preferred.
List<int> _groupsOf(List<double> starts, List<Rect> boxes, double height) {
  final t = starts.length, w = boxes.length;
  final h = math.max(height, 1.0);
  // where a cut after [g] written words is (the middle of the gap, or the very start)
  double at(int g) => g == 0 ? boxes.first.left : g >= w ? boxes.last.right : (boxes[g - 1].right + boxes[g].left) / 2;
  double gap(int g) => g == 0 || g >= w ? h : math.max(0.0, boxes[g].left - boxes[g - 1].right);
  double cost(int k, int g) => (at(g) - starts[k]).abs() / h - 0.5 * math.min(gap(g) / h, 1.0);
  // cut k (k = 1..t-1) separates word k - 1 from word k; the first cut is 0 and the last is w
  final best = List.generate(t, (_) => List.filled(w + 1, double.infinity));
  final from = List.generate(t, (_) => List.filled(w + 1, 0));
  best[0][0] = 0;
  for (var k = 1; k < t; k++) {
    for (var g = 0; g <= w; g++) {
      for (var f = 0; f <= g; f++) {
        if (best[k - 1][f].isInfinite) continue;
        // (a word with no written word of its own is a poor fit)
        final c = best[k - 1][f] + cost(k, g) + (g == f ? 3.0 : 0.0);
        if (c < best[k][g]) {
          best[k][g] = c;
          from[k][g] = f;
        }
      }
    }
  }
  var g = 0;
  var low = double.infinity;
  for (var f = 0; f <= w; f++) {
    final c = best[t - 1][f];
    if (c < low) {
      low = c;
      g = f;
    }
  }
  final out = List.filled(t + 1, 0)..[t] = w;
  for (var k = t - 1; k >= 1; k--) {
    out[k] = g;
    g = from[k][g];
  }
  return out;
}

/// The lines of [text] (what was read of [block]) with where they are written. Where the reading has as many lines as the writing
/// that is [inkTextLines]; where it has not (the reader wraps and joins lines as it likes) the words of the whole text are matched
/// to the written words of the whole block, in order, whatever line either is on.
List<InkTextLine> _linesOf(InkCluster block, String text) {
  final texts = text.split('\n').map((t) => t.trim()).toList();
  final written = inkWrittenLines(block);
  if (written.isEmpty) return inkTextLines(block, text);
  if (written.length == texts.length) return inkTextLines(block, text);
  // every written word with the line it is on, and where it would be if the lines were laid end to end
  final boxes = <InkWordBox>[];
  final lineOf = <int>[];
  final virtual = <Rect>[];
  var offset = 0.0;
  for (var l = 0; l < written.length; l++) {
    final line = written[l];
    for (final w in line.words) {
      boxes.add(w);
      lineOf.add(l);
      virtual.add(Rect.fromLTRB(offset + w.box.left - line.box.left, w.box.top, offset + w.box.right - line.box.left, w.box.bottom));
    }
    offset += line.box.width;
  }
  if (boxes.isEmpty) return inkTextLines(block, text);
  // every word of the text, with how many letters come before it
  final words = <({int line, int start, int end, double at})>[];
  var letters = 0.0;
  final weightsOf = <(String, List<double>)>[];
  for (var i = 0; i < texts.length; i++) {
    final (masked, weights) = _withoutMaths(texts[i]);
    weightsOf.add((masked, weights));
    for (final t in _token.allMatches(texts[i])) {
      words.add((line: i, start: t.start, end: t.end, at: letters + weights.take(t.start).fold(0.0, (a, b) => a + b)));
    }
    letters += weights.fold(0.0, (a, b) => a + b);
  }
  if (words.isEmpty || words.length > boxes.length || letters <= 0) return inkTextLines(block, text);
  final heights = [for (final w in boxes) w.box.height]..sort();
  final groups = _groupsOf([for (final w in words) offset * w.at / letters], virtual, heights[heights.length ~/ 2]);
  // the written words of each word of the text (only those on the line the first of them is on)
  final per = <List<InkWordBox>>[];
  for (var k = 0; k < words.length; k++) {
    final from = groups[k], to = groups[k + 1];
    if (to <= from) {
      per.add(const []);
      continue;
    }
    per.add([for (var w = from; w < to; w++) if (lineOf[w] == lineOf[from]) boxes[w]]);
  }
  final out = <InkTextLine>[];
  for (var i = 0; i < texts.length; i++) {
    if (texts[i].isEmpty) continue;
    final mine = [for (var k = 0; k < words.length; k++) if (words[k].line == i) k];
    if (mine.isEmpty) continue;
    final placed = [for (final k in mine) if (per[k].isNotEmpty) per[k]];
    if (placed.isEmpty) continue;
    // a word of the text that got no written word has none to be laid over: the line is not trusted then
    if (placed.length != mine.length) continue;
    final merged = [
      for (final g in placed) InkWordBox(g.map((w) => w.box).reduce((a, b) => a.expandToInclude(b)), [for (final w in g) ...w.strokes]),
    ];
    out.add(InkTextLine(texts[i], merged.map((w) => w.box).reduce((a, b) => a.expandToInclude(b)), words: merged));
  }
  return out;
}
