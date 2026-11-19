import 'dart:math' as math;
import 'dart:ui';

import 'shapes.dart';

/// The smallest side of a drawing that is made a shape, in page units (the page is 800 wide: about 12 mm on an A4 page). Smaller ones
/// are letters - an "o" must stay an "o".
const smallestShape = 45.0;

/// The shapes a closed drawing is compared with, the plainest first. A plainer shape wins when two fit about as well ([_plainBias]): a
/// rectangle drawn with slightly round corners is a rectangle, not a rounded one.
const _candidates = <(ShapeTool, double)>[
  (ShapeTool.rectangle, 1.0),
  (ShapeTool.ellipse, 1.0),
  (ShapeTool.triangle, 1.0),
  (ShapeTool.diamond, 1.0),
  (ShapeTool.roundedRectangle, _plainBias),
  (ShapeTool.rightTriangle, _plainBias),
  (ShapeTool.parallelogram, _plainBias),
  (ShapeTool.pentagon, _plainBias),
  (ShapeTool.hexagon, _plainBias),
  (ShapeTool.star, _plainBias),
  (ShapeTool.cross, _plainBias),
];
const _plainBias = 1.3;

/// A hand-drawn closed stroke that is very close to one of the shapes of the shape tool (rectangle, ellipse, triangle, diamond and the
/// other closed ones, see [_candidates]), or a long line with an arrow head drawn on it in one go ([snapToArrow]), as that shape: the
/// tool and its points. Null when the stroke is too small, a scribble, or not close enough to any of them.
///
/// The shape is the one the tool would draw from corner to corner of the box around the stroke, so a drawing that is turned by a few
/// degrees still becomes the upright shape and one turned by 45 degrees is a diamond. How close is close: on average within 3.5 % of the
/// diagonal of the box of the shape's outline, and no part of the outline left out. [looseness] scales every one of these tolerances
/// (see straightenStrengthSetting).
({ShapeTool tool, List<Offset> points})? snapToShape(List<Offset> points, {double looseness = 1}) {
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
  final arrow = snapToArrow(points, looseness: looseness);
  if (arrow != null) return arrow;
  if (w < smallestShape || h < smallestShape) return null;
  final diag = math.sqrt(w * w + h * h);
  // closed: it comes back to where it began (a little overshoot or gap is the hand)
  if ((points.first - points.last).distance > math.max(0.12 * looseness * path, 6.0)) return null;
  // not a scribble over the same place again and again
  if (path > 2 * (w + h) * 1.4) return null;

  final drawn = _resample(points, 120);
  final a = Offset(left, top), b = Offset(right, bottom);
  ({ShapeTool tool, double error})? best;
  for (final (tool, bias) in _candidates) {
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
    // (the shapes that are not the plainest must fit closer: a blob is near enough to a pentagon at the plainest tolerance)
    final fit = (bias == 1.0 ? 1.0 : 0.7) * looseness;
    if (mean > 0.035 * fit * diag + 1 || worst > 0.1 * fit * diag || uncovered > 0.12 * fit * diag) continue;
    final error = (mean + 0.5 * uncovered) * bias;
    if (best == null || error < best.error) best = (tool: tool, error: error);
  }
  if (best == null) return null;
  return (tool: best.tool, points: shapePoints(best.tool, a, b));
}

/// The shortest an arrow is made of a drawing, in page units (a little arrow in a line of text stays as written).
const shortestArrow = 60.0;

/// A line with an arrow head drawn in one go - the line, then a stroke out to one side of its end and back and out to the other side -
/// as the arrow of the shape tool from where the line began to its tip. Null for anything else: a line that bends, a head that is not
/// at the end, or one that is too big or not two-sided.
({ShapeTool tool, List<Offset> points})? snapToArrow(List<Offset> points, {double looseness = 1}) {
  if (points.length < 8) return null;
  final start = points.first;
  // the tip: the point furthest from the start; the line gets there the first time at (about) that distance, and the head is what follows
  var farAt = 0;
  var far = 0.0;
  for (var i = 0; i < points.length; i++) {
    final d = (points[i] - start).distance;
    if (d > far) {
      far = d;
      farAt = i;
    }
  }
  var tipAt = farAt;
  for (var i = 0; i < points.length; i++) {
    if ((points[i] - start).distance >= far - 3.0) {
      tipAt = i;
      break;
    }
  }
  if (far < shortestArrow || tipAt < 3 || points.length - tipAt < 5) return null;
  final tip = points[farAt];
  final unit = (tip - start) / far;
  final normal = Offset(-unit.dy, unit.dx);
  // the way there is a straight line
  var bend = 0.0;
  for (var i = 0; i <= tipAt; i++) {
    bend = math.max(bend, ((points[i] - start).dx * normal.dx + (points[i] - start).dy * normal.dy).abs());
  }
  if (bend > 0.06 * looseness * far) return null;
  // the head: it stays near the tip, on the side the line came from, goes out on both sides of the line and comes back to the tip between
  final head = points.sublist(tipAt);
  var reach = 0.0, left = 0.0, right = 0.0;
  for (final p in head) {
    final rel = p - tip;
    reach = math.max(reach, rel.distance);
    final side = rel.dx * normal.dx + rel.dy * normal.dy;
    left = math.max(left, side);
    right = math.min(right, side);
    if (rel.dx * unit.dx + rel.dy * unit.dy > 4) return null; // (it must not go on past the tip)
  }
  if (reach < 8 || reach > math.min(0.4 * far, 70)) return null;
  if (left < 0.2 * reach || -right < 0.2 * reach) return null; // (both sides)
  var returned = false;
  for (var i = 1; i < head.length - 1; i++) {
    if ((head[i] - tip).distance < 0.25 * reach) returned = true;
  }
  if (!returned) return null;
  return (tool: ShapeTool.arrow, points: shapePoints(ShapeTool.arrow, start, tip));
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
