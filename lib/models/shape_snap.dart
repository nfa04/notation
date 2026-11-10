import 'dart:math' as math;
import 'dart:ui';

import 'shapes.dart';

/// The smallest side of a drawing that is made a shape, in page units (the page is 800 wide: about 12 mm on an A4 page). Smaller ones
/// are letters - an "o" must stay an "o".
const smallestShape = 45.0;

/// A hand-drawn closed stroke that is very close to one of the shapes of the shape tool (rectangle, ellipse, triangle, diamond), as that
/// shape: the tool and its points. Null when the stroke is open, too small, a scribble, or not close enough to any of them.
///
/// The shape is the one the tool would draw from corner to corner of the box around the stroke, so a drawing that is turned by a few
/// degrees still becomes the upright shape and one turned by 45 degrees is a diamond. How close is close: on average within 3.5 % of the
/// diagonal of the box of the shape's outline, and no part of the outline left out.
({ShapeTool tool, List<Offset> points})? snapToShape(List<Offset> points) {
  if (points.length < 12) return null;
  var left = double.infinity, top = double.infinity, right = -double.infinity, bottom = -double.infinity;
  var path = 0.0;
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    left = math.min(left, p.dx);
    top = math.min(top, p.dy);
    right = math.max(right, p.dx);
    bottom = math.max(bottom, p.dy);
    if (i > 0) path += (p - points[i - 1]).distance;
  }
  final w = right - left, h = bottom - top;
  if (w < smallestShape || h < smallestShape) return null;
  final diag = math.sqrt(w * w + h * h);
  // closed: it comes back to where it began (a little overshoot or gap is the hand)
  if ((points.first - points.last).distance > math.max(0.12 * path, 6.0)) return null;
  // not a scribble over the same place again and again
  if (path > 2 * (w + h) * 1.4) return null;

  final drawn = _resample(points, 120);
  final a = Offset(left, top), b = Offset(right, bottom);
  ({ShapeTool tool, double error})? best;
  for (final tool in const [ShapeTool.rectangle, ShapeTool.ellipse, ShapeTool.triangle, ShapeTool.diamond]) {
    final outline = shapePoints(tool, a, b, step: 4);
    final ideal = _resample(outline, 160);
    var sum = 0.0, worst = 0.0;
    for (final p in drawn) {
      final d = _nearest(p, ideal);
      sum += d;
      worst = math.max(worst, d);
    }
    final mean = sum / drawn.length;
    var uncovered = 0.0; // the part of the outline that is furthest from anything drawn
    for (final q in ideal) {
      uncovered = math.max(uncovered, _nearest(q, drawn));
    }
    if (mean > 0.035 * diag + 1 || worst > 0.1 * diag || uncovered > 0.12 * diag) continue;
    final error = mean + 0.5 * uncovered;
    if (best == null || error < best.error) best = (tool: tool, error: error);
  }
  if (best == null) return null;
  return (tool: best.tool, points: shapePoints(best.tool, a, b));
}

double _nearest(Offset p, List<Offset> among) {
  var best = double.infinity;
  for (final q in among) {
    final dx = p.dx - q.dx, dy = p.dy - q.dy;
    best = math.min(best, dx * dx + dy * dy);
  }
  return math.sqrt(best);
}

/// [points] as about [n] points evenly spaced along the line.
List<Offset> _resample(List<Offset> points, int n) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += (points[i] - points[i - 1]).distance;
  }
  if (total == 0) return [points.first];
  final step = total / n;
  final out = <Offset>[points.first];
  var carried = 0.0;
  for (var i = 1; i < points.length; i++) {
    var from = points[i - 1];
    final to = points[i];
    var len = (to - from).distance;
    while (carried + len >= step && len > 0) {
      final t = (step - carried) / len;
      from = Offset.lerp(from, to, t)!;
      out.add(from);
      len = (to - from).distance;
      carried = 0;
    }
    carried += len;
  }
  out.add(points.last);
  return out;
}
