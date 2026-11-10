import 'dart:math' as math;
import 'dart:ui';

import '../models/canvas_models.dart';
import 'ink_grouping.dart';

/// A block of pen strokes that lie close together on a page: a few words, a line, a paragraph or one formula.
/// What is read (as text, as a formula) is read cluster by cluster, ahead of when it is asked for.
class InkCluster {
  final int page;
  final List<DrawingStroke> strokes;
  final Rect bounds;

  InkCluster(this.page, this.strokes, this.bounds);

  /// Names these strokes as they are now: another stroke, a moved one or a changed one is another key.
  late final String key = _keyOf(strokes);

  static String _keyOf(List<DrawingStroke> strokes) {
    // (the key is kept in the database with what was read: it is made of what stays the same from one run of the app to the
    // next, not of DrawingStroke.stamp, whose hash codes are different in each run)
    final parts = [for (final s in strokes) '${s.id}:${_print(s)}']..sort();
    var h = 5381;
    for (final c in parts.join(',').codeUnits) {
      h = ((h * 33) ^ c) & 0x7fffffff;
    }
    return '${strokes.length}-${h.toRadixString(16)}';
  }

  /// The width and the points of [s] (to a tenth of a unit), the same on every run.
  static String _print(DrawingStroke s) {
    var h = 5381;
    void add(int v) => h = ((h * 33) ^ v) & 0x7fffffff;
    add(s.points.length);
    add((s.width * 10).round());
    for (final p in s.points) {
      add((p.dx * 10).round());
      add((p.dy * 10).round());
    }
    return h.toRadixString(16);
  }

  /// The ids of the strokes.
  Set<String> get ids => {for (final s in strokes) s.id};
}

/// Whether a stroke can be part of handwriting: a pen line (not the highlighter) that is not too long to be a
/// letter or a word, which a drawing, a frame or an underline is.
bool isInkStroke(DrawingStroke s) {
  if (s.points.length < 2 || s.color.a <= 0.9 || !Brushes.writes(s.brush)) return false;
  final b = strokeBounds(s);
  return b.width <= largestStroke && b.height <= largestStroke;
}

/// The widest or tallest a stroke of handwriting is taken to be.
const largestStroke = 260.0;

/// The most strokes (and the greatest height) a cluster has before it is cut into lines.
const largestCluster = 120;
const tallestCluster = 350.0;

/// Groups the strokes of one page that lie close to each other. Two strokes belong together when the gap between them
/// is less than about the size of a letter. Strokes that are not handwriting (see [isInkStroke]) are left out, and so is
/// a lone dot. A cluster that is very big (a page of text) is cut into its lines.
///
/// With [rows] every cluster is cut into its rows of writing with [rowsOf], whatever its size: for reading a worked
/// solution line by line. (The cut into lines of a big cluster knows nothing of fractions: it tears them apart.)
List<InkCluster> clusterStrokes(int page, Iterable<DrawingStroke> strokes, {double? gap, bool rows = false}) {
  final ink = [for (final s in strokes) if (isInkStroke(s)) s];
  if (ink.isEmpty) return const [];
  final boxes = [for (final s in ink) strokeBounds(s)];

  // how close is close: about the size of a letter (the middle one: the gap between two words is about that), not
  // less than a hair and not more than a word
  final sizes = [for (final b in boxes) math.max(b.width, b.height)]..sort();
  final g = gap ?? (sizes[sizes.length ~/ 2]).clamp(16.0, 48.0);
  // beside each other the strokes may be further apart: the spaces around the signs of a formula (1 + 2 = 3) are as wide
  // as a letter is high, and the flat strokes of the signs pull the median down. The tall strokes tell the letter size.
  final heights = [for (final b in boxes) b.height]..sort();
  final letter = heights[(heights.length * 0.8).floor().clamp(0, heights.length - 1)];
  final gx = gap ?? math.max(g, (1.5 * letter).clamp(0.0, 120.0));

  // union-find over strokes whose boxes, grown by the gap, meet; sorted by their left edge so that each one is only
  // compared with those that start before it ends
  final parent = List.generate(ink.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  // a flat stroke (the bars of `=`, a minus, a fraction bar) is a sign of a formula, and people leave more room around those, and write
  // them a little off the line: it reaches further, so that `2F = \frac{a}{b} = 3` is not cut at its equals sign
  final flatReach = math.max(gx, (2.2 * letter).clamp(0.0, 120.0));
  final flatTall = math.max(g, (0.9 * letter).clamp(0.0, 48.0));
  bool flat(Rect b) => b.height <= 0.3 * letter && b.width >= 0.4 * letter;

  final order = List.generate(ink.length, (i) => i)..sort((a, b) => boxes[a].left.compareTo(boxes[b].left));
  for (var x = 0; x < order.length; x++) {
    final i = order[x];
    for (var y = x + 1; y < order.length; y++) {
      final j = order[y];
      if (boxes[j].left > boxes[i].right + flatReach) break;
      final isFlat = flat(boxes[i]) || flat(boxes[j]);
      if (boxes[j].left > boxes[i].right + (isFlat ? flatReach : gx)) continue;
      final tall = isFlat ? flatTall : g;
      final vertical = boxes[j].top <= boxes[i].bottom + tall && boxes[i].top <= boxes[j].bottom + tall;
      if (vertical) parent[find(j)] = find(i);
    }
  }

  final groups = <int, List<int>>{};
  for (var i = 0; i < ink.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(i);
  }

  final out = <InkCluster>[];
  for (final members in groups.values) {
    var bounds = boxes[members.first];
    for (final i in members) {
      bounds = bounds.expandToInclude(boxes[i]);
    }
    final strokesOf = [for (final i in members) ink[i]];
    if (strokesOf.length == 1 && math.max(bounds.width, bounds.height) < 10) continue; // a dot
    if (rows) {
      out.addAll(rowsOf(InkCluster(page, strokesOf, bounds)));
    } else if (strokesOf.length > largestCluster || bounds.height > tallestCluster) {
      // a page of writing: line by line
      for (final line in groupIntoLines(strokesOf)) {
        final lineStrokes = [for (final chunk in line) ...chunk.strokes];
        if (lineStrokes.isEmpty) continue;
        final lineBounds = line.map((c) => c.bounds).reduce((a, b) => a.expandToInclude(b));
        out.add(InkCluster(page, lineStrokes, lineBounds));
      }
    } else {
      out.add(InkCluster(page, strokesOf, bounds));
    }
  }
  out.sort((a, b) {
    final c = a.bounds.top.compareTo(b.bounds.top);
    return c != 0 ? c : a.bounds.left.compareTo(b.bounds.left);
  });
  return out;
}

/// Whether the clusters [a] and [b] are on one line of writing (they overlap vertically by more than half).
bool onOneLine(Rect a, Rect b) {
  final overlap = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  return overlap / math.max(1.0, math.min(a.height, b.height)) > 0.5;
}

/// Whether the writing in [cluster] might be a formula: it has parts stacked over each other (a fraction, a power, a
/// sum with limits) or, when it was read as text first, [text] has the signs and the digits of one.
bool looksLikeMaths(InkCluster cluster, {String? text}) {
  if (text != null && text.length <= 60 && RegExp(r'[=+\-*/^<>±×÷√∫∑]|\d\s*[a-zA-Z]|[a-zA-Z]\s*\d').hasMatch(text)) return true;
  final lines = groupIntoLines(cluster.strokes);
  if (lines.length < 2) return false;
  // two "lines" that lie over each other (not beside each other) are the top and bottom of a fraction, or a power
  for (var i = 0; i < lines.length; i++) {
    for (var j = i + 1; j < lines.length; j++) {
      final a = lines[i].map((c) => c.bounds).reduce((x, y) => x.expandToInclude(y));
      final b = lines[j].map((c) => c.bounds).reduce((x, y) => x.expandToInclude(y));
      final shared = math.min(a.right, b.right) - math.max(a.left, b.left);
      final narrower = math.max(1.0, math.min(a.width, b.width));
      final gap = math.max(0.0, math.max(a.top, b.top) - math.min(a.bottom, b.bottom));
      if (shared / narrower > 0.6 && gap < 1.2 * math.max(a.height, b.height)) return true;
    }
  }
  return false;
}

/// How high a letter is in [boxes]: a high percentile of the heights, since the flat strokes of `=`, `-` and the bar of a
/// fraction would pull a median down to nothing.
double letterHeight(Iterable<Rect> boxes) {
  final heights = [for (final b in boxes) b.height]..sort();
  if (heights.isEmpty) return 14;
  return math.max(heights[(heights.length * 0.75).floor().clamp(0, heights.length - 1)], 14.0);
}

/// A set of strokes whose heights overlap: a line of writing, or a part of one (the top or bottom of a fraction, an accent).
class _Band {
  final List<DrawingStroke> strokes;

  /// The strokes as the pieces that are one thing (a fraction, a root with its number, a single stroke).
  final List<List<DrawingStroke>> pieces;
  Rect box;
  _Band(this.strokes, this.box) : pieces = [List.of(strokes)];

  void absorb(_Band other) {
    strokes.addAll(other.strokes);
    pieces.addAll(other.pieces);
    box = box.expandToInclude(other.box);
  }
}

/// The rows of writing in [cluster], top to bottom: a worked solution of several lines is one cluster when the lines
/// are close, but each line is a step of its own.
///
/// Strokes whose heights overlap are one band. A line is a band, or several that belong together: the parts of a fraction
/// (a bar with writing above and below it, inside its width) and the small parts that float off a line (an accent, a dot, a
/// subscript, the limits of a sum), which go with the nearest band that has them in its width. Bands that do not belong
/// together are different rows however close they are. A stroke that is much taller than a letter (a brace, a margin line)
/// does not join anything; it goes to the row it overlaps most.
List<InkCluster> rowsOf(InkCluster cluster) => [for (final row in _rowsByBands(cluster)) ..._splitAtLabel(row)];

/// A row cut where a word with a colon ends and a formula begins (`Translation:   m g - 2F = m a`, `Rotation: ...`): a label is not part of the
/// formula, and the model that reads the formula would write the word as `\mbox{...}` garbage. The colon is two dots, one over the other, with
/// nothing between them; what is after it must be a good way off (a colon in `a : b` or `| : 2` has its numbers beside it).
List<InkCluster> _splitAtLabel(InkCluster row) {
  final strokes = row.strokes;
  if (strokes.length < 6) return [row];
  final boxes = {for (final s in strokes) s: strokeBounds(s)};
  final letter = letterHeight(boxes.values);
  final dots = [for (final s in strokes) if (boxes[s]!.width <= 0.4 * letter && boxes[s]!.height <= 0.4 * letter) s];
  for (final upper in dots) {
    for (final lower in dots) {
      final a = boxes[upper]!, b = boxes[lower]!;
      final dy = b.center.dy - a.center.dy;
      if (upper == lower || (a.center.dx - b.center.dx).abs() > 0.4 * letter || dy < 0.25 * letter || dy > 1.1 * letter) continue;
      final colon = a.expandToInclude(b);
      // (nothing between the dots, as in the bar of a division sign, and no letter's stem under them, as in an i)
      final corridor = Rect.fromLTRB(colon.left - 0.3 * letter, colon.top, colon.right + 0.3 * letter, colon.bottom + 0.5 * letter);
      if (strokes.any((s) => s != upper && s != lower && boxes[s]!.overlaps(corridor))) continue;
      bool before(DrawingStroke s) => s == upper || s == lower || boxes[s]!.center.dx <= colon.center.dx;
      final left = [for (final s in strokes) if (before(s)) s];
      final right = [for (final s in strokes) if (!before(s)) s];
      if (left.length - 2 < 3 || right.length < 2) continue;
      final gap = right.map((s) => boxes[s]!.left).reduce(math.min) - colon.right;
      final width = colon.left - left.map((s) => boxes[s]!.left).reduce(math.min);
      if (gap < 0.8 * letter || width < 2.5 * letter) continue;
      // (both parts are on the colon's line: with several lines in the row, what is beside the colon is another line's end)
      bool onTheLine(DrawingStroke s) => boxes[s]!.center.dy >= colon.top - 2.5 * letter && boxes[s]!.center.dy <= colon.bottom + 2.5 * letter;
      if (!left.every(onTheLine) || !right.every(onTheLine)) continue;
      Rect around(List<DrawingStroke> l) => l.map((s) => boxes[s]!).reduce((x, y) => x.expandToInclude(y));
      return [
        InkCluster(row.page, left, around(left)),
        ..._splitAtLabel(InkCluster(row.page, right, around(right))),
      ];
    }
  }
  return [row];
}

List<InkCluster> _rowsByBands(InkCluster cluster) {
  final strokes = cluster.strokes;
  if (strokes.length < 2) return [cluster];
  final boxes = {for (final s in strokes) s: strokeBounds(s)};
  final letter = letterHeight(boxes.values);

  final tall = [for (final s in strokes) if (boxes[s]!.height > 2.5 * letter) s];
  final normal = [for (final s in strokes) if (!tall.contains(s)) s]..sort((a, b) => boxes[a]!.top.compareTo(boxes[b]!.top));
  if (normal.isEmpty) return [cluster];

  // the parts of one fraction (or the stroke over a root and what is under it) are one piece before the lines are told apart: a line with
  // several fractions has all of its numerators at one height and all of its denominators at another, and those would be rows of their own
  final pieces = [for (final p in _fractionPieces(normal, boxes, letter)) _Band(p, p.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b)))]
    ..sort((a, b) => a.box.top.compareTo(b.box.top));
  var bands = <_Band>[];
  for (final piece in pieces) {
    if (bands.isNotEmpty && piece.box.top <= bands.last.box.bottom + 0.05 * letter) {
      bands.last.absorb(piece);
    } else {
      bands.add(piece);
    }
  }

  // the small parts first (they go to the nearest band that has them above or below), then the fractions
  bool joined = true;
  while (joined && bands.length > 1) {
    joined = false;
    for (var i = 0; i < bands.length && !joined; i++) {
      final host = _hostOf(bands, i, boxes, letter);
      if (host != null) {
        final small = bands.removeAt(i);
        bands[host > i ? host - 1 : host].absorb(small);
        joined = true;
      }
    }
    for (var i = 0; i + 1 < bands.length && !joined; i++) {
      if (_fractionBetween(bands[i], bands[i + 1], boxes, letter)) {
        bands[i].absorb(bands.removeAt(i + 1));
        joined = true;
      }
    }
  }

  // a row far taller than a line of writing is lines that touch (long tails over short letters): cut it where the middles
  // of the strokes are far apart
  final parts = <List<DrawingStroke>>[];
  for (final band in bands) {
    if (band.box.height > 4.5 * letter && band.strokes.length > 1) {
      parts.addAll(_byCentres(band.pieces, boxes, 1.1 * letter, letter));
    } else {
      parts.add(band.strokes);
    }
  }
  if (parts.length == 1 && tall.isEmpty) return [cluster];

  final members = [for (final p in parts) [...p]];
  final extents = [for (final p in parts) p.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b))];
  for (final s in tall) {
    final b = boxes[s]!;
    var best = 0;
    var bestOverlap = double.negativeInfinity;
    for (var i = 0; i < extents.length; i++) {
      final overlap = math.min(b.bottom, extents[i].bottom) - math.max(b.top, extents[i].top);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = i;
      }
    }
    members[best].add(s);
  }
  if (members.length == 1) return [cluster];
  return [
    for (final row in members)
      InkCluster(cluster.page, row, row.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b))),
  ];
}

/// The most strokes a numerator or a denominator is taken to have.
const _longestPart = 16;

/// [strokes] grouped into the pieces that are one thing: a fraction bar with its numerator above it and its denominator below it (nested
/// fractions share strokes and are one piece), and the stroke over the number under a root. Every other stroke is a piece of its own.
List<List<DrawingStroke>> _fractionPieces(List<DrawingStroke> strokes, Map<DrawingStroke, Rect> boxes, double letter) {
  bool isBar(Rect b) => b.width >= 0.8 * letter && b.height <= 0.5 * letter && b.height <= 0.4 * b.width;
  final parent = List.generate(strokes.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (var i = 0; i < strokes.length; i++) {
    final bar = boxes[strokes[i]]!;
    if (!isBar(bar)) continue;
    final lo = bar.left - 0.25 * bar.width, hi = bar.right + 0.25 * bar.width;
    final above = <int>[], below = <int>[];
    // (how far from the bar: a letter and a half, or more for a long bar, which people write with the numerator and denominator further off)
    final reach = math.max(1.5 * letter, 0.35 * bar.width);
    for (var j = 0; j < strokes.length; j++) {
      if (j == i) continue;
      final b = boxes[strokes[j]]!;
      if (b.center.dx < lo || b.center.dx > hi) continue;
      // (another bar of about the same width is the other half of an equals sign, or a line of its own)
      if (isBar(b) && b.width >= 0.5 * bar.width) continue;
      if (b.center.dy < bar.center.dy && bar.top - b.bottom <= reach) above.add(j);
      if (b.center.dy > bar.center.dy && b.top - bar.bottom <= reach) below.add(j);
    }
    // (what is written beside it is not the numerator or the denominator: it reaches far beyond the bar)
    bool within(List<int> side, double slack) {
      final box = side.map((j) => boxes[strokes[j]]!).reduce((a, b) => a.expandToInclude(b));
      return box.left > bar.left - slack && box.right < bar.right + slack;
    }

    // (a numerator or a denominator is a few symbols: a whole line of writing over or under a bar is a heading with its underline)
    List<int> members;
    // (the numerator and the denominator are about as near to the bar as each other: the bar of a T, with the letters of the line above far over it
    // and its own stem touching it, is not a fraction)
    bool evenlySpaced() {
      final gapAbove = bar.top - above.map((j) => boxes[strokes[j]]!.bottom).reduce(math.max);
      final gapBelow = below.map((j) => boxes[strokes[j]]!.top).reduce(math.min) - bar.bottom;
      final near = math.max(1.0 * letter, 0.35 * bar.width);
      final small = math.max(0.1 * letter, math.min(gapAbove, gapBelow)), large = math.max(gapAbove, gapBelow);
      return large <= near && large / small <= 4;
    }

    if (above.isNotEmpty && below.isNotEmpty && above.length <= _longestPart && below.length <= _longestPart && within(above, 3 * letter + 0.5 * bar.width) && within(below, 3 * letter + 0.5 * bar.width) && evenlySpaced()) {
      members = [...above, ...below];
    } else if (above.isEmpty && bar.width >= 1.2 * letter) {
      // the stroke over a root has what is under the root close below it, and nothing above; only what is under the stroke is the root's
      members = [
        for (var j = 0; j < strokes.length; j++)
          if (j != i && boxes[strokes[j]]!.center.dx >= bar.left - 0.5 * letter && boxes[strokes[j]]!.center.dx <= bar.right + 0.5 * letter && boxes[strokes[j]]!.center.dy > bar.center.dy && boxes[strokes[j]]!.top - bar.bottom <= reach && !(isBar(boxes[strokes[j]]!) && boxes[strokes[j]]!.width >= 0.5 * bar.width))
            j
      ];
      if (members.isEmpty || members.length > 3 * _longestPart) continue;
    } else {
      continue;
    }
    for (final j in members) {
      parent[find(j)] = find(i);
    }
  }
  final groups = <int, List<DrawingStroke>>{};
  for (var i = 0; i < strokes.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(strokes[i]);
  }
  return groups.values.toList();
}

/// The band that the small band [i] floats off (the one above or below it that has it within its width, the nearer one), or
/// null when it is not small or has no such band.
int? _hostOf(List<_Band> bands, int i, Map<DrawingStroke, Rect> boxes, double letter) {
  final small = bands[i];
  // (a script, an accent, a limit or a dot: narrow, lower than the host, and not a line of its own; the bigger it is, the
  // closer it has to be)
  final height = small.box.height;
  if (height > 1.3 * letter || small.box.width > 3 * letter) return null;
  final reach = height <= 0.6 * letter ? 0.8 : (height <= 0.85 * letter ? 0.5 : 0.25);
  int? best;
  var bestDistance = double.infinity;
  for (final j in [i - 1, i + 1]) {
    if (j < 0 || j >= bands.length) continue;
    if (bands[j].box.height < 1.2 * height) continue;
    // it belongs to the glyph it sits next to: the distance to the nearest stroke, not to the whole line
    var distance = double.infinity;
    for (final s in bands[j].strokes) {
      final b = boxes[s]!;
      final dx = math.max(0.0, math.max(small.box.left - b.right, b.left - small.box.right));
      final dy = math.max(0.0, math.max(small.box.top - b.bottom, b.top - small.box.bottom));
      distance = math.min(distance, math.sqrt(dx * dx + dy * dy));
    }
    if (distance > reach * letter || distance >= bestDistance) continue;
    best = j;
    bestDistance = distance;
  }
  return best;
}

/// Whether [upper] and [lower] are the two halves of a fraction: a bar in one of them, with writing in the other that lies
/// within the width of the bar and close to it.
bool _fractionBetween(_Band upper, _Band lower, Map<DrawingStroke, Rect> boxes, double letter) {
  bool isBar(Rect b) => b.width >= 0.8 * letter && b.height <= 0.5 * letter && b.height <= 0.4 * b.width;
  // a bar at the bottom of the upper band has the denominator below it ...
  for (final bar in upper.strokes.where((s) => isBar(boxes[s]!))) {
    final bb = boxes[bar]!;
    if (_underBar(bb, lower, boxes, letter, above: false)) return true;
  }
  // ... and a bar at the top of the lower band has the numerator above it
  for (final bar in lower.strokes.where((s) => isBar(boxes[s]!))) {
    final bb = boxes[bar]!;
    if (_underBar(bb, upper, boxes, letter, above: true)) return true;
  }
  return false;
}

bool _underBar(Rect bar, _Band other, Map<DrawingStroke, Rect> boxes, double letter, {required bool above}) {
  if (other.strokes.length > _longestPart) return false;
  final gap = above ? bar.top - other.box.bottom : other.box.top - bar.bottom;
  if (gap > 1.0 * letter) return false;
  final lo = bar.left - 0.25 * bar.width, hi = bar.right + 0.25 * bar.width;
  final inside = other.strokes.where((s) => boxes[s]!.center.dx >= lo && boxes[s]!.center.dx <= hi).length;
  if (inside == 0) return false;
  // (a whole line beside it is not the numerator: it reaches far beyond the bar)
  return other.box.left > bar.left - 3 * letter - 0.5 * bar.width && other.box.right < bar.right + 3 * letter + 0.5 * bar.width;
}

/// [pieces] (a fraction is one piece) cut into the lines they are in. Only what is about a letter high says where a line is: a bar, a dot, a
/// comma or an underline sits between two lines as well as on one, and would bridge the gap between lines that touch (a heading with its
/// underline over the line below it); those go with the part they overlap most, or the nearest.
///
/// The middles of the pieces, top to bottom, are cut at their widest gap when that is a real step from one line to the next: at least
/// [gap] (about a letter) wide, or a good part of a letter with a good many pieces on both sides and the two lines a line spacing apart
/// (a few strays from the line above, a descender or a high letter, do not leave a gap as wide as a letter). The parts are cut again.
List<List<DrawingStroke>> _byCentres(List<List<DrawingStroke>> pieces, Map<DrawingStroke, Rect> boxes, double gap, double letter) {
  Rect boxOf(List<DrawingStroke> p) => p.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b));
  final everything = [for (final p in pieces) ...p];
  final anchors = [for (final p in pieces) if (boxOf(p).height >= 0.45 * letter) p]..sort((a, b) => boxOf(a).center.dy.compareTo(boxOf(b).center.dy));
  final loose = [for (final p in pieces) if (boxOf(p).height < 0.45 * letter) p];
  if (anchors.length < 2) return [everything];

  double middle(List<List<DrawingStroke>> side) => boxOf(side[side.length ~/ 2]).center.dy;
  List<List<List<DrawingStroke>>> cut(List<List<DrawingStroke>> side) {
    if (side.length < 2) return [side];
    var at = 0;
    var widest = double.negativeInfinity;
    for (var i = 1; i < side.length; i++) {
      final d = boxOf(side[i]).center.dy - boxOf(side[i - 1]).center.dy;
      if (d > widest) {
        widest = d;
        at = i;
      }
    }
    final above = side.sublist(0, at), below = side.sublist(at);
    final real = widest > gap;
    final robust = widest >= 0.7 * letter && math.min(above.length, below.length) >= math.max(3, 0.2 * side.length) && middle(below) - middle(above) >= 1.6 * letter;
    if (!real && !robust) return [side];
    return [...cut(above), ...cut(below)];
  }

  final groups = cut(anchors);
  if (groups.length == 1) return [everything];
  final extents = [for (final g in groups) g.map(boxOf).reduce((a, b) => a.expandToInclude(b))];
  for (final p in loose) {
    final b = boxOf(p);
    var best = 0;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < groups.length; i++) {
      final overlap = math.min(b.bottom, extents[i].bottom) - math.max(b.top, extents[i].top);
      // (the more it overlaps the better; when it touches or is clear of both, the nearer middle wins)
      final score = overlap > 0 ? 1000 + overlap : -(b.center.dy - extents[i].center.dy).abs();
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    groups[best].add(p);
  }
  return [for (final g in groups) [for (final p in g) ...p]];
}
