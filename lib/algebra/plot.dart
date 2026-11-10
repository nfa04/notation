import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'expr.dart';
import 'latex_parser.dart';

/// What to draw: either `y = f(x)` ([explicit]) or `f(x, y) = 0` ([implicit]).
class PlotSpec {
  final String xName, yName;
  final Expr? explicit;
  final Expr? implicit;

  /// The formula as the user wrote it, for the caption.
  final String latex;

  const PlotSpec({required this.xName, required this.yName, this.explicit, this.implicit, required this.latex});

  /// Axes and grid only, with nothing drawn: a plot to draw into by hand.
  const PlotSpec.blank({this.xName = 'x', this.yName = 'y'})
      : explicit = null,
        implicit = null,
        latex = '';

  bool get isBlank => explicit == null && implicit == null;

  bool get isImplicit => implicit != null;

  double? valueAt(double x) => explicit == null ? null : evaluate(explicit!, {xName: x});
  double valueAt2(double x, double y) => evaluate(implicit!, {xName: x, yName: y});
}

final _functionNotation = RegExp(r'^\s*[a-zA-Z](?:_\{?\w+\}?)?\s*\(\s*([a-zA-Z])\s*\)\s*$');

/// How [source] can be drawn, or null when it cannot (no letters, more than two
/// letters, something the parser does not read).
PlotSpec? planPlot(String source) {
  try {
    final clean = cleanLatex(source);
    if (looksLikeEquation(clean)) {
      final at = clean.indexOf('=');
      final leftSource = clean.substring(0, at);
      final (l, r) = parseEquation(clean);
      final fx = _functionNotation.firstMatch(leftSource);
      if (fx != null) {
        final x = fx.group(1)!;
        final others = freeVariables(r).where((v) => v != x);
        return others.isEmpty
            ? PlotSpec(xName: x, yName: 'y', explicit: r, latex: clean)
            : null;
      }
      PlotSpec? lone(Expr side, Expr other) {
        if (side is! Sym || side.constant || contains(other, side.name)) return null;
        final vars = freeVariables(other);
        if (vars.length > 1) return null;
        return PlotSpec(xName: vars.isEmpty ? (side.name == 'x' ? 't' : 'x') : vars.first, yName: side.name, explicit: other, latex: clean);
      }

      final explicit = lone(l, r) ?? lone(r, l);
      if (explicit != null) return explicit;
      final vars = freeVariables(sub(l, r));
      if (vars.length != 2) return null;
      final x = vars.contains('x') ? 'x' : vars.first;
      final y = vars.firstWhere((v) => v != x);
      return PlotSpec(xName: x, yName: y, implicit: sub(l, r), latex: clean);
    }
    final e = parseExpression(clean);
    final vars = freeVariables(e);
    if (vars.length != 1) return null;
    return PlotSpec(xName: vars.first, yName: 'y', explicit: e, latex: 'y = $clean');
  } on ParseException {
    return null;
  }
}

bool canPlot(String source) => planPlot(source) != null;

/// The part of the plane on screen.
class PlotRange {
  final double xmin, xmax, ymin, ymax;
  const PlotRange(this.xmin, this.xmax, this.ymin, this.ymax);

  double get width => xmax - xmin;
  double get height => ymax - ymin;
  Offset get center => Offset((xmin + xmax) / 2, (ymin + ymax) / 2);

  /// Zoomed by [factor] (> 1 = closer) around the point (px, py) of the plane. A zoom that would take the view further in than
  /// the numbers can tell apart, or further out than they reach, leaves it as it is.
  PlotRange zoomed(double factor, double px, double py) {
    final z = PlotRange(
      px - (px - xmin) / factor,
      px + (xmax - px) / factor,
      py - (py - ymin) / factor,
      py + (ymax - py) / factor,
    );
    return z.usable ? z : this;
  }

  /// Whether the view can be drawn: finite, not wider than 1e306 and wider than the numbers in it can tell apart.
  bool get usable {
    bool axis(double lo, double hi) => lo.isFinite && hi.isFinite && hi - lo <= 1e306 && hi - lo > 1e-9 * math.max(1e-290, math.max(lo.abs(), hi.abs()));
    return axis(xmin, xmax) && axis(ymin, ymax);
  }

  PlotRange shifted(double dx, double dy) => PlotRange(xmin + dx, xmax + dx, ymin + dy, ymax + dy);
}

/// A first view that shows the interesting part.
PlotRange autoRange(PlotSpec spec, {double aspect = 1.5}) {
  if (spec.isImplicit) {
    for (final r in const [2.0, 5.0, 10.0, 25.0, 100.0]) {
      final range = PlotRange(-r * aspect, r * aspect, -r, r);
      final segs = implicitSegments(spec, range, columns: 60);
      if (segs.isEmpty) continue;
      // the smallest view that holds the whole curve with some room around it
      var reachX = 0.0, reachY = 0.0;
      for (final (a, b) in segs) {
        reachX = math.max(reachX, math.max(a.dx.abs(), b.dx.abs()));
        reachY = math.max(reachY, math.max(a.dy.abs(), b.dy.abs()));
      }
      if (reachX < r * aspect * 0.92 && reachY < r * 0.92 && math.max(reachX / aspect, reachY) >= r * 0.3) return range;
    }
    return PlotRange(-10 * aspect, 10 * aspect, -10, 10);
  }
  const xmin = -10.0, xmax = 10.0;
  final ys = <double>[];
  for (var i = 0; i <= 400; i++) {
    final y = spec.valueAt(xmin + (xmax - xmin) * i / 400);
    if (y != null && y.isFinite) ys.add(y);
  }
  if (ys.isEmpty) return const PlotRange(-10, 10, -7, 7);
  ys.sort();
  var lo = ys[(ys.length * 0.05).floor()], hi = ys[math.min(ys.length - 1, (ys.length * 0.95).ceil())];
  // (values beyond these cannot be told apart on a screen anyway, and the span of the view must stay a number)
  lo = math.max(math.min(lo, 0), -1e300);
  hi = math.min(math.max(hi, 0), 1e300);
  var span = hi - lo;
  if (span < 1e-9) span = 2;
  final pad = span * 0.12;
  return PlotRange(xmin, xmax, lo - pad, hi + pad);
}

/// The curve of an explicit function as polylines (broken at gaps and poles).
List<List<Offset>> explicitLines(PlotSpec spec, PlotRange range, {int samples = 700}) =>
    curveLines((x) => spec.valueAt(x)!, range, samples: samples);

/// The graph of [f] over the width of [range] as polylines (broken at gaps and poles).
List<List<Offset>> curveLines(double Function(double x) f, PlotRange range, {int samples = 700}) {
  final lines = <List<Offset>>[];
  var current = <Offset>[];
  double? prev;
  final limit = range.height * 4;
  for (var i = 0; i <= samples; i++) {
    final x = range.xmin + range.width * i / samples;
    final y = f(x);
    if (!y.isFinite || (prev != null && (y - prev).abs() > limit)) {
      if (current.length > 1) lines.add(current);
      current = [];
      prev = null;
      if (!y.isFinite) continue;
    }
    current.add(Offset(x, y));
    prev = y;
  }
  if (current.length > 1) lines.add(current);
  return lines;
}

/// The slope of an explicit function, worked out numerically (for showing f' beside f).
double Function(double x) slopeOf(PlotSpec spec) => (x) {
      final h = 1e-5 * math.max(1, x.abs());
      return (spec.valueAt(x + h)! - spec.valueAt(x - h)!) / (2 * h);
    };

enum PlotMarkKind { zero, intercept, maximum, minimum }

/// A point worth pointing out on a curve.
class PlotMark {
  final Offset at;
  final PlotMarkKind kind;
  const PlotMark(this.at, this.kind);
}

/// Where an explicit function crosses the x axis and the y axis and where it turns, inside [range].
List<PlotMark> plotMarks(PlotSpec spec, PlotRange range, {bool zeros = true, bool intercept = true, bool extrema = true, int samples = 800}) {
  if (spec.explicit == null) return const [];
  double f(double x) => spec.valueAt(x)!;
  final xs = [for (var i = 0; i <= samples; i++) range.xmin + range.width * i / samples];
  final ys = [for (final x in xs) f(x)];
  final out = <PlotMark>[];
  final tolY = range.height * 1e-3;
  bool inside(Offset p) => p.dx >= range.xmin && p.dx <= range.xmax && p.dy >= range.ymin && p.dy <= range.ymax;
  bool taken(double x, bool Function(PlotMarkKind) of) => out.any((m) => of(m.kind) && (m.at.dx - x).abs() < range.width * 0.004);
  bool isZero(PlotMarkKind k) => k == PlotMarkKind.zero;
  bool isTurn(PlotMarkKind k) => k == PlotMarkKind.maximum || k == PlotMarkKind.minimum;

  if (zeros) {
    for (var i = 0; i <= samples; i++) {
      final a = ys[i];
      double? root;
      if (a == 0) {
        root = xs[i];
      } else if (i < samples && a.isFinite && ys[i + 1].isFinite && a.sign * ys[i + 1].sign < 0) {
        var lo = xs[i], hi = xs[i + 1], flo = a;
        for (var n = 0; n < 60; n++) {
          final mid = (lo + hi) / 2, fm = f(mid);
          if (fm == 0 || fm.sign == flo.sign) {
            lo = mid;
            flo = fm;
          } else {
            hi = mid;
          }
        }
        final x = (lo + hi) / 2;
        // a pole or a jump flips the sign too, but the function does not come near zero there
        if (f(x).abs() <= tolY) root = x;
      }
      if (root != null && !taken(root, isZero)) out.add(PlotMark(Offset(root, 0), PlotMarkKind.zero));
    }
  }
  if (extrema) {
    for (var i = 1; i < samples; i++) {
      final y0 = ys[i - 1], y1 = ys[i], y2 = ys[i + 1];
      if (!(y0.isFinite && y1.isFinite && y2.isFinite)) continue;
      final isMax = y1 > y0 && y1 >= y2, isMin = y1 < y0 && y1 <= y2;
      if (!isMax && !isMin) continue;
      final sign = isMax ? 1.0 : -1.0;
      var lo = xs[i - 1], hi = xs[i + 1];
      for (var n = 0; n < 60; n++) {
        final m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
        if (sign * f(m1) < sign * f(m2)) {
          lo = m1;
        } else {
          hi = m2;
        }
      }
      final x = (lo + hi) / 2, y = f(x);
      if (!y.isFinite || !inside(Offset(x, y)) || taken(x, isTurn)) continue;
      out.add(PlotMark(Offset(x, y), isMax ? PlotMarkKind.maximum : PlotMarkKind.minimum));
      // a curve that only touches the axis has no sign change to find
      if (zeros && y.abs() < range.height * 1e-6 && !taken(x, isZero)) out.add(PlotMark(Offset(x, 0), PlotMarkKind.zero));
    }
  }
  if (intercept && range.xmin <= 0 && range.xmax >= 0) {
    final y = f(0);
    if (y.isFinite && y >= range.ymin && y <= range.ymax && !out.any((m) => (m.at - Offset(0, y)).distance < range.width * 0.004)) {
      out.add(PlotMark(Offset(0, y), PlotMarkKind.intercept));
    }
  }
  return out.length > 40 ? out.sublist(0, 40) : out;
}

/// The curve f(x, y) = 0 as short segments (marching squares).
List<(Offset, Offset)> implicitSegments(PlotSpec spec, PlotRange range, {int columns = 140}) {
  final nx = columns;
  final ny = math.max(10, (columns * range.height / range.width).round());
  final dx = range.width / nx, dy = range.height / ny;
  final values = List.generate(ny + 1, (j) => List.generate(nx + 1, (i) => spec.valueAt2(range.xmin + i * dx, range.ymin + j * dy)));
  final out = <(Offset, Offset)>[];
  for (var j = 0; j < ny; j++) {
    for (var i = 0; i < nx; i++) {
      final v00 = values[j][i], v10 = values[j][i + 1], v11 = values[j + 1][i + 1], v01 = values[j + 1][i];
      if (!(v00.isFinite && v10.isFinite && v11.isFinite && v01.isFinite)) continue;
      final x0 = range.xmin + i * dx, y0 = range.ymin + j * dy;
      double t(double a, double b) => a / (a - b);
      final points = <Offset>[];
      if ((v00 < 0) != (v10 < 0)) points.add(Offset(x0 + dx * t(v00, v10), y0)); // bottom
      if ((v10 < 0) != (v11 < 0)) points.add(Offset(x0 + dx, y0 + dy * t(v10, v11))); // right
      if ((v01 < 0) != (v11 < 0)) points.add(Offset(x0 + dx * t(v01, v11), y0 + dy)); // top
      if ((v00 < 0) != (v01 < 0)) points.add(Offset(x0, y0 + dy * t(v00, v01))); // left
      if (points.length == 2) {
        out.add((points[0], points[1]));
      } else if (points.length == 4) {
        out.add((points[0], points[1]));
        out.add((points[2], points[3]));
      }
    }
  }
  return out;
}

/// A grid step of 1, 2 or 5 times a power of ten, giving about [target] lines.
double niceStep(double span, {int target = 8}) {
  final raw = span / target;
  // (a double base: with an int one, pow works in ints, which overflow from 10^19 on)
  final mag = math.pow(10.0, (math.log(raw) / math.ln10).floor()).toDouble();
  final f = raw / mag;
  return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * mag;
}

/// The curve f(x, y) = 0 as polylines: the segments of [implicitSegments] joined end to end, so that
/// the curve can be dashed.
List<List<Offset>> implicitLines(PlotSpec spec, PlotRange range, {int columns = 140}) {
  final segs = implicitSegments(spec, range, columns: columns);
  final q = range.width / columns * 1e-4; // the same point reached from two cells differs by rounding only
  (int, int) key(Offset p) => ((p.dx / q).round(), (p.dy / q).round());
  final ends = <(int, int), List<int>>{};
  for (var i = 0; i < segs.length; i++) {
    (ends[key(segs[i].$1)] ??= []).add(i * 2);
    (ends[key(segs[i].$2)] ??= []).add(i * 2 + 1);
  }
  final used = List.filled(segs.length, false);
  Offset? take(Offset p) {
    for (final e in ends[key(p)] ?? const <int>[]) {
      if (used[e ~/ 2]) continue;
      used[e ~/ 2] = true;
      return e.isEven ? segs[e ~/ 2].$2 : segs[e ~/ 2].$1;
    }
    return null;
  }

  final lines = <List<Offset>>[];
  for (var i = 0; i < segs.length; i++) {
    if (used[i]) continue;
    used[i] = true;
    final line = [segs[i].$1, segs[i].$2];
    for (Offset? n; (n = take(line.last)) != null;) {
      line.add(n!);
    }
    final back = <Offset>[];
    for (Offset? n; (n = take(back.isEmpty ? line.first : back.last)) != null;) {
      back.add(n!);
    }
    lines.add([...back.reversed, ...line]);
  }
  return lines;
}

/// A tick step in multiples of pi, as [num]/[den] times pi, giving about [target] steps over [span].
({double step, int num, int den})? piStep(double span, {int target = 8}) {
  final raw = span / target;
  const base = [(1, 12), (1, 6), (1, 4), (1, 3), (1, 2), (1, 1), (2, 1), (5, 1)];
  if (raw < math.pi / 12 * 0.8) return null; // far in: decimals say it better
  for (var scale = 1; scale <= 1e9; scale *= 10) {
    for (final (n, d) in base) {
      final num = n * scale;
      if (num / d * math.pi >= raw * 0.8) return (step: num / d * math.pi, num: num, den: d);
    }
  }
  return null;
}

/// The label of the [i]th tick of a [piStep], like "3π/2".
String piLabel(int i, int num, int den) {
  var n = i * num, d = den;
  if (n == 0) return '0';
  final g = n.abs().gcd(d);
  n ~/= g;
  d ~/= g;
  final whole = n == 1 ? 'π' : n == -1 ? '-π' : '$nπ';
  return d == 1 ? whole : '$whole/$d';
}

/// Into how many parts the grid divides a [step] from [niceStep] (1, 2 or 5 times a power of ten).
int minorDivisions(double step) {
  final mag = math.pow(10.0, (math.log(step) / math.ln10).floor()).toDouble();
  return (step / mag).round() == 2 ? 4 : 5;
}

/// A LaTeX formula as plain text, for a title: `y = \frac{1}{x}` becomes `y = (1)/(x)`.
String plainFormula(String latex) {
  var s = latex;
  final frac = RegExp(r'\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}');
  for (var i = 0; i < 6 && frac.hasMatch(s); i++) {
    s = s.replaceAllMapped(frac, (m) => '(${m[1]})/(${m[2]})');
  }
  s = s.replaceAllMapped(RegExp(r'\\sqrt\s*\{([^{}]*)\}'), (m) => '√(${m[1]})');
  const symbols = {r'\cdot': '·', r'\times': '×', r'\pi': 'π', r'\theta': 'θ', r'\alpha': 'α', r'\beta': 'β', r'\infty': '∞', r'\left': '', r'\right': ''};
  symbols.forEach((k, v) => s = s.replaceAll(k, v));
  s = s.replaceAllMapped(RegExp(r'\\([a-zA-Z]+)'), (m) => m[1]!); // \sin -> sin
  s = s.replaceAll(RegExp(r'\\[,;! ]'), ' ').replaceAllMapped(RegExp(r'\^\{([^{}]*)\}'), (m) => '^(${m[1]})');
  return s.replaceAll('{', '(').replaceAll('}', ')').replaceAll(RegExp(r'\s+'), ' ').trim();
}
