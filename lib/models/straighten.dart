import 'dart:math' as math;
import 'dart:ui';

/// The shortest line that is straightened, in page units (the page is 800 wide: about 2 mm on an A4 page). Shorter strokes are
/// letters, dashes and dots; a dash of this length is made straight as well, a short curve is not (the shorter the line, the less it may
/// stray, see [straightLine]).
const shortestLine = 8.0;

/// A hand-drawn stroke that is meant to be a straight line, as the line it
/// means: the two ends, joined; horizontal or vertical when it was nearly so.
/// Null when [points] is no line (too short, bent, looping or back and forth).
///
/// Units are page units (the page is 800 wide).
List<Offset>? straightLine(List<Offset> points, {double snapDegrees = 10, double minLength = shortestLine}) {
  if (points.length < 2) return null; // (a quick short stroke may be only two points)
  final a = points.first, b = points.last;
  final chord = (b - a).distance;
  if (chord < minLength) return null;

  var path = 0.0;
  for (var i = 1; i < points.length; i++) {
    path += (points[i] - points[i - 1]).distance;
  }
  if (path > chord * 1.12) return null; // wiggles, loops, goes back

  // how far the stroke strays from the straight line between its ends
  final dir = (b - a) / chord;
  var deviation = 0.0;
  for (final p in points) {
    final v = p - a;
    deviation = math.max(deviation, (v.dx * dir.dy - v.dy * dir.dx).abs());
  }
  // (the allowed stray is 4 units from 40 units of length on, and less for shorter lines, down to 1 at the shortest: a short hand
  // stroke is less shaky in units, and a bend of the same size would be a letter)
  final stray = chord >= 40 ? math.max(4.0, chord * 0.06) : 1.0 + 3.0 * math.max(0.0, (chord - shortestLine) / (40 - shortestLine));
  if (deviation > stray) return null;

  var start = a, end = b;
  final angle = math.atan2(b.dy - a.dy, b.dx - a.dx) * 180 / math.pi;
  if (angle.abs() <= snapDegrees || angle.abs() >= 180 - snapDegrees) {
    final y = (a.dy + b.dy) / 2;
    start = Offset(a.dx, y);
    end = Offset(b.dx, y);
  } else if ((angle.abs() - 90).abs() <= snapDegrees) {
    final x = (a.dx + b.dx) / 2;
    start = Offset(x, a.dy);
    end = Offset(x, b.dy);
  }

  // a point every few units, so that the eraser and the lasso find it anywhere along
  final steps = ((end - start).distance / 6).ceil();
  return [for (var k = 0; k <= steps; k++) start + (end - start) * (k / steps)];
}
