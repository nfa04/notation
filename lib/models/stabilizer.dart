import 'dart:math' as math;
import 'dart:ui';

/// Steadies a shaky hand with a "rope": the line is drawn by a point that trails behind the pen on a string of a fixed length, so
/// small wobbles never reach it and a pull in one direction makes a clean curve. [strength] goes from 0 (the pen as it is) to 1
/// (a long string).
class LineStabiliser {
  /// The longest string, in page units (a little over a centimetre on an A4 page of 800 units).
  static const longest = 36.0;

  final double strength;
  Offset? _at;

  LineStabiliser(double strength) : strength = strength.clamp(0.0, 1.0);

  double get _string => strength * longest;

  /// Whether this does anything (a strength of nothing hands the pen's own points through).
  bool get active => strength > 0;

  /// Where the line begins: where the pen went down.
  Offset start(Offset pen) => _at = pen;

  /// Where the line is when the pen is at [pen]; null if the point stays where it was (the pen is still inside the string's reach).
  Offset? follow(Offset pen) {
    final at = _at;
    if (!active || at == null) return _at = pen;
    final gap = pen - at;
    final distance = gap.distance;
    if (distance <= _string) return null;
    // the point is pulled until the string is taut again, and a little more smoothly than a jump: it keeps a quarter of the slack
    final next = at + gap / distance * (distance - _string * 0.75);
    return _at = Offset.lerp(at, next, 0.9)!;
  }

  /// The points that bring the line from where it is to [pen], where the pen was lifted, so that the line ends at the pen and not
  /// a string's length before it.
  List<Offset> finish(Offset pen) {
    final at = _at;
    if (!active || at == null) return const [];
    final distance = (pen - at).distance;
    if (distance < 0.5) return const [];
    final steps = math.max(1, (distance / 6).ceil());
    _at = pen;
    return [for (var i = 1; i <= steps; i++) Offset.lerp(at, pen, i / steps)!];
  }
}
