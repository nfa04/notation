import 'dart:math' as math;
import 'dart:ui';

import '../models/canvas_models.dart';

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

  // lines: a stroke joins the line it overlaps vertically
  drawn.sort((a, b) => boxes[a]!.center.dy.compareTo(boxes[b]!.center.dy));
  final lines = <({List<DrawingStroke> strokes, Rect box})>[];
  for (final s in drawn) {
    final box = boxes[s]!;
    var placed = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final overlap = math.min(box.bottom, line.box.bottom) - math.max(box.top, line.box.top);
      final smaller = math.min(math.max(box.height, 1), math.max(line.box.height, 1));
      if (overlap / smaller > 0.5) {
        lines[i] = (strokes: [...line.strokes, s], box: line.box.expandToInclude(box));
        placed = true;
        break;
      }
    }
    if (!placed) lines.add((strokes: [s], box: box));
  }

  // a dot or an accent floats above its letter without touching its line:
  // small strokes that sit close to a line and over it belong to it
  var merged = true;
  while (merged) {
    merged = false;
    outer:
    for (var i = 0; i < lines.length; i++) {
      for (var j = 0; j < lines.length; j++) {
        if (i == j) continue;
        final small = lines[i].box, big = lines[j].box;
        if (small.height > 0.35 * big.height) continue;
        final gap = math.max(0.0, math.max(small.top, big.top) - math.min(small.bottom, big.bottom));
        final overOrUnder = small.left < big.right && big.left < small.right;
        if (overOrUnder && gap < 0.5 * big.height) {
          lines[j] = (strokes: [...lines[j].strokes, ...lines[i].strokes], box: big.expandToInclude(small));
          lines.removeAt(i);
          merged = true;
          break outer;
        }
      }
    }
  }
  lines.sort((a, b) => a.box.top.compareTo(b.box.top));

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
