import 'dart:ui';

/// One line shown while something is moved: where it lines up with another thing (or with the page).
class AlignLine {
  /// A vertical line at x = [at] (otherwise horizontal, at y = [at]).
  final bool vertical;
  final double at;

  /// How far along the other axis it runs.
  final double from, to;

  const AlignLine(this.vertical, this.at, this.from, this.to);

  @override
  bool operator ==(Object other) => other is AlignLine && other.vertical == vertical && other.at == at && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(vertical, at, from, to);
}

/// How far to nudge a moved thing so that it lines up, and the lines that show what it lines up with.
class AlignSnap {
  final Offset delta;
  final List<AlignLine> lines;

  const AlignSnap(this.delta, this.lines);

  static const none = AlignSnap(Offset.zero, []);
}

/// Where [moving] (the box of what is being moved, as it would be without snapping) lines up with [others] or the [page]: its left,
/// middle or right with their left, middle or right, and likewise top, middle and bottom. The nearest match on each axis within
/// [threshold] wins, and every edge that then lines up gets a line.
AlignSnap alignWhileMoving(Rect moving, List<Rect> others, Size page, {double threshold = 6}) {
  final targets = [...others, Offset.zero & page];

  /// The smallest shift (of those within [threshold]) that makes one of [mine] equal to one of [theirs] on an axis.
  double? nearest(List<double> mine, List<double> Function(Rect) theirs) {
    double? best;
    for (final t in targets) {
      for (final a in mine) {
        for (final b in theirs(t)) {
          final d = b - a;
          if (d.abs() <= threshold && (best == null || d.abs() < best.abs())) best = d;
        }
      }
    }
    return best;
  }

  List<double> xs(Rect r) => [r.left, r.center.dx, r.right];
  List<double> ys(Rect r) => [r.top, r.center.dy, r.bottom];
  final dx = nearest(xs(moving), xs) ?? 0;
  final dy = nearest(ys(moving), ys) ?? 0;
  final at = moving.shift(Offset(dx, dy));

  final lines = <AlignLine>{};
  const eps = 0.5;
  for (final t in targets) {
    for (final a in xs(at)) {
      for (final b in xs(t)) {
        if ((a - b).abs() < eps) lines.add(AlignLine(true, b, at.top < t.top ? at.top : t.top, at.bottom > t.bottom ? at.bottom : t.bottom));
      }
    }
    for (final a in ys(at)) {
      for (final b in ys(t)) {
        if ((a - b).abs() < eps) lines.add(AlignLine(false, b, at.left < t.left ? at.left : t.left, at.right > t.right ? at.right : t.right));
      }
    }
  }
  return AlignSnap(Offset(dx, dy), lines.toList());
}
