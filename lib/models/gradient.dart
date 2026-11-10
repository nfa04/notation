import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

/// A fill that runs from one colour to another over the inside of a closed shape: the first colour is the fill of the line
/// (`DrawingStroke.fill`), the second one is [end]. It runs along [angle] (degrees; 0 is from left to right, 90 from top to bottom),
/// or from the middle outwards when it is [radial].
class FillGradient {
  final Color end;
  final int angle;
  final bool radial;

  const FillGradient({required this.end, this.angle = 90, this.radial = false});

  FillGradient copyWith({Color? end, int? angle, bool? radial}) => FillGradient(end: end ?? this.end, angle: angle ?? this.angle, radial: radial ?? this.radial);

  /// The paint's shader for a shape that takes [bounds], from [start] to [end]; null where the shape has no size to run over.
  Shader? shader(Rect bounds, Color start) {
    if (bounds.width < 1e-6 && bounds.height < 1e-6) return null;
    final c = bounds.center;
    if (radial) {
      final r = math.max(1.0, math.sqrt(bounds.width * bounds.width + bounds.height * bounds.height) / 2);
      return Gradient.radial(c, r, [start, end]);
    }
    final (from, to) = line(bounds);
    return Gradient.linear(from, to, [start, end]);
  }

  /// Where a linear gradient starts and ends for a shape that takes [bounds]: on the line along [angle] through the middle, as far
  /// out as the corners reach (so that the first colour is in one corner and the second in the other).
  (Offset, Offset) line(Rect bounds) {
    final a = angle * math.pi / 180;
    final dx = math.cos(a), dy = math.sin(a);
    final half = (dx.abs() * bounds.width + dy.abs() * bounds.height) / 2;
    final c = bounds.center;
    final d = Offset(dx, dy) * math.max(half, 0.5);
    return (c - d, c + d);
  }

  String encode() => jsonEncode({'e': end.toARGB32(), 'a': angle, if (radial) 'r': 1});

  /// The gradient [encode] made; null for nothing (or something that is not one).
  static FillGradient? decode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['e'] is! num) return null;
      return FillGradient(end: Color((j['e'] as num).toInt()), angle: ((j['a'] as num?) ?? 90).toInt(), radial: j['r'] == 1);
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is FillGradient && other.end.toARGB32() == end.toARGB32() && other.angle == angle && other.radial == radial;

  @override
  int get hashCode => Object.hash(end.toARGB32(), angle, radial);
}
