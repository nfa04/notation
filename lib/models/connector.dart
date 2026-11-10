import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

/// The side of an item (a text box, a picture, a shape) a connector is fixed to. [auto] picks the side that faces the other end.
enum Anchor {
  auto,
  top,
  right,
  bottom,
  left;

  static Anchor byName(Object? name) => values.where((a) => a.name == name).firstOrNull ?? auto;

  /// The way out of an item at this side (auto: none).
  Offset get direction => switch (this) {
        top => const Offset(0, -1),
        right => const Offset(1, 0),
        bottom => const Offset(0, 1),
        left => const Offset(-1, 0),
        auto => Offset.zero,
      };

  /// The middle of this side of [r] (auto: the middle of [r]).
  Offset on(Rect r) => switch (this) {
        top => r.topCenter,
        right => r.centerRight,
        bottom => r.bottomCenter,
        left => r.centerLeft,
        auto => r.center,
      };
}

/// How a connector gets from one end to the other.
enum ConnectorRoute {
  straight('Straight'),
  elbow('Elbow'),
  curve('Curve');

  final String label;
  const ConnectorRoute(this.label);

  static ConnectorRoute byName(Object? name) => values.where((r) => r.name == name).firstOrNull ?? straight;
}

/// One end of a connector: fixed to an item (by its id) at [anchor], or free at [point].
class LinkEnd {
  /// The id of the text box, picture or drawing it is fixed to; null: free.
  final String? item;
  final Anchor anchor;

  /// Where a free end is (page space); where a fixed one was last, until its item is found.
  final Offset point;

  const LinkEnd.free(this.point)
      : item = null,
        anchor = Anchor.auto;

  const LinkEnd.to(String this.item, {this.anchor = Anchor.auto, this.point = Offset.zero});

  bool get isFree => item == null;

  LinkEnd copyWith({String? item, Anchor? anchor, Offset? point, bool free = false}) =>
      free ? LinkEnd.free(point ?? this.point) : LinkEnd.to(item ?? this.item!, anchor: anchor ?? this.anchor, point: point ?? this.point);

  @override
  bool operator ==(Object other) => other is LinkEnd && other.item == item && other.anchor == anchor && (item != null || other.point == point);

  @override
  int get hashCode => Object.hash(item, anchor, item == null ? point : null);

  Map<String, Object?> toJson() => {
        if (item != null) 'i': item,
        if (anchor != Anchor.auto) 'a': anchor.name,
        if (item == null || point != Offset.zero) 'x': point.dx,
        if (item == null || point != Offset.zero) 'y': point.dy,
      };

  static LinkEnd fromJson(Object? json) {
    if (json is! Map) return const LinkEnd.free(Offset.zero);
    final item = json['i'];
    final x = json['x'], y = json['y'];
    final point = x is num && y is num && x.isFinite && y.isFinite ? Offset(x.toDouble(), y.toDouble()) : Offset.zero;
    return item is String && item.isNotEmpty ? LinkEnd.to(item, anchor: Anchor.byName(json['a']), point: point) : LinkEnd.free(point);
  }
}

/// What makes a line on a page a connector: it joins two ends, and follows the items they are fixed to when those move.
class StrokeLink {
  final LinkEnd from, to;
  final ConnectorRoute route;

  /// Arrowheads at the end and at the start.
  final bool arrowAtEnd, arrowAtStart;

  const StrokeLink({required this.from, required this.to, this.route = ConnectorRoute.straight, this.arrowAtEnd = true, this.arrowAtStart = false});

  StrokeLink copyWith({LinkEnd? from, LinkEnd? to, ConnectorRoute? route, bool? arrowAtEnd, bool? arrowAtStart}) => StrokeLink(
        from: from ?? this.from,
        to: to ?? this.to,
        route: route ?? this.route,
        arrowAtEnd: arrowAtEnd ?? this.arrowAtEnd,
        arrowAtStart: arrowAtStart ?? this.arrowAtStart,
      );

  /// Whether it is fixed to at least one item (else it is a plain arrow).
  bool get isLinked => !from.isFree || !to.isFree;

  /// The ids of the items it is fixed to.
  Iterable<String> get items => [if (from.item != null) from.item!, if (to.item != null) to.item!];

  @override
  bool operator ==(Object other) =>
      other is StrokeLink && other.from == from && other.to == to && other.route == route && other.arrowAtEnd == arrowAtEnd && other.arrowAtStart == arrowAtStart;

  @override
  int get hashCode => Object.hash(from, to, route, arrowAtEnd, arrowAtStart);

  Map<String, Object?> toJson() => {
        'f': from.toJson(),
        't': to.toJson(),
        if (route != ConnectorRoute.straight) 'r': route.name,
        if (!arrowAtEnd) 'ae': false,
        if (arrowAtStart) 'as': true,
      };

  String encode() => jsonEncode(toJson());

  static StrokeLink? fromJson(Object? json) {
    if (json is! Map) return null;
    return StrokeLink(
      from: LinkEnd.fromJson(json['f']),
      to: LinkEnd.fromJson(json['t']),
      route: ConnectorRoute.byName(json['r']),
      arrowAtEnd: json['ae'] != false,
      arrowAtStart: json['as'] == true,
    );
  }

  /// What [encode] made, or null when [text] is empty or not a link.
  static StrokeLink? decode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      return fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }
}

/// The sides the two ends of a connector between [a] and [b] leave from: the ones that face each other, along the axis they are
/// further apart on (what a flowchart tool does by itself). A side [pinnedA] or [pinnedB] gives is kept.
(Anchor, Anchor) facingAnchors(Rect a, Rect b, {Anchor pinnedA = Anchor.auto, Anchor pinnedB = Anchor.auto}) {
  final d = b.center - a.center;
  // overlapping on one axis: the other axis is the one to go along
  final apartX = math.max(0.0, d.dx.abs() - (a.width + b.width) / 2);
  final apartY = math.max(0.0, d.dy.abs() - (a.height + b.height) / 2);
  final horizontal = apartX == apartY ? d.dx.abs() >= d.dy.abs() : apartX > apartY;
  final (from, to) = horizontal ? (d.dx >= 0 ? (Anchor.right, Anchor.left) : (Anchor.left, Anchor.right)) : (d.dy >= 0 ? (Anchor.bottom, Anchor.top) : (Anchor.top, Anchor.bottom));
  return (pinnedA == Anchor.auto ? from : pinnedA, pinnedB == Anchor.auto ? to : pinnedB);
}

/// The side of [r] nearest to [p] (for an end that is let go of near an item, or one that faces a free point): along the axis the
/// point is further outside the item on, as [facingAnchors] does; for a point inside, the side it is nearest to.
Anchor nearestAnchor(Rect r, Offset p) {
  if (r.width <= 0 || r.height <= 0) return Anchor.right;
  final d = p - r.center;
  final apartX = d.dx.abs() - r.width / 2, apartY = d.dy.abs() - r.height / 2;
  if (apartX > 0 || apartY > 0) {
    return apartX >= apartY ? (d.dx >= 0 ? Anchor.right : Anchor.left) : (d.dy >= 0 ? Anchor.bottom : Anchor.top);
  }
  // (inside: measured in halves of the sides, so that a wide item does not take every point for its top or bottom)
  final nx = d.dx / (r.width / 2), ny = d.dy / (r.height / 2);
  return nx.abs() >= ny.abs() ? (nx >= 0 ? Anchor.right : Anchor.left) : (ny >= 0 ? Anchor.bottom : Anchor.top);
}

/// How round the corners of an elbow are (page units).
const defaultCornerRadius = 16.0;

const _gap = 22.0; // how far an elbow or a curve leaves an item straight before it turns
const _headLength = 14.0;

/// The line of a connector, as the points of a stroke, from [start] (leaving in the direction [startOut], zero: any) to [end]
/// (arriving from [endOut]), in the shape of [route], with the arrowheads asked for. Points are about [step] apart (as
/// [shapePoints] makes them, so that the eraser and the lasso find the line anywhere on it).
List<Offset> connectorPoints(
  Offset start,
  Offset startOut,
  Offset end,
  Offset endOut,
  ConnectorRoute route, {
  bool arrowAtEnd = true,
  bool arrowAtStart = false,
  double step = 5,
  double cornerRadius = defaultCornerRadius,
}) {
  final path = switch (route) {
    ConnectorRoute.straight => [start, end],
    ConnectorRoute.elbow => _rounded(_elbow(start, startOut, end, endOut), cornerRadius),
    ConnectorRoute.curve => _curve(start, startOut, end, endOut),
  };
  var line = route == ConnectorRoute.curve ? _thin(path, step) : _along(path, step);
  if (line.length < 2) return [start, end];
  final out = List<Offset>.of(line);
  // the heads are drawn on, as one line that goes back over itself, as the arrow of the shape tool is
  void head(Offset tip, Offset from, {required bool atEnd}) {
    final d = tip - from;
    final length = d.distance;
    if (length < 1) return;
    final unit = d / length;
    final size = math.min(_headLength, length * 0.5);
    Offset barb(double angle) {
      final c = math.cos(angle), s = math.sin(angle);
      return tip - Offset(unit.dx * c - unit.dy * s, unit.dx * s + unit.dy * c) * size;
    }

    final bit = _along([tip, barb(math.pi / 7), tip, barb(-math.pi / 7)], step);
    if (atEnd) {
      out.addAll(bit.skip(1));
    } else {
      // (the start: go there and back, then on with the line)
      final back = _along([line.first, tip], step);
      out
        ..clear()
        ..addAll([...bit.reversed, ...back.skip(1), ...line.skip(1)]);
    }
  }

  if (arrowAtEnd) head(line.last, _lookBack(line, line.last), atEnd: true);
  if (arrowAtStart) head(line.first, _lookBack(line.reversed.toList(), line.first), atEnd: false);
  return out;
}

/// A point of [line] a little before its last point (the way the line is going there).
Offset _lookBack(List<Offset> line, Offset tip) {
  for (var i = line.length - 2; i >= 0; i--) {
    if ((line[i] - tip).distance >= 3) return line[i];
  }
  return line.first;
}

List<Offset> _elbow(Offset a, Offset outA, Offset b, Offset outB) {
  // leave each end straight out of its side, then join the two with right angles
  final startOut = outA == Offset.zero ? _towards(b - a) : outA;
  final endOut = outB == Offset.zero ? _towards(a - b) : outB;
  final p1 = a + startOut * _gap, p2 = b + endOut * _gap;
  final horizontalStart = startOut.dx != 0, horizontalEnd = endOut.dx != 0;
  final points = <Offset>[a, p1];
  if (horizontalStart && horizontalEnd) {
    // both leave sideways: meet at the middle in x if they face each other, else go round
    if (startOut.dx * (b.dx - a.dx) > 0 && endOut.dx * (a.dx - b.dx) > 0 && (startOut.dx != endOut.dx)) {
      final mid = (a.dx + b.dx) / 2;
      return _simplified([a, Offset(mid, a.dy), Offset(mid, b.dy), b]);
    }
    final x = startOut.dx > 0 ? math.max(p1.dx, p2.dx) : math.min(p1.dx, p2.dx);
    points.addAll([Offset(x, p1.dy), Offset(x, p2.dy)]);
  } else if (!horizontalStart && !horizontalEnd) {
    if (startOut.dy * (b.dy - a.dy) > 0 && endOut.dy * (a.dy - b.dy) > 0 && (startOut.dy != endOut.dy)) {
      final mid = (a.dy + b.dy) / 2;
      return _simplified([a, Offset(a.dx, mid), Offset(b.dx, mid), b]);
    }
    final y = startOut.dy > 0 ? math.max(p1.dy, p2.dy) : math.min(p1.dy, p2.dy);
    points.addAll([Offset(p1.dx, y), Offset(p2.dx, y)]);
  } else if (horizontalStart) {
    points.add(Offset(p2.dx, p1.dy)); // sideways, then up or down into the end
  } else {
    points.add(Offset(p1.dx, p2.dy));
  }
  points
    ..add(p2)
    ..add(b);
  return _simplified(points);
}

/// [corners] joined by straight lines with each inner corner cut off by a smooth bend of up to [radius] (less where the lines
/// next to it are short, so that two bends never overlap).
List<Offset> _rounded(List<Offset> corners, double radius) {
  if (radius <= 0 || corners.length < 3) return corners;
  final out = <Offset>[corners.first];
  for (var i = 1; i < corners.length - 1; i++) {
    final before = corners[i - 1], at = corners[i], after = corners[i + 1];
    final inLength = (at - before).distance, outLength = (after - at).distance;
    // (half of a line each, at most: the other end of it has a bend to make as well)
    final r = math.min(radius, math.min(inLength, outLength) / 2);
    if (r < 1) {
      out.add(at);
      continue;
    }
    final from = at + (before - at) / inLength * r, to = at + (after - at) / outLength * r;
    const n = 8;
    for (var k = 0; k <= n; k++) {
      final t = k / n, u = 1 - t;
      out.add(from * (u * u) + at * (2 * u * t) + to * (t * t)); // (a quadratic bend whose control point is the corner)
    }
  }
  out.add(corners.last);
  return out;
}

/// The unit step along the axis [d] is longest on.
Offset _towards(Offset d) => d.dx.abs() >= d.dy.abs() ? Offset(d.dx >= 0 ? 1 : -1, 0) : Offset(0, d.dy >= 0 ? 1 : -1);

/// [points] without the repeated ones and those in the middle of a straight run.
List<Offset> _simplified(List<Offset> points) {
  final out = <Offset>[];
  for (final p in points) {
    if (out.isNotEmpty && (out.last - p).distance < 0.5) continue;
    while (out.length >= 2) {
      final a = out[out.length - 2], b = out.last;
      final cross = (b.dx - a.dx) * (p.dy - b.dy) - (b.dy - a.dy) * (p.dx - b.dx);
      if (cross.abs() > 0.01) break;
      out.removeLast();
    }
    out.add(p);
  }
  return out;
}

List<Offset> _curve(Offset a, Offset outA, Offset b, Offset outB) {
  final d = b - a;
  final reach = math.max(30.0, d.distance * 0.4);
  final c1 = a + (outA == Offset.zero ? _towards(d) : outA) * reach;
  final c2 = b + (outB == Offset.zero ? _towards(-d) : outB) * reach;
  final n = math.max(12, (d.distance / 6).ceil());
  return [
    for (var i = 0; i <= n; i++)
      () {
        final t = i / n, u = 1 - t;
        return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
      }(),
  ];
}

/// [line] with points no closer than about [step] (a curve is sampled finely; this keeps a point at least every [step]).
List<Offset> _thin(List<Offset> line, double step) {
  if (line.length < 3) return line;
  final out = <Offset>[line.first];
  for (var i = 1; i < line.length - 1; i++) {
    if ((line[i] - out.last).distance >= step) out.add(line[i]);
  }
  out.add(line.last);
  return out;
}

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

/// Where the connector of [link] goes now: the points of its line, and the link with what it learned (an end whose item is not
/// there any more stays where it was, a fixed one remembers where its side is). [rectOf] says where an item is (null: gone).
({List<Offset> points, StrokeLink link}) routeLink(StrokeLink link, Rect? Function(String id) rectOf, {double step = 5, double cornerRadius = defaultCornerRadius}) {
  final fromRect = link.from.item == null ? null : rectOf(link.from.item!);
  final toRect = link.to.item == null ? null : rectOf(link.to.item!);

  Anchor fromAnchor = link.from.anchor, toAnchor = link.to.anchor;
  if (fromRect != null && toRect != null) {
    (fromAnchor, toAnchor) = facingAnchors(fromRect, toRect, pinnedA: fromAnchor, pinnedB: toAnchor);
  } else if (fromRect != null && fromAnchor == Anchor.auto) {
    fromAnchor = nearestAnchor(fromRect, link.to.point);
  } else if (toRect != null && toAnchor == Anchor.auto) {
    toAnchor = nearestAnchor(toRect, link.from.point);
  }
  final start = fromRect == null ? link.from.point : fromAnchor.on(fromRect);
  final end = toRect == null ? link.to.point : toAnchor.on(toRect);
  final points = connectorPoints(
    start,
    fromRect == null ? Offset.zero : fromAnchor.direction,
    end,
    toRect == null ? Offset.zero : toAnchor.direction,
    link.route,
    arrowAtEnd: link.arrowAtEnd,
    arrowAtStart: link.arrowAtStart,
    step: step,
    cornerRadius: cornerRadius,
  );
  return (
    points: points,
    link: link.copyWith(
      // (an end whose item is not there stays fixed to it, where it was: the item may come back, as with an undo)
      from: link.from.isFree ? link.from.copyWith(point: start, free: true) : link.from.copyWith(point: start),
      to: link.to.isFree ? link.to.copyWith(point: end, free: true) : link.to.copyWith(point: end),
    ),
  );
}
