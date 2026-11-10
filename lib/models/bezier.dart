import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

/// One point of a [CurvedPath]: where it is and the two handles that bend the curve through it. A point with no handles is a corner;
/// pulling a handle makes it smooth (the other handle goes the opposite way, as far).
class PathNode {
  Offset at;

  /// The handle on the way to the next point, and the one on the way from the last (where they are, not their lengths); null: none.
  Offset? out;
  Offset? inn;

  PathNode(this.at, {this.out, this.inn});

  bool get smooth => out != null || inn != null;

  /// Pulls the handle that leads on to [to], and the other one the opposite way.
  void pullOut(Offset to) {
    out = to;
    inn = at * 2 - to;
  }

  /// Pulls the handle that comes in to [to], and the other one the opposite way.
  void pullIn(Offset to) {
    inn = to;
    out = at * 2 - to;
  }

  /// Moves the point, with its handles.
  void moveBy(Offset delta) {
    at += delta;
    if (out != null) out = out! + delta;
    if (inn != null) inn = inn! + delta;
  }

  /// Makes it a corner: no handles.
  void sharpen() {
    out = null;
    inn = null;
  }

  PathNode copy() => PathNode(at, out: out, inn: inn);

  /// `[x, y]`, or `[x, y, outX, outY, inX, inY]` (a handle that is not there is the point itself).
  List<double> toJson() => smooth ? [at.dx, at.dy, (out ?? at).dx, (out ?? at).dy, (inn ?? at).dx, (inn ?? at).dy] : [at.dx, at.dy];

  static PathNode? fromJson(Object? json) {
    if (json is! List || (json.length != 2 && json.length != 6) || json.any((v) => v is! num || !v.isFinite)) return null;
    final v = [for (final n in json) (n as num).toDouble()];
    final at = Offset(v[0], v[1]);
    return v.length == 2 ? PathNode(at) : PathNode(at, out: Offset(v[2], v[3]), inn: Offset(v[4], v[5]));
  }
}

/// Which part of a node of a path.
enum PathPart { point, out, inn }

/// A path of points joined by curves, as the pen tool makes it: a cubic Bézier between each two points, bent by their handles. Open
/// or [closed] (the last point joined to the first).
class CurvedPath {
  final List<PathNode> nodes;
  bool closed;

  CurvedPath([Iterable<PathNode>? nodes, this.closed = false]) : nodes = [...?nodes];

  bool get isEmpty => nodes.isEmpty;

  /// Whether it has anything to draw: two points, or one point of a closed path.
  bool get drawable => nodes.length >= 2;

  /// The points of the line, about [step] apart (a curve more closely where it bends), for drawing it and for the eraser and lasso to
  /// find it. [to] adds a last stretch to there from the last point, as the line follows a pen that has not put its next point yet.
  List<Offset> points({double step = 4, Offset? to}) {
    if (nodes.isEmpty) return const [];
    final out = <Offset>[nodes.first.at];
    final count = nodes.length;
    for (var i = 0; i + 1 < count; i++) {
      _segment(out, nodes[i], nodes[i + 1], step);
    }
    if (closed && count >= 2) _segment(out, nodes.last, nodes.first, step);
    if (!closed && to != null) _segment(out, nodes.last, PathNode(to), step);
    return out;
  }

  static void _segment(List<Offset> into, PathNode a, PathNode b, double step) {
    final p0 = a.at, p1 = a.out ?? a.at, p2 = b.inn ?? b.at, p3 = b.at;
    final reach = (p1 - p0).distance + (p2 - p1).distance + (p3 - p2).distance;
    // (a cubic is not drawn at an even pace: it runs half as fast again at its quickest)
    final n = math.max(1, (reach * 1.5 / step).ceil());
    for (var k = 1; k <= n; k++) {
      final t = k / n, u = 1 - t;
      into.add(p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t));
    }
  }

  /// The part of the path within [reach] of [p] (the handles first - they are on top - then the points, the nearest first), or null.
  ({int node, PathPart part})? hit(Offset p, double reach) {
    ({int node, PathPart part})? best;
    var bestDistance = reach;
    for (var i = nodes.length - 1; i >= 0; i--) {
      final n = nodes[i];
      for (final (part, at) in [(PathPart.out, n.out), (PathPart.inn, n.inn)]) {
        if (at == null) continue;
        final d = (at - p).distance;
        if (d <= bestDistance) {
          best = (node: i, part: part);
          bestDistance = d - 0.001; // (a handle wins over a point at the same distance)
        }
      }
    }
    if (best != null) return best;
    for (var i = nodes.length - 1; i >= 0; i--) {
      final d = (nodes[i].at - p).distance;
      if (d <= bestDistance) {
        best = (node: i, part: PathPart.point);
        bestDistance = d - 0.001;
      }
    }
    return best;
  }

  /// A copy that can be changed without changing this (the points are copied too).
  CurvedPath copy() => CurvedPath([for (final n in nodes) n.copy()], closed);

  /// The path as text, to be kept with the line: `{"c": 1 if closed, "n": [points]}`.
  String encode() => jsonEncode({if (closed) 'c': 1, 'n': [for (final n in nodes) n.toJson()]});

  /// Reads what [encode] wrote; null when there is nothing that can be read (or fewer than two points).
  static CurvedPath? decode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['n'] is! List) return null;
      final nodes = <PathNode>[];
      for (final e in json['n'] as List) {
        final n = PathNode.fromJson(e);
        if (n == null) return null;
        nodes.add(n);
      }
      return nodes.length < 2 ? null : CurvedPath(nodes, json['c'] == 1);
    } catch (_) {
      return null;
    }
  }

  /// This path fitted to a line that was made from it and has been moved or made larger or smaller since: [drawn] are the points the
  /// line has now. Null if they are not the points of this path (the line was changed some other way), or this has no points.
  CurvedPath? fittedTo(List<Offset> drawn, {double step = 4}) {
    final made = points(step: step);
    if (made.length != drawn.length || made.length < 2) return null;
    Rect box(List<Offset> pts) {
      var r = Rect.fromPoints(pts.first, pts.first);
      for (final p in pts) {
        r = r.expandToInclude(Rect.fromPoints(p, p));
      }
      return r;
    }

    final from = box(made), to = box(drawn);
    // (a line that is flat on one side has no scale to find along it: it is taken as it is)
    final sx = from.width < 1e-6 ? 1.0 : to.width / from.width, sy = from.height < 1e-6 ? 1.0 : to.height / from.height;
    Offset map(Offset p) => Offset(to.left + (p.dx - from.left) * sx, to.top + (p.dy - from.top) * sy);
    for (var i = 0; i < made.length; i += 1 + made.length ~/ 24) {
      if ((map(made[i]) - drawn[i]).distance > 1.5) return null;
    }
    return CurvedPath([
      for (final n in nodes)
        PathNode(map(n.at), out: n.out == null ? null : map(n.out!), inn: n.inn == null ? null : map(n.inn!)),
    ], closed);
  }
}
