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

/// A line drawn with the pen, or a shape; the points are in the page space of the editor.
/// The id of the layer every note has and every line was on before there were layers (see `layers.dart`). It cannot be deleted.
const String baseLayerId = '';

class DrawingStroke {
  /// Names the stroke across devices and saves; it never changes.
  final String id;

  /// The look of the line: the colour, the width, and the dashes can be changed afterwards (a selected shape has a style dialog).
  Color color;
  double width;
  StrokeDash dash;

  /// What a closed line (a rectangle, an ellipse, a loop) is filled with; null: nothing.
  Color? fill;
  final List<Offset> points;

  /// How hard the pen pressed at each point (0 to 255, one for each point), for a line drawn with a pressure-sensitive pen:
  /// the line is thicker where it was pressed harder. Null for a line with no pressure (finger, mouse, shapes).
  List<int>? pressures;

  /// Who drew it (the name they had then); null if not known, as for notes from before names were kept.
  String? author;

  /// The brush that drew it, by [Brush.id]: how the points become a line (see `brushes.dart`). A line of a brush this app does
  /// not know (one from an extension that is not here) is drawn as the pen would.
  String brush;

  /// The layer it is on, by id (see `layers.dart`); [baseLayerId] for a line drawn before there were layers. A layer that is not
  /// there (it was deleted) is the base layer.
  String layer;

  /// For a connector: the items its ends are fixed to (see `connector.dart`). The points are what it is drawn from; the editor
  /// makes them again when an item moves. Null for a line that is just a line.
  StrokeLink? link;

  /// The group it belongs to, by id ([noGroup] for none): what is in a group is selected, moved, copied and deleted together.
  String group;

  /// For a line made with the pen for curves: the points and handles it was made from, so that it can be bent again. They are
  /// kept as they were when the line was finished; if the line has been moved or resized since, [CurvedPath] is fitted to it again
  /// when it is needed (see `fittedCurve` in `bezier.dart`).
  CurvedPath? curve;

  /// For a closed line whose inside runs from [fill] to another colour: how (see `gradient.dart`). Null: the fill is one colour.
  FillGradient? gradient;

  /// Text that runs along the line or is written inside the shape, and goes where it goes (see `stroke_label.dart`). Null: none.
  StrokeLabel? label;

  DrawingStroke({
    String? id,
    required this.color,
    required this.width,
    required this.points,
    this.author,
    this.dash = StrokeDash.solid,
    this.fill,
    this.pressures,
    this.brush = penBrushId,
    this.layer = baseLayerId,
    this.link,
    this.group = noGroup,
    this.curve,
    this.gradient,
    this.label,
  }) : id = id ?? newElementId();

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

  /// A cheap fingerprint of the stroke: its colour, width, author, length and a sample of its points
  /// (about sixteen, the first and last among them). Every way a stroke changes (more points,
  /// moved, straightened, put back) changes a sample; reading all of the points of every
  /// stroke at each save is what this avoids.
  int get stamp {
    final n = points.length;
    final step = n <= 16 ? 1 : n ~/ 16;
    final pr = pressures;
    var h = Object.hash(color.toARGB32(), width, n, author, dash, fill?.toARGB32(), pr == null || pr.isEmpty ? 0 : Object.hash(pr.length, pr.first, pr.last), brush, link, layer, group, curve == null || curve!.nodes.isEmpty ? 0 : Object.hash(curve!.nodes.length, curve!.closed, curve!.nodes.first.at, curve!.nodes.last.at, curve!.nodes.first.out, curve!.nodes.last.inn), gradient, label);
    for (var i = 0; i < n; i += step) {
      h = Object.hash(h, points[i]);
    }
    return n == 0 ? h : Object.hash(h, points.last);
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
  /// counts too), measured to the line segments between the points.
  bool isNear(Offset p, double radius) {
    final reach = radius + width / 2, reach2 = reach * reach;
    final px = p.dx, py = p.dy;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = i + 1 < points.length ? points[i + 1] : a;
      final ax = a.dx, ay = a.dy, bx = b.dx, by = b.dy;
      // (the eraser asks this of every line at every move: a segment whose box is out of reach is not measured)
      if (px < math.min(ax, bx) - reach || px > math.max(ax, bx) + reach || py < math.min(ay, by) - reach || py > math.max(ay, by) + reach) continue;
      final abx = bx - ax, aby = by - ay;
      final len2 = abx * abx + aby * aby;
      final t = len2 == 0 ? 0.0 : (((px - ax) * abx + (py - ay) * aby) / len2).clamp(0.0, 1.0);
      final dx = px - (ax + abx * t), dy = py - (ay + aby * t);
      if (dx * dx + dy * dy <= reach2) return true;
    }
    return false;
  }
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

/// A text box on a page: its place, size, text with formatting ([controller]) and look.
class TextBoxWidgetModel {
  final String id;
  Offset position;

  /// The width of the box, and the least height it keeps (0: as tall as its text).
  /// The box grows with its text, so the height is only what the person pulled it to.
  Size size;
  RichInlineTextController controller;
  FocusNode focusNode;
  double fontSize;
  TextBoxStyle style;

  /// Who made the box; null if not known.
  String? author;

  /// The layer it is on, by id (see `layers.dart`); a layer that is not there is the base layer.
  String layer;

  /// The group it belongs to ([noGroup] for none), see [DrawingStroke.group].
  String group;

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
  })  : controller = RichInlineTextController()..text = initialText,
        focusNode = FocusNode();
}

/// [document] is classic Markdown text editing instead of placing items on pages.
enum CanvasInteractionMode { selectText, draw, document }
