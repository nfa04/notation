import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'brush_effects.dart';
import 'canvas_models.dart';
import 'outline.dart';

export 'brush_effects.dart';
export 'outline.dart';

/// The id of the brush every line had before there were brushes: the pressure-sensitive pen.
const String penBrushId = 'pen';

/// The id of the roller: an even line of one width, whatever the pressure, smoothed between the points.
const String rollerBrushId = 'roller';

/// What a [Brush] makes of a line: a path, and whether it is to be filled (an outline the brush worked out itself) or stroked
/// with the line's width, round at the ends; and how opaque it is drawn (on top of the colour's own opacity).
class BrushShape {
  /// The shape, kept as its pieces so that a PDF can be given them as they are (see [Outline]).
  final Outline outline;
  final bool filled;
  final double opacity;

  /// More to draw over the path, each with its own opacity (on top of [opacity]): the streaks of a roller.
  final List<BrushLayer> layers;

  /// A better way to draw the same line where the screen can blur (see [SoftLayers]); [path], [opacity] and [layers] stay the
  /// look for everywhere that cannot (the PDF export draws only those).
  final SoftLayers? soft;

  /// Whether the line is drawn so that it darkens what it lies on, as a marker does (a multiply blend): where lines cross, or a line
  /// crosses itself in two layers, the colours multiply. The PDF export says the same.
  final bool multiply;

  /// What is drawn first, behind the shape: a shadow, a glow, an outline (each with its own opacity and colour, as the [layers]).
  final List<BrushLayer> under;

  /// Another shape drawn over this one, for the same line (a brush that mixes two). Null for most.
  final BrushShape? next;

  /// The line this shape is made for, if that is not the line that is being drawn: the line a mixed brush gives its second part (the
  /// same points, another thickness). Null: the line itself.
  final DrawingStroke? line;
  const BrushShape(this.outline,
      {this.filled = false, this.opacity = 1, this.layers = const [], this.soft, this.multiply = false, this.under = const [], this.next, this.line});

  /// This shape with [next] drawn over it.
  BrushShape withNext(BrushShape next) =>
      BrushShape(outline, filled: filled, opacity: opacity, layers: layers, soft: soft, multiply: multiply, under: under, next: next, line: line);

  /// This shape, made for [line] (see [line]).
  BrushShape forLine(DrawingStroke line) =>
      BrushShape(outline, filled: filled, opacity: opacity, layers: layers, soft: soft, multiply: multiply, under: under, next: next, line: line);

  Path get path => outline.path;
}

/// A shape drawn over the one of a [BrushShape], with an opacity of its own.
class BrushLayer {
  final Outline outline;
  final double opacity;

  /// How much lighter (positive) or darker (negative) than the line's colour this layer is drawn, as a part of the range of
  /// lightness (0: the colour as it is), and how many degrees round the colour wheel its hue is turned. Brushes that vary their
  /// colour along a line draw the pieces of it as layers of their own.
  final double lightness, hue;

  /// Whether a colour with no hue (black, grey, white) is made a colour that has one before it is turned: a rainbow on a black pen.
  final bool vivid;
  const BrushLayer(this.outline, this.opacity, {this.lightness = 0, this.hue = 0, this.vivid = false});

  /// Whether the layer is drawn in a colour of its own (and not the colour of the line).
  bool get tinted => lightness != 0 || hue != 0 || vivid;

  /// [base] as this layer is drawn.
  Color colorOf(Color base) => tintedColor(base, lightness, hue, vivid: vivid);

  Path get path => outline.path;
}

/// [base] made lighter or darker by [lightness] (from -1 to 1, of the whole range) and its hue turned by [hue] degrees; the opacity is kept.
///
/// With [vivid], a colour that has hardly any saturation (black, grey, white, so that turning its hue shows nothing) first becomes a
/// mid-light colour with saturation, so that the turn can be seen.
Color tintedColor(Color base, double lightness, double hue, {bool vivid = false}) {
  if (lightness == 0 && hue == 0 && !vivid) return base;
  var hsl = HSLColor.fromColor(base);
  if (vivid && hsl.saturation < 0.2) hsl = hsl.withSaturation(0.8).withLightness(hsl.lightness.clamp(0.35, 0.6));
  return hsl.withLightness((hsl.lightness + lightness).clamp(0.0, 1.0)).withHue((hsl.hue + hue) % 360).toColor();
}

/// The layers drawn behind a line for its [LineEffects]: a glow, a shadow, an outline, the furthest first. [make] gives the shape of the
/// line made [grow] thicker on every side and moved by [shift].
List<BrushLayer> behindLayers(LineEffects fx, double width, Outline Function(double grow, Offset shift) make) {
  final out = <BrushLayer>[];
  if (fx.glow > 0) {
    const opacities = [0.16, 0.22, 0.3];
    for (var j = 0; j < opacities.length; j++) {
      out.add(BrushLayer(make(width * fx.glow * 0.9 * (3 - j) / 3, Offset.zero), opacities[j], hue: fx.glowHue, vivid: fx.glowHue != 0));
    }
  }
  if (fx.shadow > 0) {
    final shift = const Offset(0.6, 0.8) * (fx.shadowDistance * width);
    if (fx.shadowBlur <= 0) {
      out.add(BrushLayer(make(0, shift), fx.shadow, lightness: -1));
    } else {
      const opacities = [0.18, 0.22, 0.3, 0.45];
      for (var j = 0; j < opacities.length; j++) {
        out.add(BrushLayer(make(width * 0.6 * fx.shadowBlur * (3 - j) / 3, shift), fx.shadow * opacities[j], lightness: -1));
      }
    }
  }
  if (fx.outline > 0) {
    final tone = fx.outlineTone.round();
    out.add(BrushLayer(make(width * fx.outline * 0.5, Offset.zero), 1, lightness: tone == 0 ? -1 : (tone == 1 ? 1 : 0), hue: tone == 2 ? 180 : 0, vivid: tone == 2));
  }
  return out;
}

/// What a brush draws with blurred edges: [blurred] are filled paths each drawn with a gaussian blur of [blur] (its standard
/// deviation, in the units of the page), then the sharp [crisp] ones on top (specks of spray). All in the colour of the line,
/// each with its own opacity.
class SoftLayers {
  final List<({Path path, double opacity, double blur})> blurred;
  final List<({Path path, double opacity})> crisp;

  /// Filled paths drawn through the grain of paper: the colour shows only where a fixed pattern of fine specks lets it, so that
  /// the paint looks rubbed on a rough surface (charcoal). The same pattern lies under every line, as the paper does.
  final List<({Path path, double opacity})> grain;
  const SoftLayers({this.blurred = const [], this.crisp = const [], this.grain = const []});

  /// The area the layers reach, blur included.
  Rect get bounds {
    Rect? r;
    for (final l in blurred) {
      final b = l.path.getBounds().inflate(l.blur * 3);
      r = r == null ? b : r.expandToInclude(b);
    }
    for (final l in [...crisp, ...grain]) {
      final b = l.path.getBounds();
      r = r == null ? b : r.expandToInclude(b);
    }
    return (r ?? Rect.zero).inflate(2);
  }
}

/// How the points of a line become what is drawn. The line keeps its brush by [id] (see [DrawingStroke.brush]) and its points,
/// colour and width as ever, so that a brush only decides the look: a note drawn with a brush that is missing still shows the
/// lines, as the pen draws them.
abstract class Brush {
  const Brush();

  /// Names the brush in saved notes and across devices; never changes. Brushes of extensions are `ext:<extension id>/<id>`.
  String get id;

  /// What the drawing bar calls it.
  String get label;

  IconData get icon;

  /// How many times thicker than the width chosen in the drawing bar the line is made (the width of the line is then what it is).
  double get widthScale => 1;

  /// Whether a pen that can tell how hard it presses matters: the line then keeps a pressure for every point.
  bool get usesPressure => false;

  /// Whether lines of this brush are writing, to be read as handwriting or maths: false for a brush that paints (a roller, a wash).
  bool get writing => true;

  /// The shape of [stroke], or null for the way the pen is drawn.
  BrushShape? shape(DrawingStroke stroke);
}

/// The pressure-sensitive pen: thicker where the pen pressed harder. Drawn by the painter itself.
class PenBrush extends Brush {
  const PenBrush();

  @override
  String get id => penBrushId;

  @override
  String get label => 'Pen';

  @override
  IconData get icon => Icons.edit_outlined;

  @override
  bool get usesPressure => true;

  @override
  BrushShape? shape(DrawingStroke stroke) => null;
}

/// The numbers that make a roller (see [RollerBrush]); the defaults are the roller the app comes with.
class RollerParams {
  /// How many times thicker than the width that is set the band is.
  final double width;

  /// How much of the colour the first coat has (the streaks and the edges add to it).
  final double coat;

  /// How strong the streaks of the nap are (1: as the roller comes; 0: none).
  final double streaks;

  /// How strong the ridges of paint at both edges are.
  final double ridge;

  /// How much of the roller is dry: the part of the lanes that took no extra paint (0: all took some).
  final double dryness;

  /// How long the pieces of a streak are, compared to the roller's own (1).
  final double streakLength;

  /// How wide the lanes of the nap are, compared to the roller's own (1).
  final double laneWidth;

  /// How wide the ridge at each edge is, as a part of the whole band (0.14 is the roller's own).
  final double ridgeWidth;

  /// Whether the paint darkens what it lies on (see [BrushShape.multiply]).
  final bool multiply;

  const RollerParams({
    this.width = 5,
    this.coat = 0.5,
    this.streaks = 1,
    this.ridge = 0.35,
    this.dryness = 0.3,
    this.streakLength = 1,
    this.laneWidth = 1,
    this.ridgeWidth = 0.14,
    this.multiply = false,
  });

  @override
  bool operator ==(Object other) =>
      other is RollerParams &&
      other.width == width &&
      other.coat == coat &&
      other.streaks == streaks &&
      other.ridge == ridge &&
      other.dryness == dryness &&
      other.streakLength == streakLength &&
      other.laneWidth == laneWidth &&
      other.ridgeWidth == ridgeWidth &&
      other.multiply == multiply;

  @override
  int get hashCode => Object.hash(width, coat, streaks, ridge, dryness, streakLength, laneWidth, ridgeWidth, multiply);
}

/// A paint roller: a wide flat band that keeps across the way it is moved, square at the ends, with the streaks the nap of a roller
/// leaves along the way (some lanes took more paint than others, in lengths) and the ridges of paint at both edges. The paint is
/// not quite opaque, so that it looks rolled on. It is thick (five times the width chosen in the bar) and takes no pressure.
class RollerBrush extends Brush {
  @override
  final String id;
  @override
  final String label;
  final RollerParams params;

  const RollerBrush({this.id = rollerBrushId, this.label = 'Roller', this.params = const RollerParams()});

  @override
  IconData get icon => Icons.format_paint_outlined;

  @override
  double get widthScale => params.width;

  @override
  bool get writing => false;

  @override
  bool operator ==(Object other) => other is RollerBrush && other.id == id && other.label == label && other.params == params;

  @override
  int get hashCode => Object.hash(id, label, params);

  /// The opacity of the streak levels (a lane that took a little, some or much paint more), before [RollerParams.streaks] scales them.
  static const _streakLevels = [0.2, 0.42, 0.68];

  @override
  BrushShape? shape(DrawingStroke stroke) {
    final w = stroke.width;
    final centre = _centreline(stroke.points, w);
    final n = centre.length;
    final normal = _normals(centre);
    Offset at(int i, double lateral) => centre[i] + normal[i] * (lateral * w / 2);

    /// The part of the band between the lateral positions [a] and [b] (-1 to 1) from the sample [from] to [to].
    void band(Outline path, int from, int to, double a, double b) =>
      path.addPolygon([
      for (var i = from; i <= to; i++) at(i, b),
      for (var i = to; i >= from; i--) at(i, a),
        ]);

    final base = Outline();
    band(base, 0, n - 1, -1, 1);

    // streaks: lanes along the line, each cut into lengths of its own, that took a little more paint or not
    final lanes = (w / (1.6 * params.laneWidth)).round().clamp(8, 40);
    final seed = ParamBrush._fnv(stroke.id);
    final levels = [for (var i = 0; i < _streakLevels.length; i++) Outline()];
    final ridges = Outline();
    var chunk = 0;
    for (var from = 0; from < n - 1; chunk++) {
      final usual = 10 + (ParamBrush._noise(seed, 7919 + chunk) * 30).floor();
      final length = params.streakLength == 1 ? usual : (usual * params.streakLength).round().clamp(2, 100000);
      final to = math.min(n - 1, from + length);
      var lane = 0;
      while (lane < lanes) {
        final level = _level(ParamBrush._noise(seed, lane * 131 + chunk * 17 + 1));
        var end = lane + 1;
        // (lanes next to each other with the same level are one piece, so that no seam shows between them)
        while (end < lanes && _level(ParamBrush._noise(seed, end * 131 + chunk * 17 + 1)) == level) {
          end++;
        }
        if (level > 0) band(levels[level - 1], from, to, -1 + 2 * lane / lanes, -1 + 2 * end / lanes);
        lane = end;
      }
      from = to;
    }
    // (0.14 wide, written out: the numbers of the roller the app comes with are the same to the last digit)
    final inner = params.ridgeWidth == 0.14 ? 0.86 : 1 - params.ridgeWidth;
    band(ridges, 0, n - 1, -1, -inner);
    band(ridges, 0, n - 1, inner, 1);

    return BrushShape(base, filled: true, opacity: params.coat, multiply: params.multiply, layers: [
      for (var i = 0; i < levels.length; i++) BrushLayer(levels[i], (_streakLevels[i] * params.streaks).clamp(0.0, 1.0)),
      BrushLayer(ridges, params.ridge),
    ]);
  }

  /// How much more paint a lane took, for a number from 0 to 1: 0 none (the lanes below [RollerParams.dryness] are dry), up to 3.
  /// (The three levels share what is left in the proportions the roller always had: with the usual 0.3 dry they end at 0.55 and 0.8.)
  int _level(double v) {
    final d = params.dryness;
    final rest = 1 - d;
    return v < d ? 0 : (v < d + 0.25 * (rest / 0.7) ? 1 : (v < d + 0.5 * (rest / 0.7) ? 2 : 3));
  }

  /// The way of the roller as an even, smooth line of points about 3 apart (fewer for a very long line).
  static List<Offset> _centreline(List<Offset> points, double width) {
    var pts = points;
    for (var r = 0; r < 2 && pts.length >= 3 && pts.length <= 1500; r++) {
      pts = ParamBrush._chaikin(pts, null).$1;
    }
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += (pts[i] - pts[i - 1]).distance;
    }
    final spacing = math.max(3.0, total / 2500);
    final out = <Offset>[pts.first];
    var carried = 0.0;
    for (var i = 1; i < pts.length; i++) {
      var a = pts[i - 1];
      final b = pts[i];
      var left = (b - a).distance;
      while (left > 0 && carried + left >= spacing) {
        final step = spacing - carried;
        a = a + (b - a) * (step / left);
        out.add(a);
        left = (b - a).distance;
        carried = 0;
      }
      carried += left;
    }
    if ((out.last - pts.last).distance > 0.01) out.add(pts.last);
    if (out.length < 2) out.add(out.first + const Offset(0.1, 0));
    return out;
  }

  /// The unit normals along [c]: across the direction of the way, which turns smoothly (the roller does not twist on a corner).
  static List<Offset> _normals(List<Offset> c) {
    final n = c.length;
    final dir = <Offset>[];
    for (var i = 0; i < n; i++) {
      final d = c[math.min(n - 1, i + 1)] - c[math.max(0, i - 1)];
      dir.add(d.distance < 1e-9 ? const Offset(1, 0) : d / d.distance);
    }
    final out = <Offset>[];
    for (var i = 0; i < n; i++) {
      var sum = Offset.zero;
      for (var k = math.max(0, i - 4); k <= math.min(n - 1, i + 4); k++) {
        sum += dir[k];
      }
      final d = sum.distance < 1e-9 ? dir[i] : sum / sum.distance;
      out.add(Offset(-d.dy, d.dx));
    }
    return out;
  }
}

/// The look of a brush that is described by numbers, as an extension does it (see [ParamBrush]).
class BrushParams {
  /// How thick it draws compared to the width that is set (1: as set).
  final double width;

  /// How much the pressure of the pen matters to the thickness (0: none, 1: from a third to one and two thirds of the width).
  final double pressure;

  /// How much the corners the points make are rounded off (0: none, 1: much).
  final double smoothing;

  /// How much the ends of a line run out to a point (0: round ends, 1: long points).
  final double taper;

  /// How opaque the line is drawn (1: fully). Where the line crosses itself it does not get darker.
  final double opacity;

  /// How uneven the edges of the line are, as those of a pencil on rough paper (0: even).
  final double jitter;

  /// The angle of a flat nib in degrees (0: horizontal), as a calligraphy pen has: thick across the nib, thin along it.
  /// Null: a round tip.
  final double? nibAngle;

  /// How thick a flat nib is compared to how wide it is (1: as thick as wide, which is a square; small: thin strokes).
  final double nibFlatness;

  /// Bends the response to the pressure: above 1 it takes a hard press to get thick, below 1 a light touch already does (1: straight).
  final double pressureCurve;

  /// How much thinner the line gets where the pen moves fast (0: not at all).
  final double speedThin;

  /// How much the start and the end run out to a point, each of its own; null: [taper], as ever.
  final double? startTaper, endTaper;

  /// How much the thickness swells and shrinks slowly along the line, as a hand does (0: not at all).
  final double waver;

  /// How much the colour varies along the line: lighter and darker (0..1), and turned round the colour wheel (degrees at most).
  final double lightness, hue;

  /// Whether the line darkens what it lies on (see [BrushShape.multiply]).
  final bool multiply;

  /// The thickness the pen's pressure gives, as a curve: five points from the lightest touch to the hardest press, each how thick the
  /// line is there compared to the width that is set. Null: [pressure] and [pressureCurve] say it. The same for the speed of the hand
  /// (from standing still to twice the usual speed), instead of [speedThin].
  final List<double>? pressurePoints, speedPoints;

  /// How much the points of a line are averaged with their neighbours, so that a shaky hand draws a steadier line (0: not at all).
  final double stabilise;

  /// How the colour changes along the line, and what is drawn round it.
  final ColourFlow flow;
  final LineEffects effects;

  const BrushParams({
    this.width = 1,
    this.pressure = 0,
    this.smoothing = 0.5,
    this.taper = 0,
    this.opacity = 1,
    this.jitter = 0,
    this.nibAngle,
    this.nibFlatness = 0.15,
    this.pressureCurve = 1,
    this.speedThin = 0,
    this.startTaper,
    this.endTaper,
    this.waver = 0,
    this.lightness = 0,
    this.hue = 0,
    this.multiply = false,
    this.pressurePoints,
    this.speedPoints,
    this.stabilise = 0,
    this.flow = ColourFlow.none,
    this.effects = LineEffects.none,
  });

  @override
  bool operator ==(Object other) =>
      other is BrushParams &&
      other.width == width &&
      other.pressure == pressure &&
      other.smoothing == smoothing &&
      other.taper == taper &&
      other.opacity == opacity &&
      other.jitter == jitter &&
      other.nibAngle == nibAngle &&
      other.nibFlatness == nibFlatness &&
      other.pressureCurve == pressureCurve &&
      other.speedThin == speedThin &&
      other.startTaper == startTaper &&
      other.endTaper == endTaper &&
      other.waver == waver &&
      other.lightness == lightness &&
      other.hue == hue &&
      other.multiply == multiply &&
      sameCurve(other.pressurePoints, pressurePoints) &&
      sameCurve(other.speedPoints, speedPoints) &&
      other.stabilise == stabilise &&
      other.flow == flow &&
      other.effects == effects;

  @override
  int get hashCode => Object.hashAll([
        width, pressure, smoothing, taper, opacity, jitter, nibAngle, nibFlatness, pressureCurve, speedThin, startTaper, endTaper, waver, lightness, hue, multiply,
        Object.hashAll(pressurePoints ?? const []), Object.hashAll(speedPoints ?? const []), stabilise, flow, effects, //
      ]);
}

/// A brush made of [BrushParams]: it draws a filled outline, so that the thickness can follow the pressure, the ends, the
/// direction of a nib and the unevenness of paper. Extensions bring these (`brushes` in the manifest) without any code.
class ParamBrush extends Brush {
  @override
  final String id;
  @override
  final String label;
  final BrushParams params;
  @override
  final IconData icon;

  const ParamBrush(this.id, this.label, this.params, {this.icon = Icons.brush_outlined});

  @override
  double get widthScale => params.width;

  @override
  bool get usesPressure => params.pressure > 0 || params.pressurePoints != null || params.flow.pressureShade != 0;

  @override
  bool operator ==(Object other) => other is ParamBrush && other.id == id && other.label == label && other.params == params;

  @override
  int get hashCode => Object.hash(id, label, params);

  /// Beyond this many points the line is not rounded further (the work grows with every round).
  static const _smoothest = 1500;

  @override
  BrushShape? shape(DrawingStroke stroke) {
    var pts = stroke.points;
    if (pts.isEmpty) return null;
    final given = stroke.pressures;
    final curve = params.pressurePoints;
    final wantsPressure = params.pressure > 0 || curve != null || params.flow.pressureShade != 0;
    List<double>? pr = wantsPressure && given != null && given.length == pts.length ? [for (final v in given) v / 255] : null;

    if (params.stabilise > 0 && pts.length >= 3) pts = _steadied(pts, params.stabilise);
    final rounds = params.smoothing <= 0 ? 0 : (params.smoothing < 0.5 ? 1 : 2);
    for (var r = 0; r < rounds && pts.length >= 3 && pts.length <= _smoothest; r++) {
      final (p2, q2) = _chaikin(pts, pr);
      pts = p2;
      pr = q2;
    }

    final n = pts.length;
    final along = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      along[i] = along[i - 1] + (pts[i] - pts[i - 1]).distance;
    }
    final total = along.last;
    final seed = _fnv(stroke.id);
    final taperLength = math.min(params.taper * 30, total / 2);
    // (the ends can run out each in its own way; a brush that says nothing about it runs out as ever)
    final eachEnd = params.startTaper != null || params.endTaper != null;
    final startLength = math.min((params.startTaper ?? params.taper) * 30, total / 2);
    final endLength = math.min((params.endTaper ?? params.taper) * 30, total / 2);
    // (the speed: how far apart the points are, against how far apart they are on the whole, over a few points)
    final speedCurve = params.speedPoints;
    List<double>? speed;
    if ((params.speedThin > 0 || speedCurve != null || params.flow.speedShade != 0) && n > 2 && total > 0) {
      final gap = [for (var i = 0; i < n; i++) i == 0 ? along[1] : along[i] - along[i - 1]];
      final mean = total / (n - 1);
      speed = [
        for (var i = 0; i < n; i++)
          () {
            var sum = 0.0, count = 0;
            for (var k = math.max(0, i - 3); k <= math.min(n - 1, i + 3); k++) {
              sum += gap[k];
              count++;
            }
            return sum / count / mean;
          }(),
      ];
    }
    final knots = params.waver > 0 ? <double>[for (var i = 0; i <= total ~/ 14 + 1; i++) _noise(seed, 5000011 + i) - 0.5] : const <double>[];
    final factor = List<double>.filled(n, 1);
    for (var i = 0; i < n; i++) {
      var f = pr == null || (curve == null && params.pressure <= 0)
          ? 1.0
          : curve != null
              ? curveValue(curve, pr[i])
              : pressureFactor(params.pressureCurve == 1 ? pr[i] : math.pow(pr[i], params.pressureCurve).toDouble(), params.pressure);
      if (eachEnd) {
        var ends = 1.0;
        if (startLength > 0) ends = math.min(ends, (along[i] / startLength).clamp(0.0, 1.0));
        if (endLength > 0) ends = math.min(ends, ((total - along[i]) / endLength).clamp(0.0, 1.0));
        if (startLength > 0 || endLength > 0) f *= 0.12 + 0.88 * ends;
      } else if (taperLength > 0) {
        final edge = math.min(along[i], total - along[i]);
        f *= 0.12 + 0.88 * (edge / taperLength).clamp(0.0, 1.0);
      }
      if (params.jitter > 0) f *= 1 + params.jitter * (_noise(seed, i) - 0.5) * 0.9;
      if (speed != null) {
        if (speedCurve != null) {
          f *= curveValue(speedCurve, speed[i] / 2);
        } else if (params.speedThin > 0) {
          f *= (1 - params.speedThin * 0.35 * (speed[i] - 1).clamp(-1.0, 2.0)).clamp(0.3, 1.6);
        }
      }
      if (knots.isNotEmpty) {
        final at = along[i] / 14, j = at.floor();
        f *= 1 + params.waver * 0.9 * (knots[j] + (knots[j + 1] - knots[j]) * (at - j));
      }
      factor[i] = f;
    }

    final width = stroke.width;
    final nib = params.nibAngle;
    // (the shape of a part of the line; [grow] makes it that much thicker on each side)
    Outline outlineOf(List<Offset> p, List<double> fs, [double grow = 0, bool roundStart = true, bool roundEnd = true]) {
      if (nib != null) return _nibOutline(p, fs, width, nib * math.pi / 180, params.nibFlatness, grow);
      final half = [for (final f in fs) width * f / 2 + grow];
      return roundStart && roundEnd ? ribbonOutline(p, half) : _cutRibbon(p, half, roundStart, roundEnd);
    }

    final fx = params.effects;
    final runs = fx.dash > 0 && n >= 2 && total > 0 ? _dashRuns(pts, factor, along, total, width, fx) : [(pts: pts, factor: factor, along: along)];
    Outline whole([double grow = 0, Offset shift = Offset.zero]) {
      if (runs.length == 1 && grow == 0 && shift == Offset.zero) return outlineOf(runs.first.pts, runs.first.factor);
      final out = Outline();
      for (final r in runs) {
        out.addOutline(outlineOf(shift == Offset.zero ? r.pts : [for (final q in r.pts) q + shift], r.factor, grow));
      }
      return out;
    }

    final under = fx.hasBehind ? behindLayers(fx, width, (grow, shift) => whole(grow, shift)) : const <BrushLayer>[];
    final randomTint = params.lightness > 0 || params.hue > 0;
    final flow = params.flow;

    // a colour that varies: the line is cut into pieces about as long as it is thick, each drawn in one of the colours near the line's
    if ((randomTint || flow.active) && n >= 2 && total > 0) {
      final pieceLength = math.max(6.0, width * 1.5);
      (double, double, double) tintOf(int piece, double mid) {
        var l = 0.0, h = 0.0, o = 1.0;
        if (randomTint) {
          final bucket = (_noise(seed, 9100000 + piece) * 5).floor().clamp(0, 4);
          l = (bucket - 2) / 2 * params.lightness * 0.3;
          h = (bucket - 2) / 2 * params.hue;
        }
        if (flow.active) {
          final t = (mid / total).clamp(0.0, 1.0);
          if (flow.gradientHue != 0 || flow.gradientLight != 0) {
            final q = (t * 8).floor().clamp(0, 7) / 7;
            h += flow.gradientHue * q;
            l += flow.gradientLight * q;
          }
          if (flow.rainbow > 0) h += (((mid / (flow.rainbow * width)) % 1.0) * 12).floor() * 30.0;
          if (flow.fade != 0) {
            final q = (t * 6).floor().clamp(0, 5) / 5;
            o *= flow.fade > 0 ? 1 - flow.fade * q : 1 + flow.fade * (1 - q);
          }
          if (flow.pressureShade != 0 && pr != null) {
            final x = ((_valueAt(pr, along, mid) * 5).floor().clamp(0, 4) + 0.5) / 5;
            l += flow.pressureShade * (x - 0.5) * 0.8;
          }
          if (flow.speedShade != 0 && speed != null) {
            final x = (((_valueAt(speed, along, mid) / 2).clamp(0.0, 1.0) * 5).floor().clamp(0, 4) + 0.5) / 5;
            l += flow.speedShade * (x - 0.5) * 0.8;
          }
          l = (l * 1000).round() / 1000;
          h = (h * 1000).round() / 1000;
          o = (o.clamp(0.05, 1.0) * 1000).round() / 1000;
        }
        return (l, h, o);
      }

      final groups = <(double, double, double), Outline>{};
      for (final r in runs) {
        final m = r.pts.length;
        var from = 0;
        while (from < m - 1) {
          final piece = (r.along[from] / pieceLength).floor();
          var to = from + 1;
          while (to < m - 1 && (r.along[to] / pieceLength).floor() == piece) {
            to++;
          }
          // (pieces of different colours are put end to end: cut straight across, so that none lies over the next, with the corner between them filled)
          final here = groups[tintOf(piece, (r.along[from] + r.along[to]) / 2)] ??= Outline();
          here.addOutline(outlineOf(r.pts.sublist(from, to + 1), r.factor.sublist(from, to + 1), 0, from == 0, to == m - 1));
          from = to;
        }
      }
      final shades = _fewShades(groups);
      // (a rainbow on a black pen has no colour to turn: every part is a colour of its own, so there is no line's own colour left)
      final vivid = flow.turnsHue;
      Outline? base;
      final layers = <BrushLayer>[];
      for (final key in shades) {
        final (l, h, o) = key;
        if (!vivid && l == 0 && h == 0 && o == 1) {
          base = groups[key];
        } else {
          layers.add(BrushLayer(groups[key]!, params.opacity * o, lightness: l, hue: h, vivid: vivid));
        }
      }
      return BrushShape(base ?? Outline(), filled: true, opacity: params.opacity, multiply: params.multiply, layers: layers, under: under);
    }
    return BrushShape(whole(), filled: true, opacity: params.opacity, multiply: params.multiply, under: under);
  }

  /// A ribbon like [ribbonOutline] but with joints that are not round (a corner is cut off flat) and, where [roundStart] or [roundEnd]
  /// is false, an end cut straight across the line. Pieces of different colours put end to end then do not lie over each other.
  /// Quads for the segments and two triangles at each joint (one of them lies inside the quads), all wound as the rest of an outline.
  static Outline _cutRibbon(List<Offset> pts, List<double> half, bool roundStart, bool roundEnd) {
    final out = Outline();
    final n = pts.length;
    Offset? before;
    for (var i = 0; i < n - 1; i++) {
      final d = pts[i + 1] - pts[i];
      final len = d.distance;
      if (len < 1e-6) continue;
      final normal = Offset(-d.dy / len, d.dx / len);
      final a = pts[i], b = pts[i + 1];
      out.addPolygon([a - normal * half[i], b - normal * half[i + 1], b + normal * half[i + 1], a + normal * half[i]]);
      if (before != null) {
        final previous = before;
        final l1 = previous.distance;
        final n1 = Offset(-previous.dy / l1, previous.dx / l1);
        for (final side in const [-1.0, 1.0]) {
          final p1 = a + n1 * (half[i] * side), p2 = a + normal * (half[i] * side);
          if ((p1 - p2).distance < 0.05) continue;
          final area = a.dx * p1.dy - p1.dx * a.dy + p1.dx * p2.dy - p2.dx * p1.dy + p2.dx * a.dy - a.dx * p2.dy;
          out.addPolygon(area >= 0 ? [a, p1, p2] : [a, p2, p1]);
        }
      }
      before = d;
    }
    if (roundStart) out.addOval(Rect.fromCircle(center: pts.first, radius: half.first));
    if (roundEnd) out.addOval(Rect.fromCircle(center: pts.last, radius: half.last));
    return out;
  }

  /// The most layers a line of changing colour is drawn in.
  static const _mostShades = 40;

  /// The keys of [groups] from the darkest to the lightest; if there are more than [_mostShades] of them, nearly equal ones are put
  /// together (the outlines of [groups] are added up under the first of each).
  static List<(double, double, double)> _fewShades(Map<(double, double, double), Outline> groups) {
    int order((double, double, double) a, (double, double, double) b) {
      final c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      final d = a.$2.compareTo(b.$2);
      return d != 0 ? d : a.$3.compareTo(b.$3);
    }

    var step = 1.0;
    while (groups.length > _mostShades && step < 64) {
      step *= 2;
      final merged = <(double, double, double), Outline>{};
      for (final e in groups.entries) {
        double snap(double v, double unit) => (v / (unit * step)).round() * unit * step;
        // (how see-through a part is is kept finer than the colours: it has the smaller range)
        final opacity = (e.key.$3 / math.min(0.05 * step, 0.25)).round() * math.min(0.05 * step, 0.25);
        (merged[(snap(e.key.$1, 0.02), snap(e.key.$2, 4), opacity.clamp(0.05, 1.0).toDouble())] ??= Outline()).addOutline(e.value);
      }
      groups
        ..clear()
        ..addAll(merged);
    }
    return groups.keys.toList()..sort(order);
  }

  /// [values] (one for each of the points whose distances along the line are [along]) at the distance [at].
  static double _valueAt(List<double> values, List<double> along, double at) {
    var lo = 0, hi = along.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) ~/ 2;
      if (along[mid] <= at) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = along[hi] - along[lo];
    final t = span <= 0 ? 0.0 : ((at - along[lo]) / span).clamp(0.0, 1.0);
    return values[lo] + (values[hi] - values[lo]) * t;
  }

  /// The line cut into dashes (or dots): each a run of points, with the thickness and the distance along the line at each, and a point
  /// exactly where the dash begins and ends. A dash is [LineEffects.dash] widths long as it looks (the round ends of the line included).
  static List<({List<Offset> pts, List<double> factor, List<double> along})> _dashRuns(
      List<Offset> pts, List<double> factor, List<double> along, double total, double width, LineEffects fx) {
    final n = pts.length;
    final visible = math.max(fx.dash, 1.0) * width;
    var centres = visible - width;
    final period = math.max(visible + fx.dashGap * width, 0.5);
    // (a very long line gets its dashes further apart rather than a thousand more)
    final step = math.max(period, total / 3000);
    centres *= step / period;
    int segmentOf(double at, int from) {
      var k = from;
      while (k < n - 2 && along[k + 1] <= at) {
        k++;
      }
      return k;
    }

    ({Offset p, double f}) at(int seg, double a) {
      final a0 = along[seg], a1 = along[seg + 1];
      final t = a1 > a0 ? ((a - a0) / (a1 - a0)).clamp(0.0, 1.0) : 0.0;
      return (p: Offset.lerp(pts[seg], pts[seg + 1], t)!, f: factor[seg] + (factor[seg + 1] - factor[seg]) * t);
    }

    final runs = <({List<Offset> pts, List<double> factor, List<double> along})>[];
    var seg = 0;
    for (var s = 0.0; s <= total; s += step) {
      final e = math.min(s + centres, total);
      seg = segmentOf(s, seg);
      final first = at(seg, s);
      final p = [first.p], f = [first.f], a = [s];
      var k = seg + 1;
      while (k < n && along[k] < e) {
        p.add(pts[k]);
        f.add(factor[k]);
        a.add(along[k]);
        k++;
      }
      final last = at(math.min(k - 1, n - 2), e);
      p.add(last.p);
      f.add(last.f);
      a.add(e);
      runs.add((pts: p, factor: f, along: a));
    }
    return runs;
  }

  /// [pts] with each point replaced by the average of itself and the [amount] of neighbours on both sides (the ends stay where they are).
  static List<Offset> _steadied(List<Offset> pts, double amount) {
    final reach = (amount * 6).ceil().clamp(1, 6);
    final n = pts.length;
    return [
      for (var i = 0; i < n; i++)
        if (i == 0 || i == n - 1)
          pts[i]
        else
          () {
            final r = math.min(reach, math.min(i, n - 1 - i));
            var sum = Offset.zero;
            for (var j = i - r; j <= i + r; j++) {
              sum += pts[j];
            }
            return sum / (2 * r + 1).toDouble();
          }(),
    ];
  }

  static (List<Offset>, List<double>?) _chaikin(List<Offset> pts, List<double>? pr) {
    final out = <Offset>[pts.first];
    final q = pr == null ? null : <double>[pr.first];
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i], b = pts[i + 1];
      out
        ..add(Offset.lerp(a, b, 0.25)!)
        ..add(Offset.lerp(a, b, 0.75)!);
      if (q != null) {
        q
          ..add(pr![i] + (pr[i + 1] - pr[i]) * 0.25)
          ..add(pr[i] + (pr[i + 1] - pr[i]) * 0.75);
      }
    }
    out.add(pts.last);
    q?.add(pr!.last);
    return (out, q);
  }

  /// The swept shape of a flat nib: for every segment the convex hull of the nib at both of its ends. All pieces wind the same way.
  static Outline _nibOutline(List<Offset> pts, List<double> factor, double width, double angle, double flatness, [double grow = 0]) {
    final c = math.cos(angle), s = math.sin(angle);
    final hw = width / 2 + grow, ht = math.max(0.3, width * flatness / 2) + grow;
    List<Offset> stamp(Offset at, double f) => [
          for (final (x, y) in [(-hw, -ht), (hw, -ht), (hw, ht), (-hw, ht)]) at + Offset((x * c - y * s) * f, (x * s + y * c) * f),
        ];
    final path = Outline();
    if (pts.length == 1 || pts.every((p) => p == pts.first)) {
      path.addPolygon(_hull(stamp(pts.first, factor.first)));
      return path;
    }
    for (var i = 0; i < pts.length - 1; i++) {
      path.addPolygon(_hull([...stamp(pts[i], factor[i]), ...stamp(pts[i + 1], factor[i + 1])]),);
    }
    return path;
  }

  /// The convex hull of [points], wound the way ovals are (clockwise on the screen).
  static List<Offset> _hull(List<Offset> points) {
    final p = List.of(points)..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
    double cross(Offset o, Offset a, Offset b) => (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
    final lower = <Offset>[];
    for (final q in p) {
      while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, q) <= 0) {
        lower.removeLast();
      }
      lower.add(q);
    }
    final upper = <Offset>[];
    for (final q in p.reversed) {
      while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, q) <= 0) {
        upper.removeLast();
      }
      upper.add(q);
    }
    return [...lower.take(lower.length - 1), ...upper.take(upper.length - 1)];
  }

  static int _fnv(String text) {
    var h = 0x811C9DC5;
    for (final u in text.codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  /// A number from 0 to 1 that is always the same for the same line and point.
  static double _noise(int seed, int i) {
    var x = (seed ^ (i * 0x9E3779B1)) & 0xFFFFFFFF;
    x = ((x ^ (x >> 15)) * 0x85EBCA6B) & 0xFFFFFFFF;
    x = ((x ^ (x >> 13)) * 0xC2B2AE35) & 0xFFFFFFFF;
    return ((x ^ (x >> 16)) & 0xFFFF) / 0xFFFF;
  }
}

/// A brush that paints in soft layers: the same line drawn again and again, each time narrower, so that it is lightest at the edges
/// and strongest along the middle (an airbrush, a wash of watercolour). [rings] are the widths of the layers (1: the width of the
/// line) with how opaque each is; [wobble] makes the edges uneven, as paint that spreads on wet paper. It paints, so it is not read
/// as handwriting.
class SoftBrush extends Brush {
  @override
  final String id;
  @override
  final String label;
  @override
  final IconData icon;
  @override
  final double widthScale;
  final List<({double width, double opacity})> rings;
  final double wobble;

  /// How grainy the spray is: the scattered specks around the line, as many for every 10 of its width at each point (0: none).
  final double speckle;

  /// For the screen: the layers drawn with a real blur instead of [rings] (width of the layer, opacity, and how blurred it is, the
  /// last two compared to the width of the line). The rings stay for the PDF export, which cannot blur.
  final List<({double width, double opacity, double blur})> blurs;

  /// How big the specks are, and how far from the line they reach, compared to the spray's own (1).
  final double speckleSize, speckleSpread;

  const SoftBrush(this.id, this.label, this.icon,
      {required this.widthScale, required this.rings, this.wobble = 0, this.speckle = 0, this.blurs = const [], this.speckleSize = 1, this.speckleSpread = 1});

  @override
  bool get writing => false;

  @override
  BrushShape? shape(DrawingStroke stroke) {
    if (stroke.points.isEmpty || rings.isEmpty) return null;
    final centre = RollerBrush._centreline(stroke.points, stroke.width);
    final seed = ParamBrush._fnv(stroke.id);
    // the unevenness runs slowly along the line (a few points are one swell), and each layer has its own
    List<double> swell(int layer) {
      final knots = <double>[for (var i = 0; i <= centre.length ~/ 8 + 1; i++) ParamBrush._noise(seed, layer * 7919 + i) - 0.5];
      return [
        for (var i = 0; i < centre.length; i++) 1 + wobble * (knots[i ~/ 8] + (knots[i ~/ 8 + 1] - knots[i ~/ 8]) * ((i % 8) / 8)),
      ];
    }

    Outline ring(int layer) {
      final w = swell(layer);
      return ribbonOutline(centre, [for (var i = 0; i < centre.length; i++) stroke.width * rings[layer].width * w[i] / 2]);
    }

    // specks of paint: a few at every point, mostly near the line and some far out, each at a place that is always the same; of
    // three sizes, the bigger the paler (a spray throws many fine drops and few coarse ones)
    Outline? specks;
    final tiers = [Path(), Path(), Path()];
    if (speckle > 0) {
      specks = Outline();
      final perPoint = (speckle * stroke.width / 10).ceil().clamp(1, 12);
      final stride = math.max(1, centre.length * perPoint ~/ 30000);
      for (var i = 0; i < centre.length; i += stride) {
        final dir = i + 1 < centre.length ? centre[i + 1] - centre[i] : centre[i] - centre[i - 1 < 0 ? 0 : i - 1];
        final len = dir.distance;
        if (len < 1e-6) continue;
        final u = dir / len;
        for (var j = 0; j < perPoint; j++) {
          final k = 100000 + i * 16 + j;
          // three numbers added make the middle likelier than the edges
          final across = (ParamBrush._noise(seed, k) + ParamBrush._noise(seed, k + 5000000) + ParamBrush._noise(seed, k + 7000000) - 1.5) * stroke.width * 0.5 * speckleSpread;
          final along = (ParamBrush._noise(seed, k + 9000000) - 0.5) * 3;
          final at = centre[i] + u * along + Offset(-u.dy, u.dx) * across;
          final pick = ParamBrush._noise(seed, k + 11000000);
          final tier = pick < 0.6 ? 0 : (pick < 0.9 ? 1 : 2);
          final radius = const [0.3, 0.5, 0.8][tier] * (0.8 + ParamBrush._noise(seed, k + 13000000) * 0.4) * speckleSize;
          final dot = Rect.fromCircle(center: at, radius: radius);
          tiers[tier].addOval(dot);
          specks.addOval(dot);
        }
      }
    }

    SoftLayers? soft;
    if (blurs.isNotEmpty) {
      soft = SoftLayers(
        blurred: [
          for (var i = 0; i < blurs.length; i++)
            (path: ribbonOutline(centre, List.filled(centre.length, stroke.width * blurs[i].width / 2)).path, opacity: blurs[i].opacity, blur: stroke.width * blurs[i].blur),
        ],
        crisp: [if (speckle > 0) for (final (i, o) in const [0.45, 0.35, 0.25].indexed) (path: tiers[i], opacity: o)],
      );
    }

    return BrushShape(ring(0), filled: true, opacity: rings.first.opacity, soft: soft, layers: [
      for (var i = 1; i < rings.length; i++)
          BrushLayer ( ring(i), rings[i].opacity),
      if (specks != null) BrushLayer ( specks, 0.45),
    ]);
  }
}

/// Charcoal: the dark streaks that the grain of the paper makes along the way (lanes in lengths of their own, some missing, in three
/// darknesses), a very faint body under them (the line of [ParamBrush]) and the specks of dust that crumble off to the sides. The
/// streaks and the dust grow with the width, so a wide line is a smudge of grain, not a smooth stripe.
class CharcoalBrush extends Brush {
  @override
  final String id;
  @override
  final String label;
  @override
  final IconData icon;
  final ParamBrush body;

  /// How much of the paper shows through the streaks: the part of the runs that are left out (0: none).
  final double dryness;

  /// How much dust crumbles off to the sides (1: as the charcoal of the app does; 0: none).
  final double dust;

  /// How coarse the grain is (the width of a streak), how long the runs of a streak are, how far the dust reaches and how big its
  /// specks are, each compared to the charcoal's own (1).
  final double grainSize, runLength, dustSpread, dustSize;

  const CharcoalBrush(this.id, this.label, this.icon, this.body,
      {this.dryness = 0.3, this.dust = 1, this.grainSize = 1, this.runLength = 1, this.dustSpread = 1, this.dustSize = 1});

  @override
  bool operator ==(Object other) =>
      other is CharcoalBrush &&
      other.id == id &&
      other.label == label &&
      other.body == body &&
      other.dryness == dryness &&
      other.dust == dust &&
      other.grainSize == grainSize &&
      other.runLength == runLength &&
      other.dustSpread == dustSpread &&
      other.dustSize == dustSize;

  @override
  int get hashCode => Object.hash(id, label, body, dryness, dust, grainSize, runLength, dustSpread, dustSize);

  @override
  double get widthScale => body.widthScale;

  @override
  bool get usesPressure => body.usesPressure;

  @override
  BrushShape? shape(DrawingStroke stroke) {
    final base = body.shape(stroke);
    if (base == null || stroke.points.length < 2) return base;
    final centre = RollerBrush._centreline(stroke.points, stroke.width);
    final n = centre.length;
    if (n < 2) return base;
    final seed = ParamBrush._fnv(stroke.id);
    final w = stroke.width;
    final normal = <Offset>[
      for (var i = 0; i < n; i++)
        () {
          final d = centre[math.min(i + 1, n - 1)] - centre[math.max(i - 1, 0)];
          final l = d.distance;
          return l < 1e-6 ? Offset.zero : Offset(-d.dy / l, d.dx / l);
        }(),
    ];

    // streaks: each lane runs for a while, stops, and starts again
    final lanes = (w / (1.4 * grainSize)).round().clamp(4, 28);
    final laneWidth = w * 1.0 / lanes;
    final levels = [Outline(), Outline(), Outline()];
    for (var l = 0; l < lanes; l++) {
      final offset = ((l + 0.5) / lanes - 0.5) * w * 1.0;
      var i = 0;
      var k = 0;
      while (i < n - 1) {
        final usual = 3 + (ParamBrush._noise(seed, l * 104729 + k * 2 + 1) * 26).floor();
        final run = runLength == 1 ? usual : (usual * runLength).round().clamp(2, 100000);
        final on = ParamBrush._noise(seed, l * 104729 + k * 2) > dryness;
        final end = math.min(i + run, n - 1);
        if (on && end > i) {
          final pts = [for (var j = i; j <= end; j++) centre[j] + normal[j] * offset];
          final thin = laneWidth * (0.7 + ParamBrush._noise(seed, l * 7 + k + 555) * 0.6) / 2;
          final level = (ParamBrush._noise(seed, l * 31 + k * 3 + 77) * 3).floor().clamp(0, 2);
          levels[level].addRibbon(pts, List.filled(pts.length, thin));
        }
        i = end;
        k++;
      }
    }

    // dust: more of it near the line than far from it
    final specks = Outline();
    final perPoint = dust <= 0 ? 0 : (w / 3 * dust).ceil().clamp(1, 14);
    final stride = math.max(1, n * math.max(1, perPoint) ~/ 30000);
    for (var i = 0; i < n; i += stride) {
      for (var j = 0; j < perPoint; j++) {
        final k = 200000 + i * 16 + j;
        final across = (ParamBrush._noise(seed, k) + ParamBrush._noise(seed, k + 5000000) - 1) * w * 0.8 * dustSpread;
        final along = (ParamBrush._noise(seed, k + 9000000) - 0.5) * 3;
        final tangent = Offset(normal[i].dy, -normal[i].dx);
        final at = centre[i] + tangent * along + normal[i] * across;
        specks.addOval(Rect.fromCircle(center: at, radius: (0.4 + ParamBrush._noise(seed, k + 13000000) * 0.9) * dustSize));
      }
    }

    // (for the screen the body and the streaks are drawn through the grain of paper, so they are bolder: the grain takes about half)
    final grained = Path()..addPath(base.path, Offset.zero);
    return BrushShape(base.outline, filled: true, opacity: base.opacity, soft: SoftLayers(
      grain: [
        (path: grained, opacity: 0.22),
        for (var i = 0; i < levels.length; i++) (path: levels[i].path, opacity: const [0.5, 0.78, 1.0][i]),
      ],
      crisp: [(path: specks.path, opacity: 0.55)],
    ), layers: [
      ...base.layers,
      for (var i = 0; i < levels.length; i++)
          BrushLayer ( levels[i], const [0.3, 0.55, 0.85][i]),
        BrushLayer
      ( specks, 0.55),
    ]);
  }
}

/// The shape of one dab of a [StampBrush].
enum StampShape { round, square, triangle, star, leaf }

/// The numbers that make a [StampBrush].
class StampParams {
  /// How far apart the dabs are, in dab widths.
  final double spacing;

  /// How far dabs stray from the line, across it, in dab widths (0: on the line).
  final double scatter;

  /// How much the size of the dabs varies, and how much it follows the pressure (0: not at all).
  final double sizeJitter, pressure;
  final StampShape shape;

  /// How flat a dab is (1: as wide as thick), the angle it is turned to in degrees, how much that varies (1: any angle), and
  /// whether it turns to follow the line (then [angle] is added to the direction of the line).
  final double squash, angle, angleJitter;
  final bool follow;
  final double opacity;

  /// How much the colour varies from dab to dab (see [BrushParams.lightness], [BrushParams.hue]).
  final double lightness, hue;
  final bool multiply;

  /// How the colour changes along the line (only the gradient, the rainbow and the fade count) and what is drawn behind the dabs
  /// (a shadow, a glow, an outline).
  final ColourFlow flow;
  final LineEffects effects;

  const StampParams({
    this.spacing = 0.35,
    this.scatter = 0,
    this.sizeJitter = 0.2,
    this.pressure = 0.5,
    this.shape = StampShape.round,
    this.squash = 1,
    this.angle = 0,
    this.angleJitter = 0,
    this.follow = false,
    this.opacity = 1,
    this.lightness = 0,
    this.hue = 0,
    this.multiply = false,
    this.flow = ColourFlow.none,
    this.effects = LineEffects.none,
  });

  @override
  bool operator ==(Object other) =>
      other is StampParams &&
      other.spacing == spacing &&
      other.scatter == scatter &&
      other.sizeJitter == sizeJitter &&
      other.pressure == pressure &&
      other.shape == shape &&
      other.squash == squash &&
      other.angle == angle &&
      other.angleJitter == angleJitter &&
      other.follow == follow &&
      other.opacity == opacity &&
      other.lightness == lightness &&
      other.hue == hue &&
      other.multiply == multiply &&
      other.flow == flow &&
      other.effects == effects;

  @override
  int get hashCode => Object.hash(spacing, scatter, sizeJitter, pressure, shape, squash, angle, angleJitter, follow, opacity, lightness, hue, multiply, flow, effects);
}

/// A brush that stamps the same small shape again and again along the line (dots, squares, stars, leaves), each a little different
/// if it is asked to be: the size, the place, the angle and the colour can vary. It paints, so it is not read as handwriting.
class StampBrush extends Brush {
  @override
  final String id;
  @override
  final String label;
  @override
  final IconData icon;
  @override
  final double widthScale;
  final StampParams params;

  const StampBrush(this.id, this.label, {this.icon = Icons.bubble_chart_outlined, this.widthScale = 4, this.params = const StampParams()});

  @override
  bool get writing => false;

  @override
  bool get usesPressure => params.pressure > 0;

  @override
  bool operator ==(Object other) => other is StampBrush && other.id == id && other.label == label && other.widthScale == widthScale && other.params == params;

  @override
  int get hashCode => Object.hash(id, label, widthScale, params);

  /// The most dabs a line gets (a very long line gets them further apart).
  static const _mostDabs = 4000;

  /// The corners of a dab of [shape] one unit across (-0.5 to 0.5), going round the way ovals do on the screen.
  static List<Offset> _corners(StampShape shape) {
    switch (shape) {
      case StampShape.round:
        return [for (var i = 0; i < 16; i++) Offset(math.cos(i * math.pi / 8) / 2, math.sin(i * math.pi / 8) / 2)];
      case StampShape.square:
        return const [Offset(-0.5, -0.5), Offset(0.5, -0.5), Offset(0.5, 0.5), Offset(-0.5, 0.5)];
      case StampShape.triangle:
        return [for (var i = 0; i < 3; i++) Offset(math.cos(-math.pi / 2 + i * 2 * math.pi / 3) / 2, math.sin(-math.pi / 2 + i * 2 * math.pi / 3) / 2)];
      case StampShape.star:
        return [
          for (var i = 0; i < 10; i++)
            Offset(math.cos(-math.pi / 2 + i * math.pi / 5) * (i.isEven ? 0.5 : 0.2), math.sin(-math.pi / 2 + i * math.pi / 5) * (i.isEven ? 0.5 : 0.2)),
        ];
      case StampShape.leaf:
        const radii = [0.5, 0.36, 0.17, 0.36, 0.5, 0.36, 0.17, 0.36];
        return [for (var i = 0; i < 8; i++) Offset(math.cos(i * math.pi / 4) * radii[i], math.sin(i * math.pi / 4) * radii[i])];
    }
  }

  @override
  BrushShape? shape(DrawingStroke stroke) {
    final pts = stroke.points;
    if (pts.isEmpty) return null;
    final given = stroke.pressures;
    final pressure = params.pressure > 0 && given != null && given.length == pts.length ? [for (final v in given) v / 255] : null;
    final seed = ParamBrush._fnv(stroke.id);
    final size = stroke.width;
    final corners = _corners(params.shape);
    final randomTint = params.lightness > 0 || params.hue > 0;
    final flow = params.flow;

    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += (pts[i] - pts[i - 1]).distance;
    }
    final step = math.max(math.max(0.3, params.spacing * size), total / _mostDabs);

    // every dab: where it is, how big, how it is turned, how far along the line, and which of five colours near the line's it is
    final dabs = <({Offset centre, double d, double cos, double sin, double along, int bucket})>[];
    void stamp(Offset at, Offset direction, double pressureHere, double along) {
      final k = dabs.length;
      var d = size * (1 - params.sizeJitter * ParamBrush._noise(seed, k * 7 + 1) * 0.8);
      if (pressure != null) d *= 1 - params.pressure + params.pressure * (0.3 + 1.4 * pressureHere);
      if (d < 0.2) d = 0.2;
      final length = direction.distance;
      final normal = length < 1e-9 ? Offset.zero : Offset(-direction.dy / length, direction.dx / length);
      final centre = at + normal * ((ParamBrush._noise(seed, k * 7 + 2) - 0.5) * 2 * params.scatter * size);
      var turn = params.angle * math.pi / 180 + (ParamBrush._noise(seed, k * 7 + 3) - 0.5) * 2 * params.angleJitter * math.pi;
      if (params.follow && length >= 1e-9) turn += math.atan2(direction.dy, direction.dx);
      final bucket = randomTint ? (ParamBrush._noise(seed, k * 7 + 4) * 5).floor().clamp(0, 4) : 2;
      dabs.add((centre: centre, d: d, cos: math.cos(turn), sin: math.sin(turn), along: along, bucket: bucket));
    }

    if (pts.length == 1 || total <= 0) {
      stamp(pts.first, Offset.zero, pressure?.first ?? 1, 0);
    } else {
      var carried = 0.0, walked = 0.0;
      stamp(pts.first, pts[1] - pts[0], pressure?.first ?? 1, 0);
      for (var i = 1; i < pts.length; i++) {
        final a = pts[i - 1], b = pts[i];
        final seg = (b - a).distance;
        if (seg <= 0) continue;
        var at = step - carried;
        while (at <= seg) {
          final t = at / seg;
          stamp(Offset.lerp(a, b, t)!, b - a, pressure == null ? 1 : pressure[i - 1] + (pressure[i] - pressure[i - 1]) * t, walked + at);
          at += step;
        }
        carried = seg - (at - step);
        walked += seg;
      }
    }

    // (a dab made [grow] bigger on every side and moved by [shift])
    Outline dabOutline(({Offset centre, double d, double cos, double sin, double along, int bucket}) dab, [double grow = 0, Offset shift = Offset.zero]) {
      final out = Outline();
      final d = dab.d + grow * 2, centre = dab.centre + shift;
      if (params.shape == StampShape.round && params.squash == 1) {
        out.addOval(Rect.fromCircle(center: centre, radius: d / 2));
      } else {
        out.addPolygon([
          for (final p in corners)
            () {
              final x = p.dx * d, y = p.dy * d * params.squash;
              return centre + Offset(x * dab.cos - y * dab.sin, x * dab.sin + y * dab.cos);
            }(),
        ]);
      }
      return out;
    }

    Outline all([double grow = 0, Offset shift = Offset.zero]) {
      final out = Outline();
      for (final dab in dabs) {
        out.addOutline(dabOutline(dab, grow, shift));
      }
      return out;
    }

    final fx = params.effects;
    final under = fx.hasBehind ? behindLayers(fx, size, all) : const <BrushLayer>[];

    if (!randomTint && !flow.active) return BrushShape(all(), filled: true, opacity: params.opacity, multiply: params.multiply, under: under);

    final groups = <(double, double, double), Outline>{};
    for (final dab in dabs) {
      var l = (dab.bucket - 2) / 2 * params.lightness * 0.3, h = (dab.bucket - 2) / 2 * params.hue, o = 1.0;
      if (flow.active) {
        final t = total <= 0 ? 0.0 : (dab.along / total).clamp(0.0, 1.0);
        if (flow.gradientHue != 0 || flow.gradientLight != 0) {
          final q = (t * 8).floor().clamp(0, 7) / 7;
          h += flow.gradientHue * q;
          l += flow.gradientLight * q;
        }
        if (flow.rainbow > 0) h += (((dab.along / (flow.rainbow * size)) % 1.0) * 12).floor() * 30.0;
        if (flow.fade != 0) {
          final q = (t * 6).floor().clamp(0, 5) / 5;
          o *= flow.fade > 0 ? 1 - flow.fade * q : 1 + flow.fade * (1 - q);
        }
        l = (l * 1000).round() / 1000;
        h = (h * 1000).round() / 1000;
        o = (o.clamp(0.05, 1.0) * 1000).round() / 1000;
      }
      (groups[(l, h, o)] ??= Outline()).addOutline(dabOutline(dab));
    }
    final vivid = flow.turnsHue;
    Outline? base;
    final layers = <BrushLayer>[];
    for (final key in ParamBrush._fewShades(groups)) {
      final (l, h, o) = key;
      if (!vivid && l == 0 && h == 0 && o == 1) {
        base = groups[key];
      } else {
        layers.add(BrushLayer(groups[key]!, params.opacity * o, lightness: l, hue: h, vivid: vivid));
      }
    }
    return BrushShape(base ?? Outline(), filled: true, opacity: params.opacity, multiply: params.multiply, layers: layers, under: under);
  }
}

/// Two brushes drawn on the same line, one over the other: an ink with a charcoal edge, a marker with a stamp of stars along it. The
/// first sets the width in the drawing bar; the second is made [sizeB] times as thick as it would be on its own.
class MixBrush extends Brush {
  @override
  final String id;
  @override
  final String label;
  @override
  final IconData icon;
  final Brush a, b;
  final double sizeB;

  /// Whether the second is drawn under the first (else over it).
  final bool underneath;

  const MixBrush(this.id, this.label, this.a, this.b, {this.icon = Icons.layers_outlined, this.sizeB = 1, this.underneath = false});

  @override
  double get widthScale => a.widthScale;

  @override
  bool get usesPressure => a.usesPressure || b.usesPressure;

  @override
  bool get writing => a.writing && b.writing;

  @override
  bool operator ==(Object other) => other is MixBrush && other.id == id && other.label == label && other.a == a && other.b == b && other.sizeB == sizeB && other.underneath == underneath;

  @override
  int get hashCode => Object.hash(id, label, a, b, sizeB, underneath);

  @override
  BrushShape? shape(DrawingStroke stroke) {
    final first = a.shape(stroke);
    // (the second part draws a line of its own: the same points, as thick as that brush makes it)
    final line = DrawingStroke(
      id: '${stroke.id}#b',
      color: stroke.color,
      width: stroke.width * b.widthScale / a.widthScale * sizeB,
      points: stroke.points,
      pressures: stroke.pressures,
    );
    final second = b.shape(line)?.forLine(line);
    if (first == null || second == null) return first ?? second;
    return underneath ? second.withNext(first) : first.withNext(second);
  }
}

/// A line of [pts] that is [half] thick (half of it) at each point, as a filled shape (see [OutlineRibbon]).
Outline ribbonOutline(List<Offset> pts, List<double> half) =>
    Outline.ribbon(pts, half);

/// The brushes there are, by id.
class Brushes {
  Brushes._();

  static const pen = PenBrush();
  static const roller = RollerBrush();

  /// Graphite on paper: a little grain at the edges, thicker where the pencil presses, never quite black.
  static const pencil = ParamBrush('pencil', 'Pencil', BrushParams(pressure: 0.5, smoothing: 0.3, jitter: 0.55, opacity: 0.82, taper: 0.15), icon: Icons.create_outlined);

  /// A fountain pen: smooth, thick where it presses, running out to a point at both ends.
  static const fountain = ParamBrush('fountain', 'Fountain pen', BrushParams(width: 1.2, pressure: 0.9, smoothing: 0.9, taper: 0.7), icon: Icons.history_edu_outlined);

  /// A broad nib held at an angle: thick across it, thin along it.
  static const calligraphy = ParamBrush('calligraphy', 'Calligraphy', BrushParams(width: 2.5, smoothing: 0.7, nibAngle: 40, nibFlatness: 0.16), icon: Icons.draw_outlined);

  /// A felt marker: an even, thick line that is a little see-through.
  static const marker = ParamBrush('marker', 'Marker', BrushParams(width: 3, smoothing: 0.6, opacity: 0.85), icon: Icons.brush);

  /// Charcoal: rough, dark where it presses and crumbling at the ends.
  static const charcoal = CharcoalBrush('charcoal', 'Charcoal', Icons.gradient,
      ParamBrush('charcoal', 'Charcoal', BrushParams(width: 3, pressure: 0.7, smoothing: 0.2, jitter: 0.12, opacity: 0.1, taper: 0.35)));

  /// A spray: twenty thin layers whose opacity follows a bell curve, so the line fades smoothly from a dense core to nothing at the
  /// edges, with no visible bands.
  static const airbrush = SoftBrush('airbrush', 'Airbrush', Icons.blur_on, widthScale: 6, speckle: 5, blurs: [(width: 0.5, opacity: 0.55, blur: 0.17), (width: 0.22, opacity: 0.5, blur: 0.1)], rings: [
    (width: 1.00, opacity: 0.029), (width: 0.95, opacity: 0.012), (width: 0.90, opacity: 0.015), (width: 0.85, opacity: 0.020),
    (width: 0.80, opacity: 0.026), (width: 0.75, opacity: 0.033), (width: 0.70, opacity: 0.040), (width: 0.65, opacity: 0.050),
    (width: 0.60, opacity: 0.060), (width: 0.55, opacity: 0.071), (width: 0.50, opacity: 0.084), (width: 0.45, opacity: 0.097),
    (width: 0.40, opacity: 0.111), (width: 0.35, opacity: 0.125), (width: 0.30, opacity: 0.137), (width: 0.25, opacity: 0.145),
    (width: 0.20, opacity: 0.147), (width: 0.15, opacity: 0.138), (width: 0.10, opacity: 0.111), (width: 0.05, opacity: 0.064),
  ]);

  /// A wash of watercolour: pale and wide, with edges that spread unevenly.
  static const watercolour = SoftBrush('watercolour', 'Watercolour', Icons.water_drop_outlined,
      widthScale: 4, wobble: 0.45, rings: [(width: 1, opacity: 0.16), (width: 0.82, opacity: 0.12), (width: 0.55, opacity: 0.1)]);

  /// The brushes the tool "More brushes" adds (the pen and the roller are always there).
  static const creative = <Brush>[pencil, fountain, calligraphy, marker, charcoal, airbrush, watercolour];

  static const _builtIns = <Brush>[pen, roller, ...creative];
  static final Map<String, Brush> _all = {for (final b in _builtIns) b.id: b};
  static final Set<String> _builtIn = {for (final b in _builtIns) b.id};

  /// Whether lines drawn with the brush called [id] are writing, to be read as handwriting or maths (a line of a brush that is not
  /// here is drawn as the pen draws it, so it is).
  static bool writes(String id) => _all[id]?.writing ?? true;

  /// Counts the changes of the brushes there are: lines drawn with a brush that came or went look different, so what was drawn
  /// of them has to be drawn again, and the drawing bar has a different list.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static int get revision => changes.value;

  /// The ids of brushes that are here for the lines drawn with them but are not in the brush menu (a brush that came with a note
  /// and was not kept).
  static Set<String> _unlisted = {};

  /// The ids of the brushes that are not in the brush menu.
  static Set<String> get unlisted => Set.unmodifiable(_unlisted);

  /// Whether the brush called [id] is in the brush menu.
  static bool isListed(String id) => !_unlisted.contains(id);

  /// Makes [ids] the brushes that are not in the menu (and counts it as a change if that is not what it was).
  static void setUnlisted(Set<String> ids) {
    if (_unlisted.length == ids.length && _unlisted.containsAll(ids)) return;
    _unlisted = Set.of(ids);
    changes.value++;
  }

  /// The brush called [id]; null if there is none (a brush that is not here), when a line is drawn as the pen draws it.
  static Brush? byId(String id) => _all[id];

  /// Adds a brush, or replaces the one with its id.
  static void register(Brush brush) {
    if (_all[brush.id] == brush) return;
    _all[brush.id] = brush;
    changes.value++;
  }

  static void unregister(String id) {
    if (!_builtIn.contains(id) && _all.remove(id) != null) changes.value++;
  }

  /// Makes the brushes whose id starts with [prefix] be [brushes] and no others (what an extension that is switched on has).
  static void sync(String prefix, Iterable<Brush> brushes) {
    final keep = {for (final b in brushes) b.id};
    for (final id in _all.keys.where((k) => k.startsWith(prefix) && !keep.contains(k)).toList()) {
      unregister(id);
    }
    brushes.forEach(register);
  }

  static List<Brush> get all => List.unmodifiable(_all.values);
}
