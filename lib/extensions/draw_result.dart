import 'dart:math' as math;
import 'dart:ui';

import '../models/canvas_models.dart';
import 'extension_host.dart';

/// What a drawing tool of an extension is handed: the drag of the pen, in the coordinates of the page.
class DrawGesture {
  final List<Offset> points;

  /// How hard the pen pressed at each point (0 to 1); null for a finger or a mouse.
  final List<double>? pressures;

  /// The colour and the width that are chosen in the drawing bar.
  final Color color;
  final double width;

  /// The size of the page.
  final Size page;

  /// Whether Shift was held.
  final bool shift;

  const DrawGesture({required this.points, this.pressures, required this.color, required this.width, required this.page, this.shift = false});

  static const largest = 2000;

  /// The gesture as JSON for the script: `points` as `[x, y]` pairs (at most [largest], spread evenly), `pressures`, `color`, `width`,
  /// `page` and `shift`. `start` and `end` are the first and the last point.
  Map<String, Object?> toJson() {
    final n = points.length;
    final keep = n <= largest ? [for (var i = 0; i < n; i++) i] : [for (var k = 0; k < largest; k++) (k * (n - 1) / (largest - 1)).round()];
    double r(double v) => (v * 100).roundToDouble() / 100;
    List<double> at(Offset p) => [r(p.dx), r(p.dy)];
    return {
      'points': [for (final i in keep) at(points[i])],
      'pressures': pressures == null ? null : [for (final i in keep) r(pressures![i])],
      'start': at(points.first),
      'end': at(points.last),
      'color': colorToHex(color),
      'width': width,
      'page': {'width': page.width, 'height': page.height},
      'shift': shift,
    };
  }
}

/// `#rrggbb`, or `#rrggbbaa` for a colour that is not opaque.
String colorToHex(Color c) {
  String b(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${b(c.r)}${b(c.g)}${b(c.b)}${c.a < 1 ? b(c.a) : ''}';
}

/// A colour written as `#rgb`, `#rrggbb` or `#rrggbbaa`; null if it is not one.
Color? colorFromHex(Object? text) {
  if (text is! String) return null;
  var t = text.startsWith('#') ? text.substring(1) : text;
  if (t.length == 3) t = t.split('').map((c) => '$c$c').join();
  if (t.length != 6 && t.length != 8) return null;
  final v = int.tryParse(t, radix: 16);
  if (v == null) return null;
  return t.length == 6 ? Color(0xFF000000 | v) : Color(((v & 0xFF) << 24) | (v >> 8));
}

/// Limits on what a drawing tool may hand back.
const _mostStrokes = 200, _mostPoints = 20000, _mostPointsOfOne = 5000;
const _farthest = 100000.0;

/// The lines a drawing tool returned (`{ strokes: [{ points: [[x, y], ...], color, width, dash, fill, brush }] }`, or just the list),
/// checked: a line has its points (at least two) and the colour and width of the gesture where it does not say. Anything that is
/// not right fails with [ExtensionError], and nothing is taken. A brush that is not there is the pen.
List<DrawingStroke> parseDrawnStrokes(Object? value, {required Color color, required double width}) {
  final list = value is Map ? value['strokes'] : value;
  if (list == null) return const [];
  if (list is! List) throw ExtensionError('"strokes" has to be a list.');
  if (list.length > _mostStrokes) throw ExtensionError('Too many lines (at most $_mostStrokes).');
  final out = <DrawingStroke>[];
  var total = 0;
  for (final raw in list) {
    if (raw is! Map) throw ExtensionError('A line has to be an object with "points".');
    final pts = raw['points'];
    if (pts is! List || pts.length < 2) throw ExtensionError('A line needs at least two points.');
    if (pts.length > _mostPointsOfOne) throw ExtensionError('A line has too many points (at most $_mostPointsOfOne).');
    total += pts.length;
    if (total > _mostPoints) throw ExtensionError('Too many points in all (at most $_mostPoints).');
    final points = <Offset>[];
    for (final p in pts) {
      if (p is! List || p.length != 2 || p[0] is! num || p[1] is! num) throw ExtensionError('A point has to be [x, y].');
      final x = (p[0] as num).toDouble(), y = (p[1] as num).toDouble();
      if (!x.isFinite || !y.isFinite || x.abs() > _farthest || y.abs() > _farthest) throw ExtensionError('A point is out of range.');
      points.add(Offset(x, y));
    }
    final w = raw['width'];
    if (w != null && (w is! num || !w.isFinite || w < 0.1 || w > 300)) throw ExtensionError('"width" has to be a number from 0.1 to 300.');
    final c = raw['color'] == null ? color : colorFromHex(raw['color']);
    if (c == null) throw ExtensionError('"color" has to be like #1a2b3c.');
    final f = raw['fill'] == null ? null : colorFromHex(raw['fill']);
    if (raw['fill'] != null && f == null) throw ExtensionError('"fill" has to be like #1a2b3c.');
    final dash = switch (raw['dash']) {
      null || 'solid' => StrokeDash.solid,
      'dashed' => StrokeDash.dashed,
      'dotted' => StrokeDash.dotted,
      _ => throw ExtensionError('"dash" has to be solid, dashed or dotted.'),
    };
    final brush = raw['brush'];
    if (brush != null && brush is! String) throw ExtensionError('"brush" has to be text.');
    out.add(DrawingStroke(
      color: c,
      width: w == null ? math.max(0.1, width) : (w as num).toDouble(),
      points: points,
      dash: dash,
      fill: f,
      brush: brush is String && Brushes.byId(brush) != null ? brush : penBrushId,
    ));
  }
  return out;
}
