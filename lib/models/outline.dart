import 'dart:ui';

/// A filled shape kept as the pieces it was made of (polygons, circles, ribbons), so that each place it is drawn can draw it in its
/// own best way: the screen as a [Path] (made the first time it is asked for), a PDF as the same few points and curves, with no
/// sampling along the outline. Filled non-zero; every piece winds the same way, so where pieces overlap nothing cancels.
class Outline {
  final List<OutlinePiece> _pieces = [];
  Path? _path;

  Outline();

  /// One ribbon (see [addRibbon]).
  Outline.ribbon(List<Offset> points, List<double> half) {
    addRibbon(points, half);
  }

  List<OutlinePiece> get pieces => _pieces;

  /// A polygon through [points] (always closed: the shape is filled).
  void addPolygon(List<Offset> points) => _add(OutlinePolygon(points));

  /// The circle or ellipse in [rect].
  void addOval(Rect rect) => _add(OutlineOval(rect));

  /// A line through [points] that is [half] thick (half of it) at each point, round at the ends and at every point.
  void addRibbon(List<Offset> points, List<double> half) => _add(OutlineRibbon(points, half));

  void addOutline(Outline other) {
    _pieces.addAll(other._pieces);
    _path = null;
  }

  void _add(OutlinePiece piece) {
    _pieces.add(piece);
    _path = null;
  }

  /// The shape as a path for the screen.
  Path get path => _path ??= _build();

  Path _build() {
    final path = Path();
    for (final piece in _pieces) {
      switch (piece) {
        case OutlinePolygon(:final points):
          path.addPolygon(points, true);
        case OutlineOval(:final rect):
          path.addOval(rect);
        case OutlineRibbon():
          piece.addTo(path);
      }
    }
    return path;
  }
}

sealed class OutlinePiece {
  const OutlinePiece();
}

class OutlinePolygon extends OutlinePiece {
  final List<Offset> points;
  const OutlinePolygon(this.points);
}

class OutlineOval extends OutlinePiece {
  final Rect rect;
  const OutlineOval(this.rect);
}

/// A line of [points] that is [half] thick (half of it) at each point. Filled, it is one quad for each segment, each with its own
/// normal, plus a round joint at every point: a single ribbon folds over itself in tight curves and, filled non-zero, shows holes
/// there. All pieces wind the same way (addOval is clockwise), so overlaps never cancel.
class OutlineRibbon extends OutlinePiece {
  final List<Offset> points;
  final List<double> half;
  const OutlineRibbon(this.points, this.half);

  /// The half thickness if it is the same all along (then the ribbon is exactly the line stroked that thick, with round ends and
  /// joints); null if it changes.
  double? get evenHalf {
    if (half.isEmpty) return null;
    final h = half.first;
    for (final v in half) {
      if ((v - h).abs() > 1e-6) return null;
    }
    return h;
  }

  /// Calls [quad] with the four corners of every segment and [circle] with the centre and radius of every joint and end, in the
  /// order they are added to a path.
  void visit(void Function(Offset a, Offset b, Offset c, Offset d) quad, void Function(Offset centre, double radius) circle) {
    final pts = points;
    for (var i = 0; i < pts.length - 1; i++) {
      final d = pts[i + 1] - pts[i];
      final len = d.distance;
      if (len < 1e-6) continue;
      final n = Offset(-d.dy / len, d.dx / len);
      final a = pts[i], b = pts[i + 1];
      quad(a - n * half[i], b - n * half[i + 1], b + n * half[i + 1], a + n * half[i]);
      circle(a, half[i]);
    }
    circle(pts.last, half.last);
  }

  void addTo(Path path) => visit(
        (a, b, c, d) => path
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..lineTo(c.dx, c.dy)
          ..lineTo(d.dx, d.dy)
          ..close(),
        (centre, radius) => path.addOval(Rect.fromCircle(center: centre, radius: radius)),
      );
}
