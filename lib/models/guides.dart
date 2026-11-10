import 'dart:math' as math;
import 'dart:ui';

/// Lines laid over a page to compose by. They are never part of the page.
enum GuideOverlay {
  none('None'),
  thirds('Rule of thirds'),
  golden('Golden ratio'),
  centre('Centre lines'),
  diagonals('Diagonals'),
  grid('Grid (1 cm)');

  final String label;
  const GuideOverlay(this.label);

  /// The golden ratio.
  static final double phi = (1 + math.sqrt(5)) / 2;

  /// A centimetre in page units (an A4 sheet is 210 mm and 800 units across).
  static const double centimetre = 800 / 21;

  /// The lines of this overlay on a page of [size], as (from, to).
  List<(Offset, Offset)> lines(Size size) {
    (Offset, Offset) vertical(double x) => (Offset(x, 0), Offset(x, size.height));
    (Offset, Offset) horizontal(double y) => (Offset(0, y), Offset(size.width, y));
    switch (this) {
      case GuideOverlay.none:
        return const [];
      case GuideOverlay.thirds:
        return [vertical(size.width / 3), vertical(2 * size.width / 3), horizontal(size.height / 3), horizontal(2 * size.height / 3)];
      case GuideOverlay.golden:
        final a = 1 / (phi * phi), b = 1 / phi; // 0.382 and 0.618
        return [vertical(size.width * a), vertical(size.width * b), horizontal(size.height * a), horizontal(size.height * b)];
      case GuideOverlay.centre:
        return [vertical(size.width / 2), horizontal(size.height / 2)];
      case GuideOverlay.diagonals:
        return [(Offset.zero, Offset(size.width, size.height)), (Offset(size.width, 0), Offset(0, size.height))];
      case GuideOverlay.grid:
        return [
          // (not one on the very edge of the page)
          for (var x = centimetre; x < size.width - 0.5; x += centimetre) vertical(x),
          for (var y = centimetre; y < size.height - 0.5; y += centimetre) horizontal(y),
        ];
    }
  }
}

/// Where the vanishing points of a perspective drawing begin, as parts of the page's width and height: [count] of them (1, 2 or 3),
/// on the horizon of the upper part of the page (and the third, for looking up or down, below).
List<Offset> defaultVanishingPoints(int count) => switch (count) {
      1 => const [Offset(0.5, 0.4)],
      2 => const [Offset(0.08, 0.4), Offset(0.92, 0.4)],
      3 => const [Offset(0.08, 0.35), Offset(0.92, 0.35), Offset(0.5, 0.95)],
      _ => const [],
    };

/// The lines of a perspective grid from [points] (page units): [spokes] lines out of each vanishing point, as long as the page is
/// wide and high together, and the horizon through the first two points of one or two point perspective.
List<(Offset, Offset)> perspectiveLines(List<Offset> points, Size size, {int spokes = 24}) {
  final reach = size.width + size.height;
  final lines = <(Offset, Offset)>[];
  for (final p in points) {
    for (var i = 0; i < spokes; i++) {
      final a = 2 * math.pi * i / spokes;
      lines.add((p, p + Offset(math.cos(a), math.sin(a)) * reach));
    }
  }
  if (points.length == 1 || points.length == 2) {
    final y = points.first.dy;
    lines.add((Offset(0, y), Offset(size.width, y)));
  }
  return lines;
}

/// A piece of a straight line a drawing can be made to follow.
class SnapEdge {
  final Offset a, b;
  const SnapEdge(this.a, this.b);

  double get length => (b - a).distance;

  /// The unit vector along it (from [a] to [b]).
  Offset get direction => length < 1e-9 ? const Offset(1, 0) : (b - a) / length;

  /// The point of the edge nearest to [p] (an end if [p] is past it).
  Offset nearest(Offset p) {
    final d = b - a;
    final len2 = d.dx * d.dx + d.dy * d.dy;
    if (len2 < 1e-12) return a;
    final t = (((p - a).dx * d.dx + (p - a).dy * d.dy) / len2).clamp(0.0, 1.0);
    return a + d * t;
  }

  double distanceTo(Offset p) => (nearest(p) - p).distance;
}

/// A piece of a circle a drawing can be made to follow: [sweep] radians from the angle [from] (clockwise on the screen); a full
/// circle has a sweep of 2 pi.
class SnapArc {
  final Offset centre;
  final double radius, from, sweep;
  const SnapArc(this.centre, this.radius, this.from, this.sweep);

  bool _covers(double angle) => sweep >= 2 * math.pi - 1e-9 || ((angle - from) % (2 * math.pi)) <= sweep;

  Offset _at(double angle) => centre + Offset(math.cos(angle), math.sin(angle)) * radius;

  /// The point of the arc nearest to [p] (an end if [p] is in the part that is not there).
  Offset nearest(Offset p) {
    final d = p - centre;
    if (d.distance < 1e-9) return _at(from);
    final angle = math.atan2(d.dy, d.dx);
    if (_covers(angle)) return _at(angle);
    final a = _at(from), b = _at(from + sweep);
    return (a - p).distance <= (b - p).distance ? a : b;
  }

  double distanceTo(Offset p) => (nearest(p) - p).distance;
}

/// What a ruler or a set square is: a shape on the page that the pen's lines can be made to follow along its edges.
enum AidKind {
  ruler('Ruler'),
  squareFortyFive('Set square 45°'),
  squareThirty('Set square 30° 60°'),

  /// A half circle with a scale of degrees: its straight side and its arc are followed. [DrawingAid.length] is its radius.
  protractor('Protractor'),

  /// Three circles about one centre, to draw circles by (the outer one as large as [DrawingAid.length]).
  circles('Circle stencil');

  final String label;
  const AidKind(this.label);
}

/// A ruler or a set square laid on a page: [origin] is its pivot (the left end of a ruler, the right angle of a set square), [angle]
/// the turn of its long side from the horizontal (radians, clockwise on the screen), [length] the length of that side.
class DrawingAid {
  final AidKind kind;
  final int page;
  final Offset origin;
  final double angle;
  final double length;

  const DrawingAid(this.kind, this.page, this.origin, {this.angle = 0, this.length = 420});

  static const double minLength = 120, maxLength = 1200;

  /// How wide a ruler is.
  static const double rulerWidth = 56;

  DrawingAid copyWith({Offset? origin, double? angle, double? length, int? page}) =>
      DrawingAid(kind, page ?? this.page, origin ?? this.origin, angle: angle ?? this.angle, length: (length ?? this.length).clamp(minLength, maxLength));

  /// A point of the aid's own plane (x along the long side, y across, down) on the page.
  Offset toPage(Offset local) {
    final c = math.cos(angle), s = math.sin(angle);
    return origin + Offset(local.dx * c - local.dy * s, local.dx * s + local.dy * c);
  }

  /// The corners of its outline on the page, in order.
  List<Offset> get outline => [
        for (final p in switch (kind) {
          AidKind.ruler => [Offset(0, -rulerWidth / 2), Offset(length, -rulerWidth / 2), Offset(length, rulerWidth / 2), Offset(0, rulerWidth / 2)],
          AidKind.squareFortyFive => [Offset.zero, Offset(length, 0), Offset(0, length)],
          AidKind.squareThirty => [Offset.zero, Offset(length, 0), Offset(0, length / math.sqrt(3))],
          // (the half disc above its base, and the full outer circle: polygons that are round enough to be drawn as they are)
          AidKind.protractor => [for (var i = 0; i <= 48; i++) Offset(-length * math.cos(math.pi * i / 48), -length * math.sin(math.pi * i / 48))],
          AidKind.circles => [for (var i = 0; i < 72; i++) Offset(length * math.cos(2 * math.pi * i / 72), length * math.sin(2 * math.pi * i / 72))],
        })
          toPage(p),
      ];

  /// The edges a line can be made to follow: the two long sides of a ruler, the three sides of a set square.
  List<SnapEdge> get edges {
    final o = outline;
    return switch (kind) {
      AidKind.ruler => [SnapEdge(o[0], o[1]), SnapEdge(o[3], o[2])],
      AidKind.protractor => [SnapEdge(toPage(Offset(-length, 0)), toPage(Offset(length, 0)))],
      AidKind.circles => const [],
      _ => [for (var i = 0; i < o.length; i++) SnapEdge(o[i], o[(i + 1) % o.length])],
    };
  }

  /// The curved edges a line can be made to follow: the arc of a protractor, the circles of the stencil.
  List<SnapArc> get arcs => switch (kind) {
        AidKind.protractor => [SnapArc(origin, length, math.pi + angle, math.pi)],
        AidKind.circles => [for (final f in const [1.0, 2 / 3, 1 / 3]) SnapArc(origin, length * f, 0, 2 * math.pi)],
        _ => const [],
      };

  /// The end that is pulled to turn and resize it.
  Offset get handle => toPage(Offset(length, 0));

  @override
  bool operator ==(Object other) => other is DrawingAid && other.kind == kind && other.page == page && other.origin == origin && other.angle == angle && other.length == length;

  @override
  int get hashCode => Object.hash(kind, page, origin, angle, length);
}

/// Makes a line follow the guides: the edge of a ruler or set square it was started along, or a direction of a perspective drawing it
/// was started towards. Made when the pen goes down at [start]; every point of the pen goes through [apply].
class GuideSnapper {
  /// How near the start has to be to an edge for the line to follow it.
  static const reach = 16.0;

  /// How far the pen has to have gone before a direction is chosen (a hand is unsteady at the start of a line, and what it does in
  /// the first few units says little), and how far it may go with no direction fitting before the line is left free for good.
  static const decide = 20.0, giveUp = 160.0;

  /// How far (in degrees) the line from the start to the pen may be from a direction for the line to follow that, and how much longer
  /// than that line the way of the pen may be (a line with curves in it is a curve).
  static const tolerance = 8.0, straightness = 1.15;

  final Offset start;

  /// The edge the line follows (a line that goes on for ever, along it), or the direction; null while undecided or free.
  SnapEdge? _edge;
  SnapArc? _arc;
  Offset? _direction;
  bool _free = false;
  double _path = 0;
  late Offset _last = start;
  final List<Offset> _directions;

  GuideSnapper(this.start, {List<SnapEdge> edges = const [], List<SnapArc> arcs = const [], List<Offset> directions = const []}) : _directions = directions {
    SnapEdge? best;
    var bestDistance = reach;
    for (final e in edges) {
      final d = e.distanceTo(start);
      if (d <= bestDistance) {
        best = e;
        bestDistance = d;
      }
    }
    // (a curved edge that is nearer than every straight one is the one to follow)
    SnapArc? bestArc;
    for (final a in arcs) {
      final d = a.distanceTo(start);
      if (d <= bestDistance) {
        bestArc = a;
        best = null;
        bestDistance = d;
      }
    }
    _edge = best;
    _arc = bestArc;
    if (best == null && bestArc == null && directions.isEmpty) _free = true;
  }

  /// Whether there is anything to follow: the line follows something, or still may.
  bool get active => !_free;

  /// Whether the line follows an edge or a direction now.
  bool get following => _edge != null || _arc != null || _direction != null;

  /// What to do with the point [pen]: `point` is where the line goes; `restart` says the line followed nothing until now and from
  /// here on follows something, so that what it had must be made again from its start.
  ({Offset point, bool restart}) apply(Offset pen) {
    final edge = _edge;
    if (edge != null) {
      // along the edge (the line is straight along it, and ends where the edge does)
      return (point: edge.nearest(_projected(pen, edge.a, edge.direction)), restart: false);
    }
    final arc = _arc;
    if (arc != null) return (point: arc.nearest(pen), restart: false); // (round the circle, wherever the pen is)
    final dir = _direction;
    if (dir != null) return (point: _projected(pen, start, dir), restart: false);
    if (_free) return (point: pen, restart: false);

    final moved = pen - start;
    _path += (pen - _last).distance;
    _last = pen;
    if (moved.distance < decide) return (point: pen, restart: false);
    // the way from the start to the pen, if the pen has been going about straight: the direction (either way along it) it is nearest to
    if (_path <= moved.distance * straightness) {
      final angle = math.atan2(moved.dy, moved.dx);
      Offset? best;
      var bestDiff = tolerance * math.pi / 180;
      for (final d in _directions) {
        final a = math.atan2(d.dy, d.dx);
        var diff = (angle - a).abs() % math.pi; // (a line has two ways)
        if (diff > math.pi / 2) diff = math.pi - diff;
        if (diff <= bestDiff) {
          best = d;
          bestDiff = diff;
        }
      }
      if (best != null) {
        _direction = best;
        return (point: _projected(pen, start, best), restart: true);
      }
    }
    // not going any of the ways: left free for good once it has gone a good way
    if (moved.distance > giveUp) _free = true;
    return (point: pen, restart: false);
  }

  static Offset _projected(Offset p, Offset on, Offset direction) => on + direction * ((p - on).dx * direction.dx + (p - on).dy * direction.dy);
}

/// The directions a perspective drawing can be started in from [start]: towards each vanishing point ([points], page units), and the
/// vertical (and, with one point, the horizontal). With three points there are no parallels: all go to a point.
List<Offset> perspectiveDirections(Offset start, List<Offset> points) {
  final out = <Offset>[];
  for (final p in points) {
    final d = p - start;
    if (d.distance > 1) out.add(d / d.distance);
  }
  if (points.isNotEmpty && points.length < 3) out.add(const Offset(0, 1));
  if (points.length == 1) out.add(const Offset(1, 0));
  return out;
}
