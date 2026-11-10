import 'dart:math' as math;

import 'extension_host.dart';

/// The shapes `draw.shape` knows.
const shapeTypes = ['rectangle', 'ellipse', 'triangle', 'diamond', 'line', 'arrow'];

double _number(Map<String, Object?> o, String key, {double? fallback, bool positive = false}) {
  final v = o[key] ?? fallback;
  if (v is! num || !v.isFinite) throw ExtensionError('"$key" has to be a number.');
  if (positive && v <= 0) throw ExtensionError('"$key" has to be more than 0.');
  if (v.abs() > 100000) throw ExtensionError('"$key" is out of range.');
  return v.toDouble();
}

List<double> _point(double x, double y) => [(x * 100).roundToDouble() / 100, (y * 100).roundToDouble() / 100];

/// The line (in the form `draw.strokes` takes: `points`, `color`, `width`, `fill`, `dash`) that draws the shape [o] describes:
/// `type`, then `x`, `y`, `width` and `height` for a closed shape (its box on the page), or `x`, `y` and `x2`, `y2` (from, to) for a
/// `line` and an `arrow`; and any of `color`, `lineWidth`, `fill` and `dash`. Fails with [ExtensionError] when it is not right.
List<Map<String, Object?>> shapeStrokes(Map<String, Object?> o) {
  final type = o['type'];
  if (type is! String || !shapeTypes.contains(type)) throw ExtensionError('"type" has to be one of: ${shapeTypes.join(', ')}.');
  final points = <List<double>>[];
  if (type == 'line' || type == 'arrow') {
    final x1 = _number(o, 'x'), y1 = _number(o, 'y'), x2 = _number(o, 'x2'), y2 = _number(o, 'y2');
    if (x1 == x2 && y1 == y2) throw ExtensionError('The line has no length: "x2", "y2" are where "x", "y" are.');
    points.add(_point(x1, y1));
    points.add(_point(x2, y2));
    if (type == 'arrow') {
      final angle = math.atan2(y2 - y1, x2 - x1);
      final head = (math.sqrt(math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2)) * 0.2).clamp(10.0, 40.0);
      for (final side in [-1, 1]) {
        final a = angle + math.pi + side * 0.45;
        points.add(_point(x2 + head * math.cos(a), y2 + head * math.sin(a)));
        if (side == -1) points.add(_point(x2, y2));
      }
    }
  } else {
    final x = _number(o, 'x'), y = _number(o, 'y'), w = _number(o, 'width', positive: true), h = _number(o, 'height', positive: true);
    switch (type) {
      case 'rectangle':
        points.addAll([_point(x, y), _point(x + w, y), _point(x + w, y + h), _point(x, y + h), _point(x, y)]);
      case 'triangle':
        points.addAll([_point(x + w / 2, y), _point(x + w, y + h), _point(x, y + h), _point(x + w / 2, y)]);
      case 'diamond':
        points.addAll([_point(x + w / 2, y), _point(x + w, y + h / 2), _point(x + w / 2, y + h), _point(x, y + h / 2), _point(x + w / 2, y)]);
      default: // ellipse
        const steps = 64;
        for (var i = 0; i <= steps; i++) {
          final a = 2 * math.pi * i / steps;
          points.add(_point(x + w / 2 + w / 2 * math.cos(a), y + h / 2 + h / 2 * math.sin(a)));
        }
    }
  }
  final line = o['lineWidth'];
  if (line != null && (line is! num || !line.isFinite || line < 0.1 || line > 300)) throw ExtensionError('"lineWidth" has to be a number from 0.1 to 300.');
  final fill = o['fill'];
  if (fill != null && (type == 'line' || type == 'arrow')) throw ExtensionError('A $type cannot be filled.');
  return [
    {'points': points, 'color': ?o['color'], 'width': ?line, 'fill': ?fill, 'dash': ?o['dash']},
  ];
}
