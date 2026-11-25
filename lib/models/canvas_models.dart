import 'dart:collection' show ListBase;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'bezier.dart';
import 'brush.dart';
import 'connector.dart';
import 'gradient.dart';
import 'stroke_label.dart';
import 'rich_text.dart';

export 'brush.dart' show penBrushId, rollerBrushId, Brushes;

/// The group of something that is in none.
const String noGroup = '';

final _idRandom = math.Random.secure();

/// A new id for something on a page (a stroke, a highlight): the same on every device that
/// has it, so that a change can say which one it is about.
String newElementId() => List.generate(6, (_) => _idRandom.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

/// How a line is drawn: whole, in dashes or in dots.
enum StrokeDash {
  solid('Solid'),
  dashed('Dashed'),
  dotted('Dotted');

  final String label;
  const StrokeDash(this.label);

  static StrokeDash byIndex(int? i) => i != null && i >= 0 && i < values.length ? values[i] : solid;
}

/// How much thicker (or thinner) than its set width a line is where the pen pressed with [pressure] (0 to 1), for a pen whose
/// sensitivity is [sensitivity] (0: pressure makes no difference, 1: from a third to one and two thirds of the width).
double pressureFactor(double pressure, double sensitivity) => 1 - sensitivity + sensitivity * (0.35 + 1.3 * pressure.clamp(0.0, 1.0));

/// Whether [stroke] is drawn thicker where the pen pressed harder (with [sensitivity]): a line of the pen with a pressure for every
/// point, not dashed. Otherwise it is drawn one width all along.
bool drawsWithPressure(DrawingStroke stroke, double sensitivity) {
  final pr = stroke.pressures;
  return pr != null &&
      pr.length == stroke.points.length &&
      stroke.dash == StrokeDash.solid &&
      sensitivity > 0;
}

/// Half the thickness of [stroke] at each of its points, by how hard the pen pressed there (see [drawsWithPressure]).
List<double> pressureHalfWidths(DrawingStroke stroke, double sensitivity) {
  final pr = stroke.pressures!;
  return [
    for (var i = 0; i < stroke.points.length; i++)
      stroke.width * pressureFactor(pr[i] / 255, sensitivity) / 2,
  ];
}

/// The points of a line: a list that counts the changes made through it ([revision]), so that [DrawingStroke.stamp] sees every change
/// without reading a single point. It owns its points: nothing else holds the list they are in, so every change goes through here
/// and is counted.
class StrokePoints extends ListBase<Offset> {
  final List<Offset> _points;
  int _revision = 0;

  StrokePoints._(this._points);

  /// [points] as the points of a line: [points] itself if it is that already, else a copy of them (the list given stays the caller's,
  /// and a change made to it later is not one of the line).
  factory StrokePoints.of(List<Offset> points) => points is StrokePoints ? points : StrokePoints._(List.of(points));

  /// [points] taken over as they are, with no copy: for a list just made (decoded, say) that nothing else will change.
  factory StrokePoints.owning(List<Offset> points) => points is StrokePoints ? points : StrokePoints._(points);

  /// Goes up with every change made through this list.
  int get revision => _revision;

  void _changed() => _revision++;

  int _boxRevision = -1;
  Rect _box = Rect.zero;

  /// The box around the points (none for no points), measured again only after a change: the eraser asks it of every line at every move.
  Rect get box {
    if (_boxRevision != _revision) {
      _boxRevision = _revision;
      if (_points.isEmpty) {
        _box = Rect.zero;
      } else {
        var l = double.infinity, t = double.infinity, r = double.negativeInfinity, b = double.negativeInfinity;
        for (final o in _points) {
          if (o.dx < l) l = o.dx;
          if (o.dx > r) r = o.dx;
          if (o.dy < t) t = o.dy;
          if (o.dy > b) b = o.dy;
        }
        _box = Rect.fromLTRB(l, t, r, b);
      }
    }
    return _box;
  }

  @override
  int get length => _points.length;

  @override
  set length(int n) {
    _points.length = n;
    _changed();
  }

  @override
  Offset operator [](int i) => _points[i];

  @override
  void operator []=(int i, Offset value) {
    _points[i] = value;
    _changed();
  }

  // (the reading goes straight to the list; every change below is the list's own, counted)
  @override
  Iterator<Offset> get iterator => _points.iterator;

  @override
  void add(Offset element) {
    _points.add(element);
    _changed();
  }

  @override
  void addAll(Iterable<Offset> iterable) {
    _points.addAll(iterable);
    _changed();
  }

  @override
  void insert(int index, Offset element) {
    _points.insert(index, element);
    _changed();
  }

  @override
  void insertAll(int index, Iterable<Offset> iterable) {
    _points.insertAll(index, iterable);
    _changed();
  }

  @override
  bool remove(Object? element) {
    final removed = _points.remove(element);
    if (removed) _changed();
    return removed;
  }

  @override
  Offset removeAt(int index) {
    final removed = _points.removeAt(index);
    _changed();
    return removed;
  }

  @override
  Offset removeLast() {
    final removed = _points.removeLast();
    _changed();
    return removed;
  }

  @override
  void removeRange(int start, int end) {
    _points.removeRange(start, end);
    _changed();
  }

  @override
  void removeWhere(bool Function(Offset element) test) {
    _points.removeWhere(test);
    _changed();
  }

  @override
  void retainWhere(bool Function(Offset element) test) {
    _points.retainWhere(test);
    _changed();
  }

  @override
  void clear() {
    _points.clear();
    _changed();
  }

  @override
  void sort([int Function(Offset a, Offset b)? compare]) {
    _points.sort(compare);
    _changed();
  }

  @override
  void shuffle([math.Random? random]) {
    _points.shuffle(random);
    _changed();
  }

  @override
  void setAll(int index, Iterable<Offset> iterable) {
    _points.setAll(index, iterable);
    _changed();
  }

  @override
  void setRange(int start, int end, Iterable<Offset> iterable, [int skipCount = 0]) {
    _points.setRange(start, end, iterable, skipCount);
    _changed();
  }

  @override
  void fillRange(int start, int end, [Offset? fill]) {
    _points.fillRange(start, end, fill);
    _changed();
  }

  @override
  void replaceRange(int start, int end, Iterable<Offset> newContents) {
    _points.replaceRange(start, end, newContents);
    _changed();
  }
}

/// A line drawn with the pen, or a shape; the points are in the page space of the editor.
/// The id of the layer every note has and every line was on before there were layers (see `layers.dart`). It cannot be deleted.
const String baseLayerId = '';

class DrawingStroke {
  /// Names the stroke across devices and saves; it never changes.
  final String id;

  /// Goes up with every change of the look or the place of the line made through its setters (the points count their own, see
  /// [StrokePoints]): what [stamp] goes by instead of reading the values themselves.
  int _version = 0;

  /// The look of the line: the colour, the width, and the dashes can be changed afterwards (a selected shape has a style dialog).
  Color get color => _color;
  set color(Color v) {
    if (v != _color) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _color = v;
  }
  Color _color;

  double get width => _width;
  set width(double v) {
    if (v != _width) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _width = v;
  }
  double _width;

  StrokeDash get dash => _dash;
  set dash(StrokeDash v) {
    if (v != _dash) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _dash = v;
  }
  StrokeDash _dash;

  /// What a closed line (a rectangle, an ellipse, a loop) is filled with; null: nothing.
  Color? get fill => _fill;
  set fill(Color? v) {
    if (v != _fill) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _fill = v;
  }
  Color? _fill;

  /// Changed in place as the line is drawn, moved or reshaped; every change made through it is counted (see [StrokePoints]).
  final StrokePoints points;

  /// How hard the pen pressed at each point (0 to 255, one for each point), for a line drawn with a pressure-sensitive pen:
  /// the line is thicker where it was pressed harder. Null for a line with no pressure (finger, mouse, shapes). (It grows in place
  /// while the line is drawn: [stamp] reads its length and ends.)
  List<int>? get pressures => _pressures;
  set pressures(List<int>? v) {
    if (!identical(v, _pressures)) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _pressures = v;
  }
  List<int>? _pressures;

  /// Who drew it (the name they had then); null if not known, as for notes from before names were kept.
  String? get author => _author;
  set author(String? v) {
    if (v != _author) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _author = v;
  }
  String? _author;

  /// The brush that drew it, by [Brush.id]: how the points become a line (see `brushes.dart`). A line of a brush this app does
  /// not know (one from an extension that is not here) is drawn as the pen would.
  String get brush => _brush;
  set brush(String v) {
    if (v != _brush) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _brush = v;
  }
  String _brush;

  /// The layer it is on, by id (see `layers.dart`); [baseLayerId] for a line drawn before there were layers. A layer that is not
  /// there (it was deleted) is the base layer.
  String get layer => _layer;
  set layer(String v) {
    if (v != _layer) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _layer = v;
  }
  String _layer;

  /// For a connector: the items its ends are fixed to (see `connector.dart`). The points are what it is drawn from; the editor
  /// makes them again when an item moves. Null for a line that is just a line.
  StrokeLink? get link => _link;
  set link(StrokeLink? v) {
    if (v != _link) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _link = v;
  }
  StrokeLink? _link;

  /// The group it belongs to, by id ([noGroup] for none): what is in a group is selected, moved, copied and deleted together.
  String get group => _group;
  set group(String v) {
    if (v != _group) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _group = v;
  }
  String _group;

  /// For a line made with the pen for curves: the points and handles it was made from, so that it can be bent again. They are
  /// kept as they were when the line was finished; if the line has been moved or resized since, [CurvedPath] is fitted to it again
  /// when it is needed (see `fittedCurve` in `bezier.dart`). (Its nodes can change in place: [stamp] reads their count and ends.)
  CurvedPath? get curve => _curve;
  set curve(CurvedPath? v) {
    if (!identical(v, _curve)) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _curve = v;
  }
  CurvedPath? _curve;

  /// For a closed line whose inside runs from [fill] to another colour: how (see `gradient.dart`). Null: the fill is one colour.
  FillGradient? get gradient => _gradient;
  set gradient(FillGradient? v) {
    if (!identical(v, _gradient)) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _gradient = v;
  }
  FillGradient? _gradient;

  /// Text that runs along the line or is written inside the shape, and goes where it goes (see `stroke_label.dart`). Null: none.
  StrokeLabel? get label => _label;
  set label(StrokeLabel? v) {
    if (!identical(v, _label)) _version++; // (the value is taken even when it is equal: equal is not always the same, see StrokeLink)
    _label = v;
  }
  StrokeLabel? _label;

  DrawingStroke({
    String? id,
    required Color color,
    required double width,
    required List<Offset> points,
    String? author,
    StrokeDash dash = StrokeDash.solid,
    Color? fill,
    List<int>? pressures,
    String brush = penBrushId,
    String layer = baseLayerId,
    StrokeLink? link,
    String group = noGroup,
    CurvedPath? curve,
    FillGradient? gradient,
    StrokeLabel? label,
  })  : id = id ?? newElementId(),
        points = StrokePoints.of(points),
        _color = color,
        _width = width,
        _author = author,
        _dash = dash,
        _fill = fill,
        _pressures = pressures,
        _brush = brush,
        _layer = layer,
        _link = link,
        _group = group,
        _curve = curve,
        _gradient = gradient,
        _label = label;

  /// Whether the line comes back to where it began, so that it has an inside to fill.
  bool get isClosed => points.length >= 4 && (points.first - points.last).distance <= math.max(6, width * 1.5);

  /// A copy with a new id and the same look. (A connector is copied as a plain line: it is fixed to the items it joined, not to
  /// their copies.)
  DrawingStroke copyAt(Offset shift, {String? author}) => DrawingStroke(
        color: color,
        width: width,
        points: [for (final p in points) p + shift],
        author: author ?? this.author,
        dash: dash,
        fill: fill,
        pressures: pressures == null ? null : List.of(pressures!),
        brush: brush,
        layer: layer,
        curve: curve?.copy(),
        gradient: gradient,
        label: label,
      );

  /// A cheap fingerprint of the stroke, read for every stroke of every page at each build and save: which stroke it is, the number of
  /// changes made to its look ([_version]) and to its points ([StrokePoints.revision]), and the length and ends of what changes in place
  /// (the pressures, the nodes of a curve). It reads no point. Two strokes have different stamps even when they look the same: it says
  /// whether this stroke changed, not what it looks like. Not the same from one run of the app to the next.
  int get stamp {
    final pr = _pressures;
    final cv = _curve;
    return Object.hash(
      identityHashCode(this),
      _version,
      points.revision,
      points.length,
      pr == null || pr.isEmpty ? 0 : Object.hash(pr.length, pr.first, pr.last),
      cv == null || cv.nodes.isEmpty ? 0 : Object.hash(cv.nodes.length, cv.closed, cv.nodes.first.at, cv.nodes.last.at, cv.nodes.first.out, cv.nodes.last.inn),
    );
  }

  /// Leaves out the points that add nothing one can see: those that lie within [tolerance] of the straight line between the
  /// points kept around them (and, with pressure, whose pressure is about what the kept ones around them would give). A pen
  /// sends a point at almost every pixel; a line of handwriting keeps a fraction of them, which makes it lighter to draw, store,
  /// search and send.
  void simplify(double tolerance) {
    final n = points.length;
    if (n < 3) return;
    final pr = pressures != null && pressures!.length == n ? pressures : null;
    final keep = List.filled(n, false);
    keep[0] = keep[n - 1] = true;
    final todo = <(int, int)>[(0, n - 1)];
    while (todo.isNotEmpty) {
      final (from, to) = todo.removeLast();
      if (to - from < 2) continue;
      final a = points[from], b = points[to];
      final ab = b - a;
      final len = ab.distance;
      var worst = -1;
      var worstBy = 0.0;
      for (var i = from + 1; i < to; i++) {
        final v = points[i] - a;
        var off = len < 1e-9 ? v.distance : (v.dx * ab.dy - v.dy * ab.dx).abs() / len;
        if (pr != null) {
          final t = (i - from) / (to - from);
          final expected = pr[from] + (pr[to] - pr[from]) * t;
          if ((pr[i] - expected).abs() > 10) off = math.max(off, tolerance * 2); // (a change of pressure is kept too)
        }
        if (off > worstBy) {
          worstBy = off;
          worst = i;
        }
      }
      if (worst >= 0 && worstBy > tolerance) {
        keep[worst] = true;
        todo
          ..add((from, worst))
          ..add((worst, to));
      }
    }
    if (!keep.contains(false)) return;
    final kept = [for (var i = 0; i < n; i++) if (keep[i]) points[i]];
    if (pr != null) pressures = [for (var i = 0; i < n; i++) if (keep[i]) pr[i]];
    points
      ..clear()
      ..addAll(kept);
  }

  /// Whether the stroke passes within [radius] of [p] (its own thickness
  /// counts too), measured to the line segments between the points. With [from], of the whole way from [from] to [p]: the eraser
  /// moved there between two events, and a quick sweep of the pen can be further than its size from one event to the next.
  bool isNear(Offset p, double radius, {Offset? from}) {
    if (points.isEmpty) return false;
    final reach = radius + width / 2, reach2 = reach * reach;
    final px = p.dx, py = p.dy;
    final q = from ?? p, qx = q.dx, qy = q.dy;
    final minX = math.min(px, qx) - reach, maxX = math.max(px, qx) + reach;
    final minY = math.min(py, qy) - reach, maxY = math.max(py, qy) + reach;
    // (the eraser asks this of every line at every move: a line whose box is out of reach is not read at all)
    final box = points.box;
    if (maxX < box.left || minX > box.right || maxY < box.top || minY > box.bottom) return false;
    final swept = qx != px || qy != py;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = i + 1 < points.length ? points[i + 1] : a;
      final ax = a.dx, ay = a.dy, bx = b.dx, by = b.dy;
      // (nor is a segment whose box is out of reach)
      if (maxX < math.min(ax, bx) || minX > math.max(ax, bx) || maxY < math.min(ay, by) || minY > math.max(ay, by)) continue;
      if (_gap2(px, py, ax, ay, bx, by) <= reach2) return true;
      if (!swept) continue;
      if (_gap2(qx, qy, ax, ay, bx, by) <= reach2 || _gap2(ax, ay, qx, qy, px, py) <= reach2 || _gap2(bx, by, qx, qy, px, py) <= reach2) return true;
      if (_cross(ax, ay, bx, by, qx, qy, px, py)) return true;
    }
    return false;
  }
}

/// The square of the distance from (px, py) to the segment from (ax, ay) to (bx, by).
double _gap2(double px, double py, double ax, double ay, double bx, double by) {
  final abx = bx - ax, aby = by - ay;
  final len2 = abx * abx + aby * aby;
  final t = len2 == 0 ? 0.0 : (((px - ax) * abx + (py - ay) * aby) / len2).clamp(0.0, 1.0);
  final dx = px - (ax + abx * t), dy = py - (ay + aby * t);
  return dx * dx + dy * dy;
}

/// Whether the segments a-b and c-d cross (touching at an end is found by [_gap2] already).
bool _cross(double ax, double ay, double bx, double by, double cx, double cy, double dx, double dy) {
  double side(double ox, double oy, double px, double py, double qx, double qy) => (px - ox) * (qy - oy) - (py - oy) * (qx - ox);
  final d1 = side(cx, cy, dx, dy, ax, ay), d2 = side(cx, cy, dx, dy, bx, by);
  final d3 = side(ax, ay, bx, by, cx, cy), d4 = side(ax, ay, bx, by, dx, dy);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/// Whether [p] lies inside the closed shape [polygon] (even-odd rule).
bool pointInPolygon(Offset p, List<Offset> polygon) => _inPolygon(p.dx, p.dy, polygon);

bool _inPolygon(double x, double y, List<Offset> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if ((a.dy > y) != (b.dy > y) && x < (b.dx - a.dx) * (y - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

/// Selecting strokes with a lasso.
extension StrokeLasso on DrawingStroke {
  /// Whether at least half of the stroke's length lies inside the lasso shape.
  /// Measured along the line, not by counting points: a mouse records few
  /// points for a long stroke, a pen very many.
  bool mostlyInside(List<Offset> lasso) {
    if (lasso.length < 3 || points.isEmpty) return false;
    // what is outside the box around the lasso is outside the lasso: a line out of it is not measured, nor a sample of a line
    final Rect(:left, :top, :right, :bottom) = _bounds(lasso);
    final box = _bounds(points);
    if (box.right < left || box.left > right || box.bottom < top || box.top > bottom) return false;
    var inside = 0, total = 0;
    void count(double x, double y) {
      total++;
      if (x >= left && x <= right && y >= top && y <= bottom && _inPolygon(x, y, lasso)) inside++;
    }

    count(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      final steps = ((b - a).distance / 3).ceil(); // a sample every few units
      for (var k = 1; k <= steps; k++) {
        final t = k / steps;
        count(a.dx * (1.0 - t) + b.dx * t, a.dy * (1.0 - t) + b.dy * t);
      }
    }
    return inside * 2 >= total;
  }
}

Rect _bounds(List<Offset> points) {
  var left = double.infinity, top = double.infinity, right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final q in points) {
    left = math.min(left, q.dx);
    right = math.max(right, q.dx);
    top = math.min(top, q.dy);
    bottom = math.max(bottom, q.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// How a text box looks: its fill, its border and its text colour.
class TextBoxStyle {
  final Color background;

  /// 0 (see-through) to 1 (solid); applies to the fill only, not to the text.
  final double opacity;
  final Color borderColor;

  /// 0 = no border.
  final double borderWidth;
  final double radius;
  final Color textColor;

  const TextBoxStyle({
    this.background = const Color(0xFFFFFFFF),
    this.opacity = 0.95,
    this.borderColor = const Color(0xFFBDBDBD),
    this.borderWidth = 1,
    this.radius = 8,
    this.textColor = const Color(0xDD000000),
  });

  static const defaults = TextBoxStyle();

  bool get isDefault => this == defaults;

  /// The fill with its opacity.
  Color get fill => background.withValues(alpha: opacity);

  TextBoxStyle copyWith({
    Color? background,
    double? opacity,
    Color? borderColor,
    double? borderWidth,
    double? radius,
    Color? textColor,
  }) =>
      TextBoxStyle(
        background: background ?? this.background,
        opacity: opacity ?? this.opacity,
        borderColor: borderColor ?? this.borderColor,
        borderWidth: borderWidth ?? this.borderWidth,
        radius: radius ?? this.radius,
        textColor: textColor ?? this.textColor,
      );

  @override
  bool operator ==(Object other) =>
      other is TextBoxStyle &&
      other.background == background &&
      other.opacity == opacity &&
      other.borderColor == borderColor &&
      other.borderWidth == borderWidth &&
      other.radius == radius &&
      other.textColor == textColor;

  @override
  int get hashCode => Object.hash(background, opacity, borderColor, borderWidth, radius, textColor);

  Map<String, Object> toJson() => {
        'bg': background.toARGB32(),
        'op': opacity,
        'bc': borderColor.toARGB32(),
        'bw': borderWidth,
        'r': radius,
        'tc': textColor.toARGB32(),
      };

  /// What was saved; missing or unreadable parts fall back to the defaults.
  static TextBoxStyle fromJson(Object? json) {
    if (json is! Map) return defaults;
    Color? color(String key) => json[key] is int ? Color(json[key] as int) : null;
    double? number(String key) => json[key] is num ? (json[key] as num).toDouble() : null;
    return TextBoxStyle(
      background: color('bg') ?? defaults.background,
      opacity: (number('op') ?? defaults.opacity).clamp(0.0, 1.0),
      borderColor: color('bc') ?? defaults.borderColor,
      borderWidth: (number('bw') ?? defaults.borderWidth).clamp(0.0, 12.0),
      radius: (number('r') ?? defaults.radius).clamp(0.0, 48.0),
      textColor: color('tc') ?? defaults.textColor,
    );
  }
}

/// A text box on a page: its place, size, text with formatting and look.
///
/// The text and its formatting are plain data ([text], [attributes]) until something edits the box: [controller] and [focusNode] are
/// made the first time they are asked for (by the editor, which shows the box), and from then on [text] and [attributes] are theirs.
/// A note read for the sync, the history, an export or a preview makes no controller at all; [dispose] lets go of what was made.
class TextBoxWidgetModel {
  final String id;
  Offset position;

  /// The width of the box, and the least height it keeps (0: as tall as its text).
  /// The box grows with its text, so the height is only what the person pulled it to.
  Size size;
  double fontSize;
  TextBoxStyle style;

  /// Who made the box; null if not known.
  String? author;

  /// The layer it is on, by id (see `layers.dart`); a layer that is not there is the base layer.
  String layer;

  /// The group it belongs to ([noGroup] for none), see [DrawingStroke.group].
  String group;

  String _text;
  final List<TextSpanAttribute> _attributes = [];
  RichInlineTextController? _controller;
  FocusNode? _focusNode;

  TextBoxWidgetModel({
    required this.id,
    required this.position,
    this.size = const Size(260, 0),
    String initialText = '',
    this.fontSize = 16.0,
    this.style = TextBoxStyle.defaults,
    this.author,
    this.layer = baseLayerId,
    this.group = noGroup,
  }) : _text = initialText;

  /// The text (Markdown source) of the box.
  String get text => _controller?.text ?? _text;
  set text(String value) {
    final c = _controller;
    if (c != null) {
      c.text = value;
    } else {
      _text = value;
    }
  }

  /// The formatting of [text]; changed in place.
  List<TextSpanAttribute> get attributes => _controller?.attributes ?? _attributes;

  /// What edits the box's text; made the first time it is asked for, with the text and formatting there are.
  RichInlineTextController get controller => _controller ??= RichInlineTextController()
    ..text = _text
    ..attributes.addAll(_attributes);

  /// Whether [controller] has been made (the box is, or was, shown in an editor).
  bool get hasController => _controller != null;

  FocusNode get focusNode => _focusNode ??= FocusNode();

  /// Lets go of the controller and the focus node, if they were made. The box keeps its text.
  void dispose() {
    final c = _controller;
    if (c != null) {
      _text = c.text;
      _attributes
        ..clear()
        ..addAll(c.attributes);
      c.dispose();
    }
    _controller = null;
    _focusNode?.dispose();
    _focusNode = null;
  }
}

/// [document] is classic Markdown text editing instead of placing items on pages.
enum CanvasInteractionMode { selectText, draw, document }
