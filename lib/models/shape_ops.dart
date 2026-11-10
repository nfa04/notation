import 'dart:math' as math;
import 'dart:ui';

/// How closed shapes are put together.
enum ShapeOp {
  union('Join (union)', PathOperation.union),
  intersect('Keep only the overlap', PathOperation.intersect),
  subtract('Cut the upper shapes out of the lowest', PathOperation.difference),
  exclude('Keep all but the overlap', PathOperation.xor);

  final String label;
  final PathOperation operation;
  const ShapeOp(this.label, this.operation);
}

Path _pathOf(List<Offset> points) {
  final p = Path()..moveTo(points.first.dx, points.first.dy);
  for (final q in points.skip(1)) {
    p.lineTo(q.dx, q.dy);
  }
  return p..close();
}

/// [shapes] (closed outlines, the lowest first) put together by [op]: what comes out as outlines, each with about [step] between
/// its points and closed (the first point is the last). Subtracting takes all the others out of the first; the other operations
/// treat all alike. Where the result has several pieces, or a hole, each is an outline of its own, the largest first.
List<List<Offset>> combineShapes(List<List<Offset>> shapes, ShapeOp op, {double step = 4}) {
  final usable = [for (final s in shapes) if (s.length >= 3) s];
  if (usable.isEmpty) return const [];
  var result = _pathOf(usable.first);
  for (final next in usable.skip(1)) {
    result = Path.combine(op.operation, result, _pathOf(next));
  }
  final outlines = <List<Offset>>[];
  for (final metric in result.computeMetrics()) {
    if (metric.length < step) continue;
    final points = <Offset>[];
    final n = math.max(8, (metric.length / step).ceil());
    for (var i = 0; i < n; i++) {
      points.add(metric.getTangentForOffset(metric.length * i / n)!.position);
    }
    points.add(points.first);
    outlines.add(points);
  }
  double area(List<Offset> pts) {
    var sum = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      sum += pts[i].dx * pts[i + 1].dy - pts[i + 1].dx * pts[i].dy;
    }
    return sum.abs() / 2;
  }

  return outlines..sort((a, b) => area(b).compareTo(area(a)));
}

/// Whether the point [p] lies inside the closed outline [shape] (even-odd).
bool insideOutline(List<Offset> shape, Offset p) {
  var inside = false;
  for (var i = 0, j = shape.length - 1; i < shape.length; j = i++) {
    final a = shape[i], b = shape[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) && p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) inside = !inside;
  }
  return inside;
}
