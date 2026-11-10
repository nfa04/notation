import 'package:flutter/foundation.dart' show listEquals;

/// How the colour of a line changes along it, on top of the colour the person picked: every number is a change from that colour, so
/// the brush never decides the colour (see [ParamBrush]). All off by default.
class ColourFlow {
  /// How many degrees round the colour wheel the colour has turned at the end of the line, and how much lighter (positive) or darker
  /// (negative) it has become, as a part of the whole range.
  final double gradientHue, gradientLight;

  /// How long one turn round the whole colour wheel is, in widths of the line (0: no rainbow).
  final double rainbow;

  /// How the line fades: positive, it is see-through towards the end by this much; negative, it comes out of nothing at the start.
  final double fade;

  /// How much lighter or darker the line is where the pen pressed hard, and where it moved fast (negative: darker there).
  final double pressureShade, speedShade;

  const ColourFlow({this.gradientHue = 0, this.gradientLight = 0, this.rainbow = 0, this.fade = 0, this.pressureShade = 0, this.speedShade = 0});

  static const none = ColourFlow();

  /// Whether the colour changes along the line at all.
  bool get active => gradientHue != 0 || gradientLight != 0 || rainbow > 0 || fade != 0 || pressureShade != 0 || speedShade != 0;

  /// Whether the colours are to be seen on a pen that is black or grey (which has no hue to turn).
  bool get turnsHue => gradientHue != 0 || rainbow > 0;

  @override
  bool operator ==(Object other) =>
      other is ColourFlow &&
      other.gradientHue == gradientHue &&
      other.gradientLight == gradientLight &&
      other.rainbow == rainbow &&
      other.fade == fade &&
      other.pressureShade == pressureShade &&
      other.speedShade == speedShade;

  @override
  int get hashCode => Object.hash(gradientHue, gradientLight, rainbow, fade, pressureShade, speedShade);
}

/// What is drawn round and behind a line, and how it is broken up: dashes and dots, a glow, a shadow and an outline. All off by default.
class LineEffects {
  /// How long a dash looks, in widths of the line, caps included (0: a solid line; up to 1: a dot), and how long the gap is.
  final double dash, dashGap;

  /// How dark the shadow is (0: none), how far it falls to the lower right in widths, and how blurred it is (0: sharp).
  final double shadow, shadowDistance, shadowBlur;

  /// How far a glow reaches round the line in widths (0: none) and how many degrees round the colour wheel its colour is turned.
  final double glow, glowHue;

  /// How thick the border round the line is, as a part of its width (0: none), and what colour it is: 0 dark, 1 light, 2 the opposite
  /// on the colour wheel.
  final double outline, outlineTone;

  const LineEffects({
    this.dash = 0,
    this.dashGap = 1.5,
    this.shadow = 0,
    this.shadowDistance = 0.8,
    this.shadowBlur = 0,
    this.glow = 0,
    this.glowHue = 0,
    this.outline = 0,
    this.outlineTone = 0,
  });

  static const none = LineEffects();

  /// Whether anything is drawn behind the line.
  bool get hasBehind => shadow > 0 || glow > 0 || outline > 0;

  @override
  bool operator ==(Object other) =>
      other is LineEffects &&
      other.dash == dash &&
      other.dashGap == dashGap &&
      other.shadow == shadow &&
      other.shadowDistance == shadowDistance &&
      other.shadowBlur == shadowBlur &&
      other.glow == glow &&
      other.glowHue == glowHue &&
      other.outline == outline &&
      other.outlineTone == outlineTone;

  @override
  int get hashCode => Object.hash(dash, dashGap, shadow, shadowDistance, shadowBlur, glow, glowHue, outline, outlineTone);
}

/// A curve through points that are evenly spaced from 0 to 1 on the way in (the pressure of a pen, the speed of a hand), each point
/// the value that comes out there (a thickness compared to the set width); between two points it runs straight.
double curveValue(List<double> points, double x) {
  if (points.length == 1) return points.first;
  final at = x.clamp(0.0, 1.0) * (points.length - 1);
  final i = at.floor().clamp(0, points.length - 2);
  return points[i] + (points[i + 1] - points[i]) * (at - i);
}

/// Whether two curves are the same (null: no curve).
bool sameCurve(List<double>? a, List<double>? b) => a == null || b == null ? a == b : listEquals(a, b);
