import 'calculus.dart';
import 'equation_solver.dart';
import 'expr.dart';
import 'latex_parser.dart';

/// What [CalcPlan] says can be done with a piece of LaTeX.
enum CalcKind { solve, derive, integrate, ask, none }

/// What can be done with a piece of LaTeX: [kind] says which, [variables] are
/// the letters it can be done for ([ask] = the user picks derive or integrate).
class CalcPlan {
  final CalcKind kind;
  final List<String> variables;
  final String? message;

  const CalcPlan(this.kind, this.variables, [this.message]);
}

final _derivative = RegExp(
  r'^\\frac\{\s*d(?:\^\{?(\d+)\}?)?\s*\}\{\s*d\s*([a-zA-Z])(?:\^\{?(\d+)\}?)?\s*\}\s*(.+)$',
  dotAll: true,
);

/// `\frac{d}{dx} f` or `\int_a^b f dx`, read from the start of a line.
class Notation {
  final CalcKind kind;
  final String variable;
  final Expr expr;
  final int order;
  final Expr? lower, upper;

  Notation(this.kind, this.variable, this.expr, {this.order = 1, this.lower, this.upper});
}

String _prepare(String source) {
  var s = cleanLatex(source).replaceAll(RegExp(r'\\(mathrm|operatorname)\{d\}'), 'd');
  final eq = s.indexOf('=');
  if (eq >= 0 && (s.startsWith(r'\int') || s.startsWith(r'\frac{d'))) s = s.substring(0, eq);
  return s.trim();
}

/// `\int_a^b f dx` and `\frac{d}{dx} f`, or null when [source] has neither. With [infinite], a limit of an integral may be `\infty`
/// or `-\infty` (read as an infinite number, which only a check that is prepared for it can use).
Notation? readNotation(String source, {bool infinite = false}) {
  final s = _prepare(source);
  final d = _derivative.firstMatch(s);
  if (d != null) {
    final order = int.tryParse(d.group(1) ?? '') ?? int.tryParse(d.group(3) ?? '') ?? 1;
    return Notation(CalcKind.derive, d.group(2)!, parseExpression(d.group(4)!), order: order);
  }
  if (!s.startsWith(r'\int')) return null;
  var i = 4;
  String? group() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
    if (i >= s.length) return null;
    if (s[i] == '{') {
      var depth = 0;
      for (var j = i; j < s.length; j++) {
        if (s[j] == '{') depth++;
        if (s[j] == '}' && --depth == 0) {
          final inner = s.substring(i + 1, j);
          i = j + 1;
          return inner;
        }
      }
      throw ParseException('Unclosed bracket in the integral');
    }
    final m = RegExp(r'-?\\[a-zA-Z]+|-?\d+(\.\d+)?|[a-zA-Z]').matchAsPrefix(s, i);
    if (m == null) throw ParseException('Could not read the limits of the integral');
    i = m.end;
    return m.group(0);
  }

  String? lo, hi;
  while (i < s.length && s[i] == ' ') {
    i++;
  }
  if (i < s.length && s[i] == '_') {
    i++;
    lo = group();
    while (i < s.length && s[i] == ' ') {
      i++;
    }
    if (i < s.length && s[i] == '^') {
      i++;
      hi = group();
    }
  }
  final body = s.substring(i);
  final end = RegExp(r'd\s*([a-zA-Z])\s*$').firstMatch(body);
  if (end == null) throw ParseException('Write dx (or dt, ...) at the end of the integral');
  final integrand = body.substring(0, end.start).trim();
  if (integrand.isEmpty) throw ParseException('Nothing to integrate');
  if ((lo == null) != (hi == null)) throw ParseException('An integral needs both limits');
  Expr? limit(String? text) {
    if (text == null) return null;
    final t = text.replaceAll(' ', '');
    if (infinite && RegExp(r'^\+?\\infty$').hasMatch(t)) return const Num(double.infinity);
    if (infinite && t == r'-\infty') return const Num(double.negativeInfinity);
    return parseExpression(text, euler: true);
  }

  return Notation(CalcKind.integrate, end.group(1)!, parseExpression(integrand), lower: limit(lo), upper: limit(hi));
}

CalcPlan planCalculation(String source) {
  try {
    final n = readNotation(source);
    if (n != null) return CalcPlan(n.kind, [n.variable]);
    if (looksLikeEquation(source)) {
      final vars = equationVariables(source);
      return vars.isEmpty ? const CalcPlan(CalcKind.none, []) : CalcPlan(CalcKind.solve, vars);
    }
    // (a statistics function such as E[X] has the hidden letter of the checker in it: nothing to ask for)
    final vars = [for (final v in freeVariables(parseExpression(source))) if (v != modelName) v];
    return vars.isEmpty ? const CalcPlan(CalcKind.none, []) : CalcPlan(CalcKind.ask, vars);
  } on ParseException catch (e) {
    return CalcPlan(CalcKind.none, const [], e.message);
  }
}

/// Whether there is anything to calculate in [source].
bool canCalculate(String source) => const {CalcKind.solve, CalcKind.derive, CalcKind.integrate, CalcKind.ask}
    .contains(planCalculation(source).kind);

/// Does [kind] for [variable] with the LaTeX in [source].
EquationSolution calculate(String source, CalcKind kind, String variable) {
  try {
    if (kind == CalcKind.solve) return solveEquation(source, variable);
    final n = readNotation(source);
    final expr = n?.expr ?? parseExpression(source);
    return kind == CalcKind.derive
        ? _derive(expr, variable, n?.order ?? 1)
        : _integrate(expr, variable, n?.lower, n?.upper);
  } on ParseException catch (e) {
    throw SolveException('I could not read it: ${e.message}');
  } on UnsupportedError catch (e) {
    throw SolveException('${e.message} is not supported.');
  }
}

EquationSolution _derive(Expr expr, String v, int order) {
  var d = expr;
  for (var i = 0; i < order; i++) {
    d = derivative(d, v);
  }
  final head = order == 1 ? '\\frac{d}{d$v}' : '\\frac{d^{$order}}{d$v^{$order}}';
  return EquationSolution(v, ['$head\\left(${latexOf(expr)}\\right) = ${latexOf(d)}']);
}

EquationSolution _integrate(Expr expr, String v, Expr? lo, Expr? hi) {
  final anti = integrate(expr, v);
  if (anti == null) {
    throw SolveException('I do not know how to integrate this one.');
  }
  if (lo == null || hi == null) {
    return EquationSolution(v, ['\\int ${latexOf(expr)} \\, d$v = ${latexOf(anti)} + C']);
  }
  final value = sub(replace(anti, Sym(v), hi), replace(anti, Sym(v), lo));
  var out = '\\int_{${latexOf(lo)}}^{${latexOf(hi)}} ${latexOf(expr)} \\, d$v = ${latexOf(value)}';
  if (value is! Num && freeVariables(value).isEmpty) out += r' \approx ' + numberTex(evaluate(value, const {}));
  return EquationSolution(v, [out]);
}
