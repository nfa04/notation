import 'dart:math' as math;

import 'expr.dart';
import 'latex_parser.dart';

/// Why an equation could not be solved, in words for the user.
class SolveException implements Exception {
  final String message;
  SolveException(this.message);
  @override
  String toString() => message;
}

/// The answer to "solve for [variable]". Each of [solutions] is LaTeX like
/// `x = 3`; [note] says when there is no (real) solution or every value works.
class EquationSolution {
  final String variable;
  final List<String> solutions;
  final String? note;

  const EquationSolution(this.variable, this.solutions, {this.note});

  /// All answers on one line: `x = 1 \;\text{or}\; x = 2`.
  String get latex => solutions.join(r' \;\text{or}\; ');
}

/// The letters of the equation that can be solved for (empty when [source] is
/// not an equation this solver reads).
List<String> equationVariables(String source) {
  if (!looksLikeEquation(source)) return const [];
  try {
    final (l, r) = parseEquation(source);
    return freeVariables(sub(l, r));
  } on ParseException {
    return const [];
  }
}

/// Solves `source` (LaTeX with one `=`) for [variable].
///
/// Polynomials up to degree two come out exactly, with the other letters kept
/// as letters. Anything else is solved numerically, but only when no other
/// letter is left, and only finds roots between -1000 and 1000.
EquationSolution solveEquation(String source, String variable) {
  final Expr left, right;
  try {
    (left, right) = parseEquation(source);
  } on ParseException catch (e) {
    throw SolveException('I could not read the equation: ${e.message}');
  }
  final f = sub(left, right);
  if (!contains(left, variable) && !contains(right, variable)) throw SolveException('The equation does not contain $variable.');
  final others = freeVariables(f).where((v) => v != variable).toList();

  final co = polynomial(f, variable);
  if (co != null && co.length <= 3) {
    return _exact(variable, co);
  }
  if (others.isNotEmpty) {
    throw SolveException(co == null
        ? 'This is not a polynomial in $variable, so it can only be solved when it has no other letters.'
        : 'Equations above degree two with other letters are not supported.');
  }
  return _numeric(variable, f);
}

EquationSolution _exact(String v, List<Expr> co) {
  String eq(Expr value, {bool approx = true}) {
    var out = '$v = ${latexOf(value)}';
    if (approx && freeVariables(value).isEmpty && out.contains(r'\sqrt')) {
      out += r' \approx ' + numberTex(evaluate(value, const {}));
    }
    return out;
  }

  switch (co.length) {
    case 0:
      return EquationSolution(v, const [], note: 'Every value of $v solves it.');
    case 1:
      return EquationSolution(v, const [], note: 'There is no solution.');
    case 2:
      return EquationSolution(v, [eq(div(neg(co[0]), co[1]))]);
  }
  final a = co[2], b = co[1], c = co[0];
  final disc = sub(pow(b, const Num(2)), mul([const Num(4), a, c]));
  if (disc is Num) {
    if (disc.v < -1e-12) return EquationSolution(v, const [], note: 'There is no real solution.');
    if (disc.v.abs() <= 1e-12) return EquationSolution(v, [eq(div(neg(b), mul([const Num(2), a])))]);
  }
  final root = pow(disc, const Num(0.5));
  final twoA = mul([const Num(2), a]);
  final plus = div(add([neg(b), root]), twoA);
  final minus = div(sub(neg(b), root), twoA);
  return EquationSolution(v, [eq(plus), eq(minus)]);
}

EquationSolution _numeric(String v, Expr f) {
  double at(double x) => evaluate(f, {v: x});
  const reach = 1000.0, step = 0.01;
  final roots = <double>[];
  void keep(double x) {
    if (!roots.any((r) => (r - x).abs() < 1e-6)) roots.add(x);
  }

  // the roots from x0 to x1 (one step), where the function is y0 and y1
  void look(double x0, double y0, double x1, double y1) {
    if (!y0.isFinite || !y1.isFinite) return;
    if (y0 == 0) {
      keep(x0);
    } else if (y0 * y1 < 0) {
      var a = x0, b = x1, fa = y0;
      for (var k = 0; k < 80; k++) {
        final m = (a + b) / 2, fm = at(m);
        if (fa * fm <= 0) {
          b = m;
        } else {
          a = m;
          fa = fm;
        }
      }
      final r = (a + b) / 2;
      // a sign change over a pole is not a root
      if (at(r).abs() < 1e-6 * math.max(1, y0.abs() + y1.abs())) keep(r);
    }
  }

  // outwards from zero, both ways at once: the roots nearest zero are found first, and the search ends when it has more than it
  // shows (a periodic function has thousands between -1000 and 1000, and only the ones nearest zero are of use)
  final y = at(0);
  var right = (x: 0.0, y: y), left = (x: 0.0, y: y);
  for (var i = 1; i <= reach ~/ step && roots.length <= 6; i++) {
    final r = (x: i * step, y: at(i * step)), l = (x: -i * step, y: at(-i * step));
    look(right.x, right.y, r.x, r.y);
    look(l.x, l.y, left.x, left.y);
    right = r;
    left = l;
  }
  if (roots.isEmpty) {
    return EquationSolution(v, const [], note: 'I found no solution between -1000 and 1000.');
  }
  // periodic functions have endless roots: show the ones nearest zero
  final truncated = roots.length > 6;
  roots.sort((a, b) => a.abs().compareTo(b.abs()));
  roots.removeRange(math.min(6, roots.length), roots.length);
  roots.sort();
  return EquationSolution(v, note: truncated ? 'There are more solutions further from zero.' : null, [
    for (final r in roots) ratOf(r) != null && at(r).abs() < 1e-9 ? '$v = ${numberTex(r)}' : '$v \\approx ${numberTex(r)}'
  ]);
}
