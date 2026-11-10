import 'dart:math' as math;
import 'dart:ui';

/// What a drag with the pen draws: the line the hand makes, or a shape between
/// where it started and where it is now.
enum ShapeTool {
  freehand('Freehand'),
  line('Line'),
  arrow('Arrow'),
  connector('Connector'),
  rectangle('Rectangle'),
  ellipse('Ellipse'),
  triangle('Triangle'),
  diamond('Diamond'),
  roundedRectangle('Rounded rectangle'),
  rightTriangle('Right triangle'),
  parallelogram('Parallelogram'),
  pentagon('Pentagon'),
  hexagon('Hexagon'),
  star('Star'),
  heart('Heart'),
  cross('Cross'),
  doubleArrow('Double arrow'),
  speechBubble('Speech bubble'),

  /// Not a drag: points are placed one by one and pulled into curves (see [CurvedPath]); the editor handles it, [shapePoints] has
  /// nothing to draw for it.
  bezier('Pen (curves)');

  final String label;
  const ShapeTool(this.label);

  /// A line from where the pen went down to where it is: Shift makes it go along 45 degree steps.
  bool get isLinear => this == line || this == arrow || this == connector || this == doubleArrow;

  /// A shape that fills a box: Shift makes its box a square.
  bool get isClosed => !isLinear && this != freehand && this != bezier;
}

/// The points of [tool] from [a] to [b], close enough together (about [step]
/// apart) for the eraser and the lasso to find the shape anywhere on it.
/// [constrain] makes lines go along 45 degree steps, and rectangles and
/// ellipses square and round (what Shift does).
List<Offset> shapePoints(ShapeTool tool, Offset a, Offset b, {bool constrain = false, double step = 5}) {
  var end = b;
  if (constrain) {
    final d = b - a;
    if (tool.isLinear) {
      final angle = (math.atan2(d.dy, d.dx) / (math.pi / 4)).round() * (math.pi / 4);
      end = a + Offset(math.cos(angle), math.sin(angle)) * d.distance;
    } else if (tool.isClosed) {
      final side = math.max(d.dx.abs(), d.dy.abs());
      end = a + Offset(d.dx < 0 ? -side : side, d.dy < 0 ? -side : side);
    }
  }

  switch (tool) {
    case ShapeTool.freehand:
    case ShapeTool.bezier:
      return [a, end];
    case ShapeTool.line:
      return _along([a, end], step);
    case ShapeTool.arrow:
    case ShapeTool.connector: // (between two items it is made by the editor; with no item at either end it is an arrow)
      final d = end - a;
      final length = d.distance;
      if (length < 1) return [a, end];
      final unit = d / length;
      final head = math.min(24.0, length * 0.35); // a short arrow has a small head
      Offset barb(double angle) {
        final c = math.cos(angle), s = math.sin(angle);
        return end - Offset(unit.dx * c - unit.dy * s, unit.dx * s + unit.dy * c) * head;
      }

      // one line that goes: tail -> tip -> one barb -> back to the tip -> the other barb
      return _along([a, end, barb(math.pi / 7), end, barb(-math.pi / 7)], step);
    case ShapeTool.doubleArrow:
      final d = end - a;
      final length = d.distance;
      if (length < 1) return [a, end];
      final unit = d / length;
      final head = math.min(24.0, length * 0.3);
      Offset barb(Offset tip, Offset direction, double angle) {
        final c = math.cos(angle), s = math.sin(angle);
        return tip - Offset(direction.dx * c - direction.dy * s, direction.dx * s + direction.dy * c) * head;
      }

      // one line that goes: a barb at the start -> the start -> its other barb -> back to the start -> the tip -> a barb, back, the other
      return _along([
        barb(a, -unit, math.pi / 7), a, barb(a, -unit, -math.pi / 7), a,
        end, barb(end, unit, math.pi / 7), end, barb(end, unit, -math.pi / 7),
      ], step);
    case ShapeTool.roundedRectangle:
      final r = Rect.fromPoints(a, end);
      final radius = math.min(math.min(r.width, r.height) * 0.25, 28.0);
      if (radius < 1) return _along([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft], step);
      List<Offset> arc(Offset centre, double from) => [
            for (var i = 0; i <= 6; i++) centre + Offset(math.cos(from + i * math.pi / 12), math.sin(from + i * math.pi / 12)) * radius,
          ];
      final corners = [
        ...arc(Offset(r.right - radius, r.top + radius), -math.pi / 2),
        ...arc(Offset(r.right - radius, r.bottom - radius), 0),
        ...arc(Offset(r.left + radius, r.bottom - radius), math.pi / 2),
        ...arc(Offset(r.left + radius, r.top + radius), math.pi),
      ];
      return _along([...corners, corners.first], step);
    case ShapeTool.rightTriangle:
      final r = Rect.fromPoints(a, end);
      return _along([r.topLeft, r.bottomLeft, r.bottomRight, r.topLeft], step);
    case ShapeTool.parallelogram:
      final r = Rect.fromPoints(a, end);
      final lean = r.width * 0.22;
      return _along([Offset(r.left + lean, r.top), r.topRight, Offset(r.right - lean, r.bottom), r.bottomLeft, Offset(r.left + lean, r.top)], step);
    case ShapeTool.pentagon:
      return _along(_closed(_fitted(Rect.fromPoints(a, end), [for (var i = 0; i < 5; i++) _onCircle(-math.pi / 2 + i * 2 * math.pi / 5, 1)])), step);
    case ShapeTool.hexagon:
      return _along(_closed(_fitted(Rect.fromPoints(a, end), [for (var i = 0; i < 6; i++) _onCircle(i * math.pi / 3, 1)])), step);
    case ShapeTool.star:
      return _along(
          _closed(_fitted(Rect.fromPoints(a, end), [for (var i = 0; i < 10; i++) _onCircle(-math.pi / 2 + i * math.pi / 5, i.isEven ? 1 : 0.382)])), step);
    case ShapeTool.heart:
      final r = Rect.fromPoints(a, end);
      final n = math.max(60, (2.4 * (r.width + r.height) / step).ceil());
      final raw = [
        for (var i = 0; i < n; i++)
          () {
            final t = 2 * math.pi * i / n;
            return Offset(16 * math.pow(math.sin(t), 3).toDouble(), -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)));
          }(),
      ];
      return _closed(_fitted(r, raw));
    case ShapeTool.cross:
      final r = Rect.fromPoints(a, end);
      final x1 = r.left + r.width / 3, x2 = r.left + 2 * r.width / 3, y1 = r.top + r.height / 3, y2 = r.top + 2 * r.height / 3;
      return _along([
        Offset(x1, r.top), Offset(x2, r.top), Offset(x2, y1), Offset(r.right, y1), Offset(r.right, y2), Offset(x2, y2),
        Offset(x2, r.bottom), Offset(x1, r.bottom), Offset(x1, y2), Offset(r.left, y2), Offset(r.left, y1), Offset(x1, y1), Offset(x1, r.top),
      ], step);
    case ShapeTool.speechBubble:
      final r = Rect.fromPoints(a, end);
      final body = r.bottom - r.height * 0.22;
      return _along([
        r.topLeft, r.topRight, Offset(r.right, body), Offset(r.left + r.width * 0.45, body), Offset(r.left + r.width * 0.2, r.bottom),
        Offset(r.left + r.width * 0.25, body), Offset(r.left, body), r.topLeft,
      ], step);
    case ShapeTool.rectangle:
      final r = Rect.fromPoints(a, end);
      return _along([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft], step);
    case ShapeTool.triangle:
      final r = Rect.fromPoints(a, end);
      return _along([Offset(r.center.dx, r.top), r.bottomRight, r.bottomLeft, Offset(r.center.dx, r.top)], step);
    case ShapeTool.diamond:
      final r = Rect.fromPoints(a, end);
      return _along([Offset(r.center.dx, r.top), Offset(r.right, r.center.dy), Offset(r.center.dx, r.bottom), Offset(r.left, r.center.dy), Offset(r.center.dx, r.top)], step);
    case ShapeTool.ellipse:
      final r = Rect.fromPoints(a, end);
      if (r.width < 1 && r.height < 1) return [a, end];
      // The points are evenly spaced in angle, so they are furthest apart on the longest
      // side: enough of them for that to be about [step] too.
      final w = r.width / 2, h = r.height / 2;
      // (a multiple of four, so that the points include the middle of every side)
      final n = (math.max(24, (2 * math.pi * math.max(w, h) / step).ceil()) / 4).ceil() * 4;
      return [
        for (var i = 0; i <= n; i++)
          Offset(r.center.dx + w * math.cos(2 * math.pi * i / n), r.center.dy + h * math.sin(2 * math.pi * i / n)),
      ];
  }
}

Offset _onCircle(double angle, double radius) => Offset(math.cos(angle), math.sin(angle)) * radius;

/// [points] stretched and moved to fill [box] exactly (the box around them becomes [box]).
List<Offset> _fitted(Rect box, List<Offset> points) {
  var left = double.infinity, top = double.infinity, right = -double.infinity, bottom = -double.infinity;
  for (final p in points) {
    left = math.min(left, p.dx);
    top = math.min(top, p.dy);
    right = math.max(right, p.dx);
    bottom = math.max(bottom, p.dy);
  }
  final w = right - left, h = bottom - top;
  return [
    for (final p in points) Offset(box.left + (w == 0 ? 0 : (p.dx - left) / w * box.width), box.top + (h == 0 ? 0 : (p.dy - top) / h * box.height)),
  ];
}

List<Offset> _closed(List<Offset> points) => [...points, points.first];

/// [corners] joined by straight lines, with a point at least every [step].
List<Offset> _along(List<Offset> corners, double step) {
  final out = <Offset>[corners.first];
  for (var i = 1; i < corners.length; i++) {
    final from = corners[i - 1], to = corners[i];
    final n = math.max(1, ((to - from).distance / step).ceil());
    for (var k = 1; k <= n; k++) {
      out.add(Offset.lerp(from, to, k / n)!);
    }
  }
  return out;
}
