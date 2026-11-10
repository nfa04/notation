import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'canvas_models.dart';

/// Why [regionAround] found nothing to fill.
enum RegionProblem {
  /// Nothing is drawn that could close an area.
  noLines,

  /// The area runs out to the edge: the lines do not close it (a bigger gap closing may).
  open,

  /// The touch is on a line, and no free place is near it.
  onLine,
}

/// The closed area found round a touch: [outline] is a polygon that ends where it began (a hole in the area is joined to the outline by
/// a seam, which is walked there and back, so it takes no room), or [problem] says why there is none.
class RegionResult {
  final List<Offset>? outline;
  final RegionProblem? problem;

  const RegionResult.found(List<Offset> this.outline) : problem = null;
  const RegionResult.none(RegionProblem this.problem) : outline = null;
}

/// How much of a gap in the lines still closes an area, in page units.
enum FillGap {
  none('No gap closing', 0),
  small('Small gaps', 5),
  medium('Medium gaps', 12),
  large('Large gaps', 26);

  final String label;
  final double units;
  const FillGap(this.label, this.units);
}

/// A fill that the bucket made: a closed shape with a fill and no line of its own.
bool isBucketFill(DrawingStroke s) => s.fill != null && s.color.a == 0 && s.link == null;

/// Picking a drawing by a touch: its line within [radius] or, for a fill of the bucket (whose line cannot be seen), anywhere in its area.
extension StrokePicking on DrawingStroke {
  bool pickedAt(Offset at, double radius) => isNear(at, radius) || (isBucketFill(this) && pointInPolygon(at, points));
}

/// The area that the lines of [walls] close round [at], for a fill that goes under them. The lines are drawn on a grid as wide as they
/// are ([width] counts, thin lines are widened to about two cells), a gap of up to [gap] units between them is closed, and the area
/// is what can be reached from [at]. The fill is then pushed under the lines (as far as their middle), so that no sliver of paper is
/// left beside a line.
///
/// With [page], the area is that page and its edge is a wall (a fill may reach the edge of the paper); without it, the area runs out
/// as far as the lines go, and one that reaches the end is not closed ([RegionProblem.open]).
RegionResult regionAround(Offset at, Iterable<DrawingStroke> walls, {Rect? page, double gap = 0, int maxCells = 1000}) {
  final lines = [for (final s in walls) if (!isBucketFill(s) && s.points.length >= 2) s];
  if (lines.isEmpty) return const RegionResult.none(RegionProblem.noLines);

  var widest = 0.0;
  for (final s in lines) {
    widest = math.max(widest, s.width);
  }

  // the grid: the page, or the box round the lines (and the touch)
  Rect area;
  if (page != null) {
    area = page;
  } else {
    var box = Rect.fromPoints(at, at);
    for (final s in lines) {
      box = box.expandToInclude(_boundsOf(s.points));
    }
    area = box.inflate(widest + gap + 12);
  }
  var cell = math.max(0.5, math.max(area.width, area.height) / maxCells);
  if (gap > 0) cell = math.max(cell, gap / 16); // (a gap is closed in at most eight steps)
  final cols = (area.width / cell).ceil() + 1, rows = (area.height / cell).ceil() + 1;
  if (cols < 3 || rows < 3) return const RegionResult.none(RegionProblem.noLines);
  final walled = Uint8List(cols * rows);

  void stamp(double cx, double cy, double radius) {
    final r = radius / cell;
    final x0 = math.max(0, (cx - r).floor()), x1 = math.min(cols - 1, (cx + r).ceil());
    final y0 = math.max(0, (cy - r).floor()), y1 = math.min(rows - 1, (cy + r).ceil());
    for (var y = y0; y <= y1; y++) {
      final dy = y + 0.5 - cy;
      for (var x = x0; x <= x1; x++) {
        final dx = x + 0.5 - cx;
        if (dx * dx + dy * dy <= r * r) walled[y * cols + x] = 1;
      }
    }
  }

  for (final s in lines) {
    // (a line is at least two cells thick, so that it has no holes in it)
    final radius = math.max(s.width / 2, cell);
    Offset toGrid(Offset p) => Offset((p.dx - area.left) / cell, (p.dy - area.top) / cell);
    var from = toGrid(s.points.first);
    stamp(from.dx, from.dy, radius);
    for (var i = 1; i < s.points.length; i++) {
      final to = toGrid(s.points[i]);
      final length = (to - from).distance;
      final steps = math.max(1, (length / 0.5).ceil());
      for (var k = 1; k <= steps; k++) {
        final p = Offset.lerp(from, to, k / steps)!;
        stamp(p.dx, p.dy, radius);
      }
      from = to;
    }
  }

  // closing the gaps: the lines are grown by half of the gap
  final grow = gap <= 0 ? 0 : math.max(1, (gap / 2 / cell).round());
  for (var i = 0; i < grow; i++) {
    _dilate(walled, cols, rows, diagonal: i.isOdd);
  }

  // the cell of the touch, or the nearest free one if the touch is on a line
  var sx = ((at.dx - area.left) / cell).floor(), sy = ((at.dy - area.top) / cell).floor();
  if (sx < 0 || sy < 0 || sx >= cols || sy >= rows) return const RegionResult.none(RegionProblem.open);
  if (walled[sy * cols + sx] != 0) {
    final reach = (widest / 2 / cell).ceil() + 4 + grow;
    var best = -1, bestD = double.infinity;
    for (var y = math.max(0, sy - reach); y <= math.min(rows - 1, sy + reach); y++) {
      for (var x = math.max(0, sx - reach); x <= math.min(cols - 1, sx + reach); x++) {
        if (walled[y * cols + x] != 0) continue;
        final d = ((x - sx) * (x - sx) + (y - sy) * (y - sy)).toDouble();
        if (d < bestD) {
          bestD = d;
          best = y * cols + x;
        }
      }
    }
    if (best < 0) return const RegionResult.none(RegionProblem.onLine);
    sx = best % cols;
    sy = best ~/ cols;
  }

  // the flood from the touch
  final region = Uint8List(cols * rows);
  final stack = Int32List(cols * rows);
  var top = 0;
  region[sy * cols + sx] = 1;
  stack[top++] = sy * cols + sx;
  var leaked = false;
  while (top > 0) {
    final i = stack[--top];
    final x = i % cols, y = i ~/ cols;
    if (x == 0 || y == 0 || x == cols - 1 || y == rows - 1) leaked = true;
    void visit(int j) {
      if (walled[j] == 0 && region[j] == 0) {
        region[j] = 1;
        stack[top++] = j;
      }
    }

    if (x > 0) visit(i - 1);
    if (x < cols - 1) visit(i + 1);
    if (y > 0) visit(i - cols);
    if (y < rows - 1) visit(i + cols);
  }
  if (leaked && page == null) return const RegionResult.none(RegionProblem.open);

  // under the lines: the area goes into the grown lines, as far as they were grown and to the middle of the line
  var frontier = <int>[];
  for (var i = 0; i < region.length; i++) {
    if (region[i] == 0) continue;
    final x = i % cols, y = i ~/ cols;
    if ((x > 0 && walled[i - 1] != 0) || (x < cols - 1 && walled[i + 1] != 0) || (y > 0 && walled[i - cols] != 0) || (y < rows - 1 && walled[i + cols] != 0)) {
      frontier.add(i);
    }
  }
  for (var step = 0; step < grow + 2 && frontier.isNotEmpty; step++) {
    final next = <int>[];
    for (final i in frontier) {
      final x = i % cols, y = i ~/ cols;
      void into(int j) {
        if (walled[j] != 0 && region[j] == 0) {
          region[j] = 1;
          next.add(j);
        }
      }

      if (x > 0) into(i - 1);
      if (x < cols - 1) into(i + 1);
      if (y > 0) into(i - cols);
      if (y < rows - 1) into(i + cols);
    }
    frontier = next;
  }

  // the edges of the area (the outline, and the outlines of what is inside it that is not filled)
  final loops = _loops(region, cols, rows);
  final tolerance = cell * 1.5; // (the steps of the grid are smoothed over: they lie under the lines)
  Offset toPage(math.Point<int> v) => Offset(area.left + v.x * cell, area.top + v.y * cell);
  List<Offset>? outer;
  var outerArea = 0.0;
  final holes = <List<Offset>>[];
  for (final loop in loops) {
    final size = _signedArea(loop);
    final pts = _simplified([for (final v in loop) toPage(v)], tolerance);
    if (pts.length < 4) continue;
    if (size > 0) {
      if (size > outerArea) {
        outerArea = size;
        outer = pts;
      }
    } else if (-size >= 6) {
      holes.add(pts);
    }
  }
  if (outer == null) return const RegionResult.none(RegionProblem.open);
  var shape = outer;
  for (final hole in holes) {
    shape = _joined(shape, hole);
  }
  return RegionResult.found(shape);
}

Rect _boundsOf(List<Offset> points) {
  var left = double.infinity, top = double.infinity, right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final p in points) {
    left = math.min(left, p.dx);
    right = math.max(right, p.dx);
    top = math.min(top, p.dy);
    bottom = math.max(bottom, p.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// One step of growing the marked cells of [mask] by a cell: to the four sides, or (with [diagonal]) to the diagonals too.
void _dilate(Uint8List mask, int cols, int rows, {required bool diagonal}) {
  final before = Uint8List.fromList(mask);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      final i = y * cols + x;
      if (before[i] != 0) continue;
      var near = (x > 0 && before[i - 1] != 0) || (x < cols - 1 && before[i + 1] != 0) || (y > 0 && before[i - cols] != 0) || (y < rows - 1 && before[i + cols] != 0);
      if (!near && diagonal) {
        near = (x > 0 && y > 0 && before[i - cols - 1] != 0) ||
            (x < cols - 1 && y > 0 && before[i - cols + 1] != 0) ||
            (x > 0 && y < rows - 1 && before[i + cols - 1] != 0) ||
            (x < cols - 1 && y < rows - 1 && before[i + cols + 1] != 0);
      }
      if (near) mask[i] = 1;
    }
  }
}

/// The edges between the marked cells of [mask] and the others, as closed loops of grid corners with the marked cells on the right of
/// the way round: an outline goes clockwise (on a screen, y down), a hole in the area the other way. Where two marked cells touch
/// only by a corner, the loop keeps them together.
List<List<math.Point<int>>> _loops(Uint8List mask, int cols, int rows) {
  bool at(int x, int y) => x >= 0 && y >= 0 && x < cols && y < rows && mask[y * cols + x] != 0;
  final w = cols + 1;
  // the edges leaving each corner, by direction: 0 east, 1 south, 2 west, 3 north
  final out = <int, List<int>>{};
  void edge(int x, int y, int dir) => (out[y * w + x] ??= []).add(dir);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      if (!at(x, y)) continue;
      if (!at(x, y - 1)) edge(x, y, 0);
      if (!at(x + 1, y)) edge(x + 1, y, 1);
      if (!at(x, y + 1)) edge(x + 1, y + 1, 2);
      if (!at(x - 1, y)) edge(x, y + 1, 3);
    }
  }
  const dx = [1, 0, -1, 0], dy = [0, 1, 0, -1];
  final loops = <List<math.Point<int>>>[];
  while (out.isNotEmpty) {
    final start = out.keys.first;
    var x = start % w, y = start ~/ w;
    var dir = out[start]!.first;
    final loop = <math.Point<int>>[];
    while (true) {
      final key = y * w + x;
      final here = out[key];
      if (here == null || !here.contains(dir)) break;
      here.remove(dir);
      if (here.isEmpty) out.remove(key);
      loop.add(math.Point(x, y));
      x += dx[dir];
      y += dy[dir];
      // (at a corner with two ways on, the right turn: the marked cells on the right stay together)
      final next = out[y * w + x];
      if (next == null) break;
      final right = (dir + 1) % 4, straight = dir, left = (dir + 3) % 4;
      dir = next.contains(right) ? right : next.contains(straight) ? straight : left;
    }
    if (loop.length >= 4) loops.add(loop);
  }
  return loops;
}

double _signedArea(List<math.Point<int>> loop) {
  var sum = 0.0;
  for (var i = 0; i < loop.length; i++) {
    final a = loop[i], b = loop[(i + 1) % loop.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum / 2;
}

/// [loop] (one corner after the other, closed implicitly) with the corners that lie within [tolerance] of the line between their
/// neighbours left out, as a polygon that ends where it began.
List<Offset> _simplified(List<Offset> loop, double tolerance) {
  final line = DrawingStroke(color: const Color(0xFF000000), width: 1, points: [...loop, loop.first]);
  line.simplify(tolerance);
  return line.points;
}

/// [outline] with [hole] joined to it by a seam from the nearest corners, walked there and back: one polygon that is filled like the
/// outline and leaves the hole empty (the hole goes the other way round).
List<Offset> _joined(List<Offset> outline, List<Offset> hole) {
  final ring = hole.sublist(0, hole.length - 1);
  var bi = 0, bj = 0;
  var best = double.infinity;
  for (var i = 0; i < outline.length - 1; i++) {
    for (var j = 0; j < ring.length; j++) {
      final d = (outline[i] - ring[j]).distanceSquared;
      if (d < best) {
        best = d;
        bi = i;
        bj = j;
      }
    }
  }
  return [
    ...outline.sublist(0, bi + 1),
    for (var k = 0; k <= ring.length; k++) ring[(bj + k) % ring.length],
    ...outline.sublist(bi),
  ];
}
