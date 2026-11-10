import 'dart:math' as math;
import 'dart:ui';

/// Free transform of drawings: the maths of distorting, perspective, skewing, rotating and warping a set of points. A transform is
/// a [PointMap]; the editor applies it to the points of the selected lines.
typedef PointMap = Offset Function(Offset p);

/// The four corners of [r], clockwise from the top left (the order every quad here has).
List<Offset> quadOf(Rect r) => [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

Rect boundsOfPoints(Iterable<Offset> points) {
  Rect? r;
  for (final p in points) {
    r = r == null ? Rect.fromLTRB(p.dx, p.dy, p.dx, p.dy) : r.expandToInclude(Rect.fromLTRB(p.dx, p.dy, p.dx, p.dy));
  }
  return r ?? Rect.zero;
}

/// Whether the four corners make a convex four-sided shape that is not folded or flat (only then does a perspective map make sense).
bool isConvexQuad(List<Offset> q) {
  if (q.length != 4) return false;
  double? sign;
  for (var i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
    final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
    if (cross.abs() < 1e-6) return false;
    sign ??= cross.sign;
    if (cross.sign != sign) return false;
  }
  return true;
}

/// The perspective map that takes a rectangle onto a four-cornered shape (distort and perspective are both this; straight lines stay
/// straight). Null where the corners do not make a usable shape.
class Homography {
  final Rect from;
  final double _a, _b, _c, _d, _e, _f, _g, _h;

  Homography._(this.from, this._a, this._b, this._c, this._d, this._e, this._f, this._g, this._h);

  static Homography? rectToQuad(Rect from, List<Offset> q) {
    if (!isConvexQuad(q)) return null;
    final x0 = q[0].dx, y0 = q[0].dy, x1 = q[1].dx, y1 = q[1].dy, x2 = q[2].dx, y2 = q[2].dy, x3 = q[3].dx, y3 = q[3].dy;
    final dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
    final dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
    double g = 0, h = 0;
    if (dx3.abs() > 1e-9 || dy3.abs() > 1e-9) {
      final det = dx1 * dy2 - dx2 * dy1;
      if (det.abs() < 1e-12) return null;
      g = (dx3 * dy2 - dx2 * dy3) / det;
      h = (dx1 * dy3 - dx3 * dy1) / det;
    }
    // (the corners of the square must stay in front of the viewer)
    if (g + 1 <= 0.02 || h + 1 <= 0.02 || g + h + 1 <= 0.02) return null;
    return Homography._(from, x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h);
  }

  Offset apply(Offset p) {
    final u = (p.dx - from.left) / math.max(from.width, 1e-6);
    final v = (p.dy - from.top) / math.max(from.height, 1e-6);
    final w = _g * u + _h * v + 1;
    final d = w.abs() < 1e-9 ? 1e-9 : w;
    return Offset((_a * u + _b * v + _c) / d, (_d * u + _e * v + _f) / d);
  }
}

/// The corners [q] turned by [angle] (radians) about [centre].
List<Offset> quadRotated(List<Offset> q, Offset centre, double angle) {
  final c = math.cos(angle), s = math.sin(angle);
  return [
    for (final p in q) centre + Offset((p.dx - centre.dx) * c - (p.dy - centre.dy) * s, (p.dx - centre.dx) * s + (p.dy - centre.dy) * c),
  ];
}

/// Perspective: corner [corner] of [q] pulled by [d], and the corner next to it on the other side mirrors the pull (along the
/// direction the pull is mostly in), so that the shape stays a trapezoid (as in a photo of a wall seen from the side).
List<Offset> quadPerspective(List<Offset> q, int corner, Offset d) {
  final out = List.of(q);
  out[corner] = q[corner] + d;
  if (d.dx.abs() >= d.dy.abs()) {
    const partner = [1, 0, 3, 2];
    out[partner[corner]] = q[partner[corner]] + Offset(-d.dx, 0);
  } else {
    const partner = [3, 2, 1, 0];
    out[partner[corner]] = q[partner[corner]] + Offset(0, -d.dy);
  }
  return out;
}

/// Skew: the edge [edge] (0 top, 1 right, 2 bottom, 3 left) slid along itself by as much of [d] as lies along it, the opposite edge
/// staying where it is.
List<Offset> quadSkewed(List<Offset> q, int edge, Offset d) {
  final a = edge, b = (edge + 1) % 4;
  final dir = q[b] - q[a];
  final len = dir.distance;
  if (len < 1e-9) return q;
  final unit = dir / len;
  final slide = unit * (d.dx * unit.dx + d.dy * unit.dy);
  final out = List.of(q);
  out[a] = q[a] + slide;
  out[b] = q[b] + slide;
  return out;
}

/// A warp: a net of 4 × 4 points over a rectangle; the picture is bent so that the place of each net point goes to where the point
/// now is, and smoothly in between (a cubic through the points). With the points in their first places it changes nothing.
class WarpGrid {
  final Rect from;

  /// Row by row, [rows] × [rows] points: the point of row r and column c is at `r * 4 + c`.
  final List<Offset> points;

  static const side = 4;

  WarpGrid(this.from, List<Offset> points) : points = points.length == side * side ? points : throw ArgumentError('16 points');

  factory WarpGrid.identity(Rect from) => WarpGrid(from, [
        for (var r = 0; r < side; r++)
          for (var c = 0; c < side; c++) Offset(from.left + from.width * c / (side - 1), from.top + from.height * r / (side - 1)),
      ]);

  WarpGrid copy() => WarpGrid(from, List.of(points));

  Offset homeOf(int index) => Offset(from.left + from.width * (index % side) / (side - 1), from.top + from.height * (index ~/ side) / (side - 1));

  static double _basis(int i, double t) {
    var v = 1.0;
    for (var j = 0; j < side; j++) {
      if (j == i) continue;
      v *= (t - j / (side - 1)) / ((i - j) / (side - 1));
    }
    return v;
  }

  Offset apply(Offset p) {
    final u = (p.dx - from.left) / math.max(from.width, 1e-6);
    final v = (p.dy - from.top) / math.max(from.height, 1e-6);
    var x = 0.0, y = 0.0;
    for (var r = 0; r < side; r++) {
      final br = _basis(r, v);
      for (var c = 0; c < side; c++) {
        final w = br * _basis(c, u);
        final q = points[r * side + c];
        x += w * q.dx;
        y += w * q.dy;
      }
    }
    return Offset(x, y);
  }

  /// A point of the net, by its place in the rectangle (0 to 1 each way) as the net now bends it: for drawing the net's lines.
  Offset at(double u, double v) => apply(Offset(from.left + from.width * u, from.top + from.height * v));
}

/// The line [points] with points added wherever a step is longer than [maxStep], so that a bend (a warp) has points to bend;
/// [pressures] (one for each point, or null) get the values in between. Never more than [limit] points.
({List<Offset> points, List<int>? pressures}) refinedLine(List<Offset> points, List<int>? pressures, double maxStep, {int limit = 20000}) {
  final pr = pressures != null && pressures.length == points.length ? pressures : null;
  if (points.length < 2) return (points: List.of(points), pressures: pr == null ? null : List.of(pr));
  var step = math.max(maxStep, 0.5);
  double length = 0;
  for (var i = 1; i < points.length; i++) {
    length += (points[i] - points[i - 1]).distance;
  }
  if (length / step > limit) step = length / limit;
  final out = <Offset>[points.first];
  final outPr = pr == null ? null : <int>[pr.first];
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1], b = points[i];
    final n = math.max(1, ((b - a).distance / step).ceil());
    for (var k = 1; k <= n; k++) {
      final t = k / n;
      out.add(k == n ? b : Offset.lerp(a, b, t)!);
      if (outPr != null) outPr.add(k == n ? pr![i] : (pr![i - 1] + (pr[i] - pr[i - 1]) * t).round());
    }
  }
  return (points: out, pressures: outPr);
}
