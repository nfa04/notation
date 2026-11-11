import 'dart:math' as math;
import 'dart:ui';

import '../models/canvas_models.dart';
import 'ink_clusters.dart' show linesOfWriting;

/// A few words of one line, read by the model in one go.
class InkChunk {
  final List<DrawingStroke> strokes;
  final Rect bounds;

  const InkChunk(this.strokes, this.bounds);
}

Rect strokeBounds(DrawingStroke s) {
  // (kept while the stroke stays as it is: the writing is grouped again after every change, and most strokes did not change)
  final key = s.stamp;
  final kept = _bounds[s];
  if (kept != null && kept.$1 == key) return kept.$2;
  var left = s.points.first.dx, right = left, top = s.points.first.dy, bottom = top;
  for (final p in s.points) {
    if (p.dx < left) left = p.dx;
    if (p.dx > right) right = p.dx;
    if (p.dy < top) top = p.dy;
    if (p.dy > bottom) bottom = p.dy;
  }
  final r = Rect.fromLTRB(left, top, right, bottom);
  _bounds[s] = (key, r);
  return r;
}

final Expando<(int, Rect)> _bounds = Expando('stroke bounds');

/// Sorts strokes into lines (top to bottom) and each line into chunks of a few
/// words (left to right). The model reads a line of about 20 tokens at most,
/// so longer lines are cut at the gaps between words.
///
/// [wordGap] is the gap that separates two words, as a fraction of the line's
/// height; a chunk has at most [maxWords] words and is at most
/// [maxWidthPerHeight] times as wide as the line is high.
List<List<InkChunk>> groupIntoLines(
  List<DrawingStroke> strokes, {
  double wordGap = 0.3,
  int maxWords = 3,
  double maxWidthPerHeight = 7,
}) {
  final drawn = [for (final s in strokes) if (s.points.length >= 2) s];
  if (drawn.isEmpty) return const [];
  final boxes = {for (final s in drawn) s: strokeBounds(s)};

  // lines: the rows of writing as the maths check finds them (bands of strokes whose heights overlap; the parts of a fraction, an
  // accent, a dot, a subscript go with their line; a stroke much taller than a letter, a bracket, joins nothing). Lines used to be
  // grown stroke by stroke, and a bracket over two lines or a long tail made a whole block of writing one "line", read as one
  // squeezed picture.
  final lines = [
    for (final row in linesOfWriting(drawn)) (strokes: row, box: row.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b))),
  ]..sort((a, b) => a.box.top.compareTo(b.box.top));

  return [
    for (final line in lines)
      () {
        final height = math.max(line.box.height, 1.0);
        final ordered = [...line.strokes]..sort((a, b) => boxes[a]!.left.compareTo(boxes[b]!.left));

        // words: strokes that follow each other closely
        final words = <List<DrawingStroke>>[];
        var wordRight = double.negativeInfinity;
        for (final s in ordered) {
          final box = boxes[s]!;
          if (words.isEmpty || box.left - wordRight > wordGap * height) {
            words.add([s]);
            wordRight = box.right;
          } else {
            words.last.add(s);
            wordRight = math.max(wordRight, box.right);
          }
        }

        // chunks: a few words, not wider than the model reads well
        final chunks = <InkChunk>[];
        var current = <List<DrawingStroke>>[];
        Rect? currentBox;
        void flush() {
          if (current.isEmpty) return;
          chunks.add(InkChunk([for (final w in current) ...w], currentBox!));
          current = [];
          currentBox = null;
        }

        for (final word in words) {
          final wordBox = word.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b));
          final joined = currentBox?.expandToInclude(wordBox);
          if (current.isNotEmpty && (current.length >= maxWords || joined!.width > maxWidthPerHeight * height)) {
            flush();
          }
          current.add(word);
          currentBox = currentBox == null ? wordBox : currentBox!.expandToInclude(wordBox);
        }
        flush();
        return chunks;
      }(),
  ];
}
