import 'dart:math' as math;
import 'dart:typed_data';
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
  late final String key = keyOf(strokes);

  /// The key of any set of strokes (a block, or a selection that was read).
  static String keyOf(Iterable<DrawingStroke> strokes) {
    // (the key is kept in the database with what was read: it is made of what stays the same from one run of the app to the
    // next, not of DrawingStroke.stamp, whose hash codes are different in each run)
    final parts = [for (final s in strokes) '${s.id}:${_print(s)}']..sort();
    var h = 5381;
    for (final c in parts.join(',').codeUnits) {
      h = ((h * 33) ^ c) & 0x7fffffff;
    }
    return '${parts.length}-${h.toRadixString(16)}';
  }

  /// The width and the points of [s] (to a tenth of a unit), the same on every run.
  static String _print(DrawingStroke s) {
    var h = 5381;
    void add(int v) => h = ((h * 33) ^ v) & 0x7fffffff;
    add(s.points.length);
    add(_tenths(s.width));
    for (final p in s.points) {
      add(_tenths(p.dx));
      add(_tenths(p.dy));
    }
    return h.toRadixString(16);
  }

  static final _single = Float32List(1);

  /// [v] in tenths, as it is after it was stored: points are kept as 32-bit numbers, so a stroke that was just drawn (64-bit) and the
  /// same stroke loaded again can round differently (244.54999 and 244.55000), and its block would get another key and be read
  /// again. Rounding to 32 bits first gives both the same; a number that has been stored already does not change by it.
  static int _tenths(double v) {
    _single[0] = v;
    return (_single[0] * 10).round();
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
  final ink = _withoutUnderlines([for (final s in strokes) if (isInkStroke(s)) s]);
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

  // the rows and columns of a matrix are further apart than words are: its brackets hold them together
  final index = {for (var i = 0; i < ink.length; i++) ink[i]: i};
  for (final m in matricesIn(ink, {for (var i = 0; i < ink.length; i++) ink[i]: boxes[i]}, letter)) {
    for (final s in m) {
      parent[find(index[s]!)] = find(index[m.first]!);
    }
  }

  // blocks of one line each that are on the same line, a few letters apart, are one line of writing with a wide gap in it (`Rotation:
  // 2F r = I a`, a word written after a pause): read apart, neither half makes sense to the reader
  if (gap == null) {
    final parts = <int, Rect>{};
    for (var i = 0; i < ink.length; i++) {
      final r = find(i);
      parts[r] = parts[r]?.expandToInclude(boxes[i]) ?? boxes[i];
    }
    final oneLine = [for (final e in parts.entries) if (e.value.height <= 2.5 * letter) e]..sort((a, b) => a.value.left.compareTo(b.value.left));
    for (var x = 0; x < oneLine.length; x++) {
      for (var y = x + 1; y < oneLine.length; y++) {
        final a = oneLine[x].value, b = oneLine[y].value;
        if (b.left - a.right > 3 * letter) break;
        final shared = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
        if (b.left >= a.right && shared >= 0.6 * math.min(a.height, b.height)) parent[find(oneLine[y].key)] = find(oneLine[x].key);
      }
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

/// [ink] without the strokes that underline writing: a long flat stroke just under several strokes, with nothing under it for a letter
/// and a half (a fraction bar has its denominator there). It is not writing, and the reader would be given it in the picture of the line.
List<DrawingStroke> _withoutUnderlines(List<DrawingStroke> ink) {
  if (ink.length < 3) return ink;
  final boxes = {for (final s in ink) s: strokeBounds(s)};
  final heights = [for (final b in boxes.values) b.height]..sort();
  final letter = math.max(heights[(heights.length * 0.8).floor().clamp(0, heights.length - 1)], 14.0);
  bool underline(DrawingStroke s) {
    final b = boxes[s]!;
    if (b.width < 2.5 * letter || b.height > math.max(0.3 * letter, 0.08 * b.width)) return false;
    var above = 0;
    for (final o in ink) {
      if (o == s) continue;
      final a = boxes[o]!;
      final within = a.center.dx >= b.left && a.center.dx <= b.right;
      if (!within) continue;
      // (something written under it: a denominator, which may be well below the bar, or the next line close to it)
      if (a.top >= b.top - 0.1 * letter && a.top <= b.bottom + 1.5 * letter) return false;
      if (a.bottom <= b.bottom + 0.2 * letter && a.bottom >= b.top - 0.8 * letter && a.height >= 0.3 * letter) above++;
    }
    // under several letters, most of its width
    return above >= 3;
  }

  final drop = {for (final s in ink) if (underline(s)) s};
  return drop.isEmpty ? ink : [for (final s in ink) if (!drop.contains(s)) s];
}

/// [clusterStrokes] of each page, kept while the page's strokes stay as they are: the background reader groups the whole note again
/// after every reading and every change, and almost always only one page (or none) changed. A page counts as unchanged when it has the
/// same stroke objects in the same order with the same [DrawingStroke.stamp] (the fingerprint the saves and [strokeBounds] go by).
/// The clusters handed out are the kept ones, so their [InkCluster.key] is worked out once.
///
/// Working out the stamps of every stroke is most of the cost of a look (5 ms for 5000 strokes on a desktop, against 0.3 without), so
/// [of] only does it when asked to ([stamps]: after the editor said the ink changed); otherwise the same stroke objects with as many
/// points each count as unchanged, which is what a new stroke, an erased one or one being drawn changes.
class PageClusters {
  final Map<(int, bool), ({List<DrawingStroke> strokes, List<int> lengths, List<int> stamps, List<InkCluster> clusters})> _kept = {};

  /// The clusters of [page], whose strokes are [strokes] (see [clusterStrokes] for [rows]).
  List<InkCluster> of(int page, List<DrawingStroke> strokes, {bool rows = false, bool stamps = true}) {
    final kept = _kept[(page, rows)];
    if (kept != null && kept.strokes.length == strokes.length) {
      var same = true;
      for (var i = 0; i < strokes.length && same; i++) {
        same = identical(kept.strokes[i], strokes[i]) && kept.lengths[i] == strokes[i].points.length;
      }
      if (same && stamps) {
        for (var i = 0; i < strokes.length && same; i++) {
          same = kept.stamps[i] == strokes[i].stamp;
        }
      }
      if (same) return kept.clusters;
    }
    final clusters = List<InkCluster>.unmodifiable(clusterStrokes(page, strokes, rows: rows));
    _kept[(page, rows)] = (
      strokes: List.of(strokes),
      lengths: [for (final s in strokes) s.points.length],
      stamps: [for (final s in strokes) s.stamp],
      clusters: clusters,
    );
    return clusters;
  }

  /// Forgets the pages that are not among [pages] (deleted ones).
  void keepOnly(Iterable<int> pages) {
    final alive = pages.toSet();
    _kept.removeWhere((k, _) => !alive.contains(k.$1));
  }

  void clear() => _kept.clear();
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

  /// Makes the pieces that have any of [these] one piece (a sum sign with its limits).
  void together(Set<DrawingStroke> these) {
    final joined = [for (final p in pieces) if (p.any(these.contains)) ...p];
    pieces
      ..removeWhere((p) => p.any(these.contains))
      ..add(joined);
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

/// The lines of writing in [strokes] for reading them as text, top to bottom: the rows of [rowsOf] without the cut at a label (that
/// is for the formula reader; a line of text reads better whole). Every stroke is in one line.
List<List<DrawingStroke>> linesOfWriting(List<DrawingStroke> strokes) {
  if (strokes.isEmpty) return const [];
  final bounds = strokes.map(strokeBounds).reduce((a, b) => a.expandToInclude(b));
  return _adoptSpecks([for (final row in _rowsByBands(InkCluster(0, strokes, bounds))) row.strokes]);
}

/// A line of one or two small strokes (the 4 under a fraction bar, the 2 of a subscript) that the cut put on a line of its own is
/// given back to the line it is written against: one that has a stroke within a letter beside it and lies at most half a letter above
/// or below it, or under a bar of it. A label (`er:`) has more strokes than that and stays where it is.
List<List<DrawingStroke>> _adoptSpecks(List<List<DrawingStroke>> lines) {
  if (lines.length < 2) return lines;
  final boxes = {for (final l in lines) for (final s in l) s: strokeBounds(s)};
  final letter = letterHeight(boxes.values);
  Rect around(List<DrawingStroke> l) => l.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b));
  final merged = [for (final l in lines) List.of(l)];
  final gone = <int>{};
  for (var i = 0; i < lines.length; i++) {
    final speck = around(lines[i]);
    if (lines[i].length > 2 || speck.height > 1.3 * letter || speck.width > 0.8 * letter) continue;
    final small = speck.height <= 0.5 * letter; // (a figure under a bar is as big as any letter)
    int? best;
    var bestGap = double.infinity;
    for (var j = 0; j < lines.length; j++) {
      if (j == i || gone.contains(j) || lines[j].length < 4) continue;
      final host = around(lines[j]);
      final up = math.max(0.0, math.max(host.top - speck.bottom, speck.top - host.bottom));
      // (under a fraction bar of the line: a flat stroke over the speck, at most a letter above it)
      final underBar = lines[j].any((s) {
        final b = boxes[s]!;
        return b.width >= 2.5 * b.height && b.left - 0.3 * letter <= speck.center.dx && b.right + 0.3 * letter >= speck.center.dx && speck.top - b.bottom >= -0.2 * letter && speck.top - b.bottom <= 1.3 * letter;
      });
      if ((!small && !underBar) || (up > 0.5 * letter && !underBar) || speck.center.dx < host.left - 0.5 * letter || speck.center.dx > host.right + 0.5 * letter) continue;
      final beside = lines[j].any((s) {
        final b = boxes[s]!;
        return math.max(0.0, math.max(b.left - speck.right, speck.left - b.right)) <= letter && b.top < speck.bottom + 0.5 * letter && b.bottom > speck.top - 0.5 * letter;
      });
      if ((beside || underBar) && up < bestGap) {
        best = j;
        bestGap = up;
      }
    }
    if (best == null) continue;
    merged[best].addAll(lines[i]);
    gone.add(i);
  }
  return [for (var i = 0; i < merged.length; i++) if (!gone.contains(i)) merged[i]];
}

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

  // a matrix is one piece, brackets and all: its rows are not rows of writing
  final matrices = matricesIn(strokes, boxes, letter);
  final brackets = {for (final m in matrices) ...[m.first, m.last]};
  final tall = [for (final s in strokes) if (boxes[s]!.height > 2.5 * letter && !brackets.contains(s)) s];
  final normal = [for (final s in strokes) if (!tall.contains(s)) s]..sort((a, b) => boxes[a]!.top.compareTo(boxes[b]!.top));
  if (normal.isEmpty) return [cluster];

  // the parts of one fraction (or the stroke over a root and what is under it) are one piece before the lines are told apart: a line with
  // several fractions has all of its numerators at one height and all of its denominators at another, and those would be rows of their own
  final stems = _dotsOnStems(normal, boxes, letter);
  final pieces = [for (final p in _besideMatrices(_joined(_fractionPieces(normal, boxes, letter), [...matrices, ...stems]), brackets, boxes)) _Band(p, p.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b)))]
    ..sort((a, b) => a.box.top.compareTo(b.box.top));
  // (a piece is placed by its body: the dot of an i is in the piece of its stem, and may reach up into the line above)
  final dots = {for (final d in stems) d.first};
  double topOf(_Band piece) {
    final body = [for (final s in piece.strokes) if (!dots.contains(s)) boxes[s]!.top];
    return body.isEmpty ? piece.box.top : body.reduce(math.min);
  }

  pieces.sort((a, b) => topOf(a).compareTo(topOf(b)));
  var bands = <_Band>[];
  for (final piece in pieces) {
    if (bands.isNotEmpty && topOf(piece) <= bands.last.box.bottom + 0.05 * letter) {
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
      final found = _hostOf(bands, i, boxes, letter);
      if (found != null) {
        final (host, sign) = found;
        final small = bands.removeAt(i);
        final into = bands[host > i ? host - 1 : host];
        into.absorb(small);
        if (sign != null) into.together({...sign, ...small.strokes});
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
    // (lines that run uphill or downhill touch at their ends, though they are clear of each other along their slant: two of them are a band
    // not much taller than one straight line, and are cut along the slant)
    // (and lines written close together touch with their tails, a band not much taller than one line: those too are looked for, carefully)
    // (measured by the body of the writing: in joined-up writing a word is one stroke, ascenders and descenders and all, and the letter
    // size taken from the heights of the strokes is about twice what the lines are apart for)
    final unit = _lineUnit(band.strokes, boxes, letter);
    final slope = _slopeOf(band.pieces, boxes, unit);
    if (band.box.height > 2.2 * unit && band.strokes.length > 1) {
      // (straight across as ever for a band far taller than a line, and carefully along its slant: whichever tells more lines apart)
      final straight = band.box.height > 4.5 * letter ? _byCentres(band.pieces, boxes, 1.1 * letter, letter) : [band.strokes];
      final careful = _byCentres(band.pieces, boxes, 1.1 * unit, unit, slope: slope, onlyLines: true, tall: [for (final t in tall) boxes[t]!]);
      parts.addAll(careful.length > straight.length ? careful : straight);
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

/// [pieces] with what is written beside a matrix (a piece that holds one of [brackets]) made one with it: `A = (...) = L U` is one row
/// although the middle of the matrix is lower than the middle of the `A`, and lines are cut where middles are far apart.
List<List<DrawingStroke>> _besideMatrices(List<List<DrawingStroke>> pieces, Set<DrawingStroke> brackets, Map<DrawingStroke, Rect> boxes) {
  if (brackets.isEmpty) return pieces;
  Rect boxOf(List<DrawingStroke> p) => p.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b));
  final matrices = [for (final p in pieces) if (p.any(brackets.contains)) p];
  final spans = [for (final m in matrices) boxOf(m)];
  final out = [for (final m in matrices) [...m]];
  final rest = <List<DrawingStroke>>[];
  for (final p in pieces) {
    if (p.any(brackets.contains)) continue;
    final y = boxOf(p).center.dy;
    final at = spans.indexWhere((m) => y >= m.top && y <= m.bottom);
    if (at < 0) {
      rest.add(p);
    } else {
      out[at].addAll(p);
    }
  }
  return [...out, ...rest];
}

/// The dots of i's and j's in [strokes], each with the stem right under it: in crowded lines a dot is as near to the line above, whose
/// tails reach down past it.
List<List<DrawingStroke>> _dotsOnStems(List<DrawingStroke> strokes, Map<DrawingStroke, Rect> boxes, double letter) {
  final out = <List<DrawingStroke>>[];
  for (final dot in strokes) {
    final d = boxes[dot]!;
    if (d.height > 0.4 * letter || d.width > 0.4 * letter) continue;
    // (a dot stands alone at its height: a small stroke with letters of its size right beside it is a letter, the e of a word; strokes that
    // reach far past it, a t beside the i or a tail from the line above, do not count)
    final beside = strokes.any((s) {
      final b = boxes[s]!;
      final dx = math.max(0.0, math.max(b.left - d.right, d.left - b.right));
      return s != dot && dx <= 0.3 * letter && b.top >= d.top - 0.5 * letter && b.bottom <= d.bottom + 0.5 * letter && b.height > d.height;
    });
    if (beside) continue;
    DrawingStroke? stem;
    var nearest = double.infinity;
    for (final s in strokes) {
      final b = boxes[s]!;
      if (s == dot || b.width > 0.5 * letter || b.height < 0.4 * letter || (b.center.dx - d.center.dx).abs() > 0.35 * letter) continue;
      final gap = b.top - d.bottom;
      if (gap < -0.1 * letter || gap > 1.0 * letter || gap >= nearest) continue;
      nearest = gap;
      stem = s;
    }
    if (stem != null) out.add([dot, stem]);
  }
  return out;
}

/// [pieces] with those that have strokes of one of [together] made one.
List<List<DrawingStroke>> _joined(List<List<DrawingStroke>> pieces, List<List<DrawingStroke>> together) {
  if (together.isEmpty) return pieces;
  final parent = List.generate(pieces.length, (i) => i);
  int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
  final pieceOf = {for (var i = 0; i < pieces.length; i++) for (final s in pieces[i]) s: i};
  for (final group in together) {
    final at = [for (final s in group) if (pieceOf[s] != null) pieceOf[s]!];
    for (final i in at) {
      parent[find(i)] = find(at.first);
    }
  }
  final out = <int, List<DrawingStroke>>{};
  for (var i = 0; i < pieces.length; i++) {
    out.putIfAbsent(find(i), () => []).addAll(pieces[i]);
  }
  return out.values.toList();
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
    // (the numerator is what is stacked on the bar, up to the first clear gap: a line of writing above it is not, however near; and so for the
    // denominator under it)
    List<int> stacked(List<int> side, bool up) {
      // (only what is over the bar itself makes the stack; what is in the margin beside its ends is left as it was found)
      final margin = [for (final j in side) if (boxes[strokes[j]]!.center.dx < bar.left || boxes[strokes[j]]!.center.dx > bar.right) j];
      final order = [for (final j in side) if (!margin.contains(j)) j]..sort((a, b) => up ? boxes[strokes[b]]!.bottom.compareTo(boxes[strokes[a]]!.bottom) : boxes[strokes[a]]!.top.compareTo(boxes[strokes[b]]!.top));
      var edge = up ? bar.top : bar.bottom;
      final out = <int>[];
      for (final j in order) {
        final b = boxes[strokes[j]]!;
        // (the nearest may be well off the bar; the rest of it touches what is already in it, or nearly)
        if (out.isNotEmpty && (up ? b.bottom < edge - 0.6 * letter : b.top > edge + 0.6 * letter)) break;
        out.add(j);
        edge = up ? math.min(edge, b.top) : math.max(edge, b.bottom);
      }
      return [...out, ...margin];
    }

    if (above.isNotEmpty) {
      final keep = stacked(above, true).toSet();
      above.removeWhere((j) => !keep.contains(j));
    }
    if (below.isNotEmpty) {
      final keep = stacked(below, false).toSet();
      below.removeWhere((j) => !keep.contains(j));
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

    // (a wide bar can have a whole formula over it: about four strokes to a letter's width of it)
    // (but only when it is one line of formula, not several, as the rows are told apart: a sum with its limits is one line)
    bool oneLine(List<int> side) => side.length <= _longestPart || linesOfWriting([for (final j in side) strokes[j]]).length == 1;

    final longest = oneLine(above) && oneLine(below) ? math.max(_longestPart, (4 * bar.width / letter).round()) : _longestPart;
    if (above.isNotEmpty && below.isNotEmpty && above.length <= longest && below.length <= longest && within(above, 3 * letter + 0.5 * bar.width) && within(below, 3 * letter + 0.5 * bar.width) && evenlySpaced()) {
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
/// null when it is not small or has no such band; with the strokes of the sign it is the limits of (a sum), if it is.
(int, List<DrawingStroke>?)? _hostOf(List<_Band> bands, int i, Map<DrawingStroke, Rect> boxes, double letter) {
  final small = bands[i];
  // (a script, an accent, a limit or a dot: narrow, lower than the host, and not a line of its own; the bigger it is, the
  // closer it has to be)
  final height = small.box.height;
  if (height > 1.3 * letter || small.box.width > 3 * letter) return null;
  final reach = height <= 0.6 * letter ? 0.8 : (height <= 0.85 * letter ? 0.5 : 0.25);
  (int, List<DrawingStroke>?)? best;
  var bestDistance = double.infinity;
  for (final j in [i - 1, i + 1]) {
    if (j < 0 || j >= bands.length) continue;
    if (bands[j].box.height < 1.2 * height) continue;
    // it belongs to the glyph it sits next to: the distance to the nearest stroke, not to the whole line
    var distance = double.infinity;
    Rect? nearest;
    for (final s in bands[j].strokes) {
      final b = boxes[s]!;
      final dx = math.max(0.0, math.max(small.box.left - b.right, b.left - small.box.right));
      final dy = math.max(0.0, math.max(small.box.top - b.bottom, b.top - small.box.bottom));
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < distance) {
        distance = d;
        nearest = b;
      }
    }
    // the limits of a sum (or of an integral, a product) have their middle under (or over) the one sign they hang from, which is about as
    // wide as they are, where a line of words lies under several letters, or under a joined-up word far wider than it. They may be a little
    // further off than other small parts: a handwritten sum sign is often no taller than a letter, and its limits are letter sized
    // (the sign is all the strokes of the line over or under the middle of the limits: a sum sign is often written in several strokes)
    final centre = small.box.center.dx;
    final column = [for (final s in bands[j].strokes) if (boxes[s]!.left <= centre && centre <= boxes[s]!.right) s];
    final sign = column.isEmpty ? null : column.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b));
    final oneSign = sign != null && sign.height >= math.max(height, 1.3 * letter) && sign.width <= 2.5 * small.box.width && small.box.width <= 2.5 * sign.width;
    if (distance > (oneSign ? math.max(reach, 0.8) : reach) * letter || distance >= bestDistance) continue;
    // a few small letters wholly below an ordinary letter ("so", "an" on a line of their own) are a line: what hangs under a letter
    // is a subscript, which overlaps it, or the limits of a sum
    if (small.strokes.length >= 2 && small.box.top >= bands[j].box.bottom && nearest!.height < 1.3 * letter && !oneSign) continue;
    best = (j, oneSign ? column : null);
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
List<List<DrawingStroke>> _byCentres(List<List<DrawingStroke>> pieces, Map<DrawingStroke, Rect> boxes, double gap, double letter, {double slope = 0, bool onlyLines = false, List<Rect> tall = const []}) {
  Rect boxOf(List<DrawingStroke> p) => p.map((s) => boxes[s]!).reduce((a, b) => a.expandToInclude(b));
  // (the height of a middle along the slant of the lines)
  // (carefully, by where most of its ink is: the middle of a box moves with every ascender and descender of a joined-up word)
  final inkLevel = <List<DrawingStroke>, double>{};
  double middleOf(List<DrawingStroke> p) => onlyLines ? inkLevel.putIfAbsent(p, () => _medianY(p)) : boxOf(p).center.dy;
  double level(List<DrawingStroke> p) => middleOf(p) - slope * boxOf(p).center.dx;
  final everything = [for (final p in pieces) ...p];
  final anchors = [for (final p in pieces) if (boxOf(p).height >= 0.45 * letter) p]..sort((a, b) => level(a).compareTo(level(b)));
  final loose = [for (final p in pieces) if (boxOf(p).height < 0.45 * letter) p];
  if (anchors.length < 2) return [everything];

  double middle(List<List<DrawingStroke>> side) => level(side[side.length ~/ 2]);
  List<List<List<DrawingStroke>>> cut(List<List<DrawingStroke>> side) {
    if (side.length < 2) return [side];
    var at = 0;
    var widest = double.negativeInfinity;
    for (var i = 1; i < side.length; i++) {
      final d = level(side[i]) - level(side[i - 1]);
      if (d > widest) {
        widest = d;
        at = i;
      }
    }
    final above = side.sublist(0, at), below = side.sublist(at);
    if (onlyLines) {
      // (carefully: only lines are cut apart, each of several letters and across much of the band, not a script or a fraction off its line)
      double width(List<List<DrawingStroke>> g) => g.map(boxOf).reduce((a, b) => a.expandToInclude(b)).width;
      final across = width(side);
      // (a line of joined-up writing has a stroke a word: two of them make a short line)
      // (or a line of a few words, as the last line of a paragraph is)
      final wide = math.min(0.3 * across, 8 * letter);
      if (math.min(above.length, below.length) < 2 || width(above) < wide || width(below) < wide) return [side];
    }
    final real = widest > gap;
    final robust = widest >= 0.7 * letter && math.min(above.length, below.length) >= math.max(3, 0.2 * side.length) && middle(below) - middle(above) >= 1.6 * letter;
    if (!real && !robust) return [side];
    return [...cut(above), ...cut(below)];
  }

  final groups = cut(anchors);
  if (groups.length == 1) return [everything];
  if (onlyLines) {
    // (an exponent's middle is as high as the line above's: it is the lower line's when it touches the top end of a much taller stroke of it, `(p)³`)
    for (var g = 0; g + 1 < groups.length; g++) {
      for (final p in [...groups[g]]) {
        final b = boxOf(p);
        if (b.height > letter) continue;
        // (the tall strokes, a big bracket, are not in the groups: they go to the line they overlap most)
        Rect span(List<List<DrawingStroke>> g) => g.map(boxOf).reduce((a, b) => a.expandToInclude(b));
        final upper = span(groups[g]), lower = span(groups[g + 1]);
        double overlap(Rect a, Rect b) => math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
        final base = [...groups[g + 1].map(boxOf), ...tall.where((c) => overlap(c, lower) > overlap(c, upper))].any((c) {
          final dx = math.max(0.0, math.max(c.left - b.right, b.left - c.right));
          return c.height >= 2 * b.height && dx <= 0.3 * letter && b.top >= c.top - 0.3 * letter && b.bottom <= c.center.dy;
        });
        if (base) {
          groups[g].remove(p);
          groups[g + 1].add(p);
        }
      }
    }
    groups.removeWhere((g) => g.isEmpty);
    if (groups.length == 1) return [everything];
  }
  final extents = [for (final g in groups) g.map(boxOf).reduce((a, b) => a.expandToInclude(b))];
  for (final p in loose) {
    final b = boxOf(p);
    if (onlyLines) {
      // (along the slant: the group whose middles are nearest)
      var best = 0;
      var nearest = double.infinity;
      for (var i = 0; i < groups.length; i++) {
        final d = (level(p) - groups[i].map(level).reduce((a, b) => a + b) / groups[i].length).abs();
        if (d < nearest) {
          nearest = d;
          best = i;
        }
      }
      groups[best].add(p);
      continue;
    }
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

/// The height of the body of the writing in [strokes] (where most of each stroke's ink is, about the height of an x) times two, or [letter]
/// if that is less: about a letter's height for printed writing, much less than [letter] for joined-up writing.
double _lineUnit(List<DrawingStroke> strokes, Map<DrawingStroke, Rect> boxes, double letter) {
  final bodies = <double>[];
  for (final s in strokes) {
    if (boxes[s]!.height <= 0.3 * letter || s.points.length < 4) continue;
    final ys = [for (final p in s.points) p.dy]..sort();
    bodies.add(ys[3 * ys.length ~/ 4] - ys[ys.length ~/ 4]);
  }
  if (bodies.length < 4) return letter;
  bodies.sort();
  return (2 * bodies[bodies.length ~/ 2]).clamp(0.4 * letter, letter);
}

/// The median height of the points of [strokes].
double _medianY(List<DrawingStroke> strokes) {
  final ys = [for (final s in strokes) for (final p in s.points) p.dy]..sort();
  return ys.isEmpty ? 0 : ys[ys.length ~/ 2];
}

/// How much the lines of writing of [pieces] run uphill or downhill (down the page per unit across), from the middles of the letters: 0 when
/// there are too few of them, or they are not spread across enough to tell.
double _slopeOf(List<List<DrawingStroke>> pieces, Map<DrawingStroke, Rect> boxes, double letter) {
  // (from neighbours on one line: each letter or word and the next one to its right at about its height. A fit through all of them would take
  // a short line under a long one, on its left, for a slant)
  // (a joined-up word is wide: the next one is next by the gap between them, not by how far apart their middles are)
  final words = [
    for (final p in pieces)
      if (p.length == 1 && boxes[p.single]!.height >= 0.45 * letter && boxes[p.single]!.height <= 3 * letter) (box: boxes[p.single]!, middle: _medianY(p)),
  ]..sort((a, b) => a.box.left.compareTo(b.box.left));
  final slopes = <double>[];
  for (var i = 0; i < words.length; i++) {
    for (var j = i + 1; j < words.length; j++) {
      final a = words[i], b = words[j];
      if (b.box.left - a.box.right > 3 * letter) break;
      final dx = b.box.center.dx - a.box.center.dx, dy = b.middle - a.middle;
      if (dx < letter || dy.abs() > 0.5 * letter + 0.04 * dx) continue;
      slopes.add(dy / dx);
      break;
    }
  }
  if (slopes.length < 6) return 0;
  slopes.sort();
  return slopes[slopes.length ~/ 2].clamp(-0.1, 0.1);
}

/// Whether the stroke with [box] is a big bracket (`(`, `[`, `{` or their closing ones) of something stacked, at least [tall] high: a narrow
/// stroke whose middle sticks out to the left of its ends (an opening one) or to the right (a closing one). Null when it is not one.
bool? _bracketOpens(DrawingStroke s, Rect box, double tall) {
  if (box.height < tall || box.width > 0.6 * box.height || s.points.length < 3) return null;
  final first = s.points.first, last = s.points.last;
  // the ends are near the top and the bottom of it, as the ends of a bracket are
  if (math.min(first.dy, last.dy) > box.top + 0.25 * box.height || math.max(first.dy, last.dy) < box.bottom - 0.25 * box.height) return null;
  final mid = box.center.dy;
  var middle = s.points.first;
  for (final p in s.points) {
    if ((p.dy - mid).abs() < (middle.dy - mid).abs()) middle = p;
  }
  // (written quickly a bracket is nearly straight: its middle may be only a little off its ends)
  final reach = 0.07 * box.height, past = 0.02 * box.height;
  if (middle.dx < math.min(first.dx, last.dx) - past && middle.dx < (first.dx + last.dx) / 2 - reach) return true;
  if (middle.dx > math.max(first.dx, last.dx) + past && middle.dx > (first.dx + last.dx) / 2 + reach) return false;
  return null;
}

/// The matrices (and vectors) in [strokes]: the strokes of each one, its two big brackets and what is between them, which is written in rows
/// and columns with gaps wider than a word's. An opening bracket goes with the nearest closing one to its right of about its height and on its
/// line; what is between them must be stacked (two rows at least), or the pair is two tall letters of a word. [letter] is how high a letter is.
List<List<DrawingStroke>> matricesIn(List<DrawingStroke> strokes, Map<DrawingStroke, Rect> boxes, double letter) {
  final opens = <DrawingStroke>[], closes = <DrawingStroke>[];
  for (final s in strokes) {
    final kind = _bracketOpens(s, boxes[s]!, 1.6 * letter);
    if (kind == true) opens.add(s);
    if (kind == false) closes.add(s);
  }
  if (opens.isEmpty || closes.isEmpty) return const [];
  final used = <DrawingStroke>{};
  final out = <List<DrawingStroke>>[];
  for (final o in opens..sort((a, b) => boxes[a]!.left.compareTo(boxes[b]!.left))) {
    final a = boxes[o]!;
    DrawingStroke? best;
    for (final c in closes) {
      final b = boxes[c]!;
      if (used.contains(c) || b.left < a.right || b.left - a.right > 12 * letter) continue;
      final shared = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
      if (shared < 0.6 * math.min(a.height, b.height) || math.max(a.height, b.height) > 1.6 * math.min(a.height, b.height)) continue;
      if (best == null || b.left < boxes[best]!.left) best = c;
    }
    if (best == null) continue;
    final b = boxes[best]!;
    final inside = Rect.fromLTRB(a.left, math.min(a.top, b.top), b.right, math.max(a.bottom, b.bottom));
    final within = [
      for (final s in strokes)
        if (s != o && s != best && inside.contains(boxes[s]!.center)) s,
    ];
    // stacked: something is written in the top part between the brackets and something in the bottom part, at least a letter apart (in
    // `(M - \bar{I})` the bar is over the letter, not a row of its own)
    final middles = [for (final s in within) if (boxes[s]!.height >= 0.3 * letter || boxes[s]!.width >= 0.3 * letter) boxes[s]!.center.dy];
    final top = middles.where((y) => y <= inside.top + 0.4 * inside.height), bottom = middles.where((y) => y >= inside.bottom - 0.4 * inside.height);
    if (top.isEmpty || bottom.isEmpty || bottom.reduce(math.max) - top.reduce(math.min) < 1.0 * letter) continue;
    used.add(best);
    out.add([o, ...within, best]);
  }
  return out;
}
