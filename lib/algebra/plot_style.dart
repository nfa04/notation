import 'dart:ui' show Color;

/// Which grid lines are drawn behind the curve.
enum PlotGrid { none, major, fine }

/// How many numbers and grid lines the axes carry.
enum PlotDensity {
  sparse(0.65),
  normal(1),
  dense(1.6);

  /// Times the usual number of steps along an axis.
  final double factor;
  const PlotDensity(this.factor);
}

/// Where the axes are drawn.
enum PlotAxes { cross, edges, hidden }

enum PlotLine { solid, dashed, dotted }

/// The paper of the plot and the colours that go with it.
enum PlotBackground {
  white(color: Color(0xFFFFFFFF), ink: Color(0xFF1A1A1A), grid: Color(0xFFE0E0E0), label: Color(0xFF555555), border: Color(0xFFBDBDBD)),
  paper(color: Color(0xFFFBF5E4), ink: Color(0xFF2A2418), grid: Color(0xFFE6DDC4), label: Color(0xFF6B6250), border: Color(0xFFCFC4A4)),
  grey(color: Color(0xFFEEEEEE), ink: Color(0xFF1A1A1A), grid: Color(0xFFD2D2D2), label: Color(0xFF555555), border: Color(0xFFBDBDBD)),
  dark(color: Color(0xFF20242B), ink: Color(0xFFE8EAED), grid: Color(0xFF3A404A), label: Color(0xFFA8AEB8), border: Color(0xFF5A616C)),

  /// Nothing behind the plot, so the page shows through the picture.
  transparent(color: Color(0x00FFFFFF), ink: Color(0xFF1A1A1A), grid: Color(0xFFD0D0D0), label: Color(0xFF555555), border: Color(0xFFBDBDBD));

  final Color color, ink, grid, label, border;
  const PlotBackground({required this.color, required this.ink, required this.grid, required this.label, required this.border});

  bool get isTransparent => color.a == 0;
}

/// The colours offered for a curve.
const plotCurveColors = [
  Color(0xFF1565C0),
  Color(0xFFC62828),
  Color(0xFF2E7D32),
  Color(0xFFEF6C00),
  Color(0xFF6A1B9A),
  Color(0xFF00838F),
  Color(0xFFAD1457),
  Color(0xFF1A1A1A),
];

/// How a plot looks: everything about the display that is not the formula or the part of the
/// plane. The default is the plain look the plots always had.
class PlotStyle {
  // the curve
  final Color curve;
  final double lineWidth;
  final PlotLine line;
  final bool fillUnder, derivative;
  final bool zeros, intercept, extrema, markLabels;

  // grid and axes
  final PlotGrid grid;
  final PlotDensity density;
  final PlotAxes axes;
  final bool numbers, ticks, names, arrows, piLabels;
  final double labelScale;

  // the page
  final PlotBackground background;
  final bool border;
  final String title;

  const PlotStyle({
    this.curve = const Color(0xFF1565C0),
    this.lineWidth = 2.2,
    this.line = PlotLine.solid,
    this.fillUnder = false,
    this.derivative = false,
    this.zeros = false,
    this.intercept = false,
    this.extrema = false,
    this.markLabels = true,
    this.grid = PlotGrid.major,
    this.density = PlotDensity.normal,
    this.axes = PlotAxes.cross,
    this.numbers = true,
    this.ticks = false,
    this.names = true,
    this.arrows = false,
    this.piLabels = false,
    this.labelScale = 1,
    this.background = PlotBackground.white,
    this.border = true,
    this.title = '',
  });

  bool get hasMarks => zeros || intercept || extrema;

  PlotStyle copyWith({
    Color? curve,
    double? lineWidth,
    PlotLine? line,
    bool? fillUnder,
    bool? derivative,
    bool? zeros,
    bool? intercept,
    bool? extrema,
    bool? markLabels,
    PlotGrid? grid,
    PlotDensity? density,
    PlotAxes? axes,
    bool? numbers,
    bool? ticks,
    bool? names,
    bool? arrows,
    bool? piLabels,
    double? labelScale,
    PlotBackground? background,
    bool? border,
    String? title,
  }) =>
      PlotStyle(
        curve: curve ?? this.curve,
        lineWidth: lineWidth ?? this.lineWidth,
        line: line ?? this.line,
        fillUnder: fillUnder ?? this.fillUnder,
        derivative: derivative ?? this.derivative,
        zeros: zeros ?? this.zeros,
        intercept: intercept ?? this.intercept,
        extrema: extrema ?? this.extrema,
        markLabels: markLabels ?? this.markLabels,
        grid: grid ?? this.grid,
        density: density ?? this.density,
        axes: axes ?? this.axes,
        numbers: numbers ?? this.numbers,
        ticks: ticks ?? this.ticks,
        names: names ?? this.names,
        arrows: arrows ?? this.arrows,
        piLabels: piLabels ?? this.piLabels,
        labelScale: labelScale ?? this.labelScale,
        background: background ?? this.background,
        border: border ?? this.border,
        title: title ?? this.title,
      );

  List<Object> get _fields => [
        curve, lineWidth, line, fillUnder, derivative, zeros, intercept, extrema, markLabels, //
        grid, density, axes, numbers, ticks, names, arrows, piLabels, labelScale, background, border, title,
      ];

  @override
  bool operator ==(Object other) {
    if (other is! PlotStyle) return false;
    final a = _fields, b = other._fields;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_fields);
}
