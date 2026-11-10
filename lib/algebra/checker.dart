import 'dart:math' as math;

import 'calculator.dart';
import 'calculus.dart';
import 'equation_solver.dart';
import 'expr.dart';
import 'latex_parser.dart';
import 'logic.dart';
import 'matrix.dart';
import 'units.dart';

part 'checker_logic.dart';
part 'checker_matrix.dart';
part 'checker_relations.dart';
part 'checker_units.dart';

/// How a line of maths (or the step from the line above it) turned out.
enum Verdict {
  /// Correct.
  right,

  /// Correct up to rounding (`1/3 = 0.333`).
  rounded,

  /// Not correct.
  wrong,

  /// The step lets in solutions the line above did not have (squaring both sides).
  widened,

  /// The step drops a solution the line above had (dividing by something that can be zero).
  lost,
}

/// What a [Verdict] is about, so that it can be put into words.
enum Reason {
  arithmetic,
  identity,
  step,
  derivative,
  integral,
  limit,
  notSolution,
  lostSolution,
  extraSolution,
  notImplied,

  /// An inequality with numbers that is not true (`5 < 3`).
  order,

  /// Two inequalities that do not have the same solutions, and they are not told apart by what one of them lets in or out.
  setDiffers,

  /// A matrix that is not what the line above worked out to.
  matrix,

  /// A matrix expression whose sizes do not fit (`2 \times 3` times `2 \times 3`).
  shape,

  /// A matrix with no inverse.
  singular,

  /// `a \equiv b \pmod m` where it does not hold.
  congruence,

  /// Two formulas of logic that are not the same (some row of the truth table tells them apart).
  notEquivalent,

  /// Quantities whose units do not fit: `0.5\,kg \cdot 9.81\,m/s^2 = 4.9\,J`, or a length added to a mass.
  units,
}

/// What is known about one line of maths.
class LineCheck {
  /// Whether the line (or the step to it from the line above) is right; null when there is nothing to say (an
  /// equation to solve, or something that could not be checked).
  final Verdict? verdict;
  final Reason? reason;

  /// LaTeX of what it should read, when it is wrong and that can be worked out.
  final String? expected;

  /// LaTeX of an example that shows it, such as `x = 2:\; 16 \neq 18`.
  final String? counter;

  /// LaTeX of what the line works out to, for a line that ends with `=` and waits for its result.
  final String? answer;

  const LineCheck({this.verdict, this.reason, this.expected, this.counter, this.answer});

  static const nothing = LineCheck();

  bool get isNothing => verdict == null && answer == null;

  /// Something to look at again: the line, or the step to it, is wrong, loses solutions or adds some.
  bool get isProblem => verdict == Verdict.wrong || verdict == Verdict.lost || verdict == Verdict.widened;
}

/// Checks the lines of a worked solution one after the other. [lines] are the LaTeX of each line (null for one that could
/// not be read); the result has one entry per line. A line is checked against itself (`17 \cdot 24 = 408`,
/// `(x+2)^2 = x^2 + 4x + 4`, a derivative, an integral, a limit) and against the line above it (an equation that is
/// the same as the one above, with the same solutions).
///
/// Everything is worked out numerically: two expressions are the same when they agree at many points, which is as good
/// as certain for the algebra of a course and much more robust than rewriting rules. Nothing that cannot be parsed or
/// decided is reported.
List<LineCheck> checkLines(List<String?> lines) => withSampleMeans(lines, () => _checkLines(lines));

List<LineCheck> _checkLines(List<String?> lines) {
  final out = List<LineCheck>.filled(lines.length, LineCheck.nothing);
  _Statement? previous;
  // the letters that stand for a matrix written above (`A = \begin{pmatrix}...`)
  final names = <String, MExpr>{};
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    if (raw == null) {
      previous = null;
      continue;
    }
    LineCheck? merged;
    final matrices = <MatrixLiteral>[];
    // a line about propositions is not cut at its arrows; when it turns out not to be logic after all, it is read as maths as usual
    List<_Statement?>? logic;
    if (looksLogical(normalizeLatex(raw))) {
      final parsed = [for (final (text, _) in _segments(raw, matrices, logical: true)) _Statement.parseLogic(text)];
      if (parsed.isNotEmpty && parsed.every((p) => p != null)) logic = parsed;
    }
    final segments = logic == null ? _segments(raw, matrices) : const <(String, _Link)>[];
    // units after numbers (`9.81 m/s^2`, `4.81 N`) are worked out to SI numbers: that is what is checked as maths, and [_checkUnits] looks at the units
    final readings = [for (final (text, _) in segments) matrices.isEmpty ? readUnits(text) : null];
    final statements = logic ?? [for (var j = 0; j < segments.length; j++) _Statement.parse(readings[j]?.clean ?? segments[j].$1, matrices)?..link = segments[j].$2];
    for (var k = 0; k < statements.length; k++) {
      var st = statements[k];
      if (st == null) {
        previous = null;
        continue;
      }
      var own = _guard(() => _checkOwn(st!, names));
      if (own?.verdict == Verdict.wrong && logic == null) {
        // a times dot written low is read as a decimal point (`31.18 = 558` for `31 \cdot 18 = 558`): when it is right as a product, it is
        // not reported
        final alt = _lowDotReading(readings[k]?.clean ?? segments[k].$1, segments[k].$2, matrices);
        final altOwn = alt == null ? null : _guard(() => _checkOwn(alt, names));
        if (alt != null && altOwn != null && !altOwn.isProblem) {
          st = alt;
          own = null;
        }
      }
      final reading = logic == null ? readings[k] : null;
      if (reading != null) own = _worse(own, _guard(() => _checkUnits(reading, st!)));
      final cur = st;
      final step = previous == null ? null : _guard(() => _checkStep(previous!, cur, names));
      merged = _worse(merged, _worse(own, step));
      previous = st;
    }
    if (merged != null) out[i] = merged;
  }
  return out;
}

/// The statement with each point after a whole number that does not begin with 0 read as a times dot (`31.18` as `31 \cdot 18`; `0.2`
/// is a decimal for sure), or null when there is none.
_Statement? _lowDotReading(String text, _Link link, List<MatrixLiteral> matrices) {
  final dots = RegExp(r'(?<![\d.])([1-9]\d*)\.(?=\d)');
  if (!dots.hasMatch(text)) return null;
  return _Statement.parse(text.replaceAllMapped(dots, (m) => '${m[1]} \\cdot '), matrices)?..link = link;
}

T? _guard<T>(T? Function() f) {
  try {
    return f();
  } on ParseException {
    return null;
  } on UnsupportedError {
    return null;
  } on SolveException {
    return null;
  } on RangeError {
    return null;
  } on FormatException {
    return null;
  }
}

int _rank(Verdict? v) => switch (v) {
      null => 0,
      Verdict.rounded => 1,
      Verdict.right => 2,
      Verdict.widened => 3,
      Verdict.lost => 4,
      Verdict.wrong => 5,
    };

/// The more telling of two results: a mistake before a tick; the fields of an answer are kept.
LineCheck? _worse(LineCheck? a, LineCheck? b) {
  if (a == null) return b;
  if (b == null) return a;
  final first = _rank(b.verdict) > _rank(a.verdict) ? b : a;
  final other = identical(first, a) ? b : a;
  if (first.answer != null || other.answer == null) return first;
  return LineCheck(verdict: first.verdict, reason: first.reason, expected: first.expected, counter: first.counter, answer: other.answer);
}

// ---- reading a line ----

/// How a line goes on from the one before: `=` and the like say they are the same (equations: with the same solutions);
/// `\Rightarrow` (and `\to`, `→`) says the new line follows (it may have more solutions: squaring is a fine deduction),
/// `\iff` (`⇔`) says both ways.
enum _Link { none, implies, iff }

final _arrows = RegExp(
    r'\\(?:Rightarrow|Longrightarrow|rightarrow|longrightarrow|to|implies|leadsto|Leftrightarrow|Longleftrightarrow|leftrightarrow|iff)(?![a-zA-Z])|[⇒⟹→⟶⇔⟺↔]');
final _bothWays = RegExp(r'Leftrightarrow|Longleftrightarrow|leftrightarrow|iff|[⇔⟺↔]');
final _relation = RegExp(r'=|\\approx(?![a-zA-Z])|\\simeq(?![a-zA-Z])|\\equiv(?![a-zA-Z])|\\cong(?![a-zA-Z])');
final _or = RegExp(r'\\(?:text|mathrm|textrm)\{\s*(?:or|and|oder|und)\s*\}|\\(?:lor|vee|land|wedge)(?![a-zA-Z])');
/// The end of a congruence: `\pmod{m}`, `\pmod m`, `(\mod m)`, `\bmod m`.
final _modulus = RegExp(r'(?:\s|\\ )*(?:\\pmod\s*\{([^{}]*)\}|\\pmod\s+([A-Za-z0-9]+)|\(\s*\\b?mod(?:\s|\\ )+([^()]+?)\s*\)|\\b?mod\s*\{?([A-Za-z0-9]+)\}?)\s*$');
final _gap = RegExp(r'\\q{1,2}uad(?![a-zA-Z])');
/// What is about sets (or far more than less), which is not looked at.
final _setLike = RegExp(r'\\(?:ll|gg|in|notin|subset|subseteq|supset|supseteq|cup|cap|setminus)(?![a-zA-Z])');

/// The statements of one line: it is cut at `\\` and at arrows such as `\Rightarrow`, and the fences of `aligned` are
/// dropped.
List<(String, _Link)> _segments(String raw, List<MatrixLiteral> matrices, {bool logical = false}) {
  var s = normalizeLatex(maskMatrices(raw, matrices))
      // (a quad beside "or", "and" or a comma is part of one statement: `x = 2 \quad \text{or} \quad x = -2`)
      .replaceAllMapped(RegExp(r'(?:\\q{1,2}uad\s*)?(' + _or.pattern + r')\s*(?:\\q{1,2}uad(?![a-zA-Z]))?'), (m) => ' ${m[1]} ')
      .replaceAllMapped(RegExp(r'([,;])\s*\\q{1,2}uad(?![a-zA-Z])'), (m) => '${m[1]} ')
      .replaceAll(RegExp(r'\\(?:begin|end)\{(?:aligned|align\*?|alignedat|split|gathered|gather\*?|eqnarray\*?)\}(?:\{[^}]*\})?'), ' ')
      .replaceAll('&', ' ')
      .replaceAll(RegExp(r'\\(?:displaystyle|,|;|:|!)'), ' ');
  final out = <(String, _Link)>[];
  for (final line in _splitTop(s, [RegExp(r'\\\\')]).$1) {
    // (in logic an arrow is a sign inside of the formula: the line is not cut at it)
    if (logical) {
      if (line.trim().isNotEmpty) out.add((line.trim(), _Link.none));
      continue;
    }
    final (parts, arrows) = _splitTop(line, [_arrows]);
    var link = _Link.none;
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) link = _bothWays.hasMatch(arrows[i - 1]) ? _Link.iff : _Link.implies;
      // (an arrow at the start of a line goes on from the line above)
      // a quad separates statements that stand side by side (`1 + 1 = 2 \quad 2 + 2 = 4`); a note (`\quad | -3`) says what was
      // done and is not maths to check
      for (final piece in _splitTop(parts[i], [_gap]).$1) {
        final text = _withoutNote(piece).trim();
        if (text.isEmpty) continue;
        out.add((text, link));
        link = _Link.none;
      }
    }
  }
  return out;
}

/// [piece] without a note about the step, such as `| -3`, `| : 2` or `|\cdot 2` (what the person did to both sides): a
/// bar that is followed by an operator and that no other bar closes.
String _withoutNote(String piece) {
  final t = piece.replaceAll(RegExp(r'\\(?:left|right)(?![a-zA-Z])'), '').replaceAll(RegExp(r'\\(?:lvert|rvert|vert|mid)(?![a-zA-Z])'), '|');
  final bars = [for (var i = 0; i < t.length; i++) if (t[i] == '|') i];
  if (bars.length.isEven) return piece;
  final after = t.substring(bars.last + 1).trimLeft();
  if (!RegExp(r'^(?:[-+:*/^]|\\(?:cdot|div|times|sqrt|frac)(?![a-zA-Z]))').hasMatch(after)) return piece;
  return t.substring(0, bars.last);
}

/// [s] cut at the places where one of [separators] matches outside of braces; and what matched.
(List<String>, List<String>) _splitTop(String s, List<RegExp> separators, {bool brackets = false}) {
  final parts = <String>[];
  final seps = <String>[];
  var depth = 0, start = 0, i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '{' || brackets && (c == '(' || c == '[')) {
      depth++;
    } else if (c == '}' || brackets && (c == ')' || c == ']')) {
      depth--;
    } else if (depth == 0) {
      Match? hit;
      for (final r in separators) {
        hit = r.matchAsPrefix(s, i);
        if (hit != null && hit.end > hit.start) break;
        hit = null;
      }
      if (hit != null) {
        parts.add(s.substring(start, i));
        seps.add(hit.group(0)!);
        i = hit.end;
        start = i;
        continue;
      }
    }
    i++;
  }
  parts.add(s.substring(start));
  return (parts, seps);
}

/// `a = b = c` or `a ≈ b`: the expressions and how each pair is related.
class _Chain {
  final List<String> parts;
  final List<bool> approximate;
  _Chain(this.parts, this.approximate);
}

class _Statement {
  /// More than one when the statement lists solutions (`x = 2 \text{ or } x = -2`, `x = \pm 2`).
  final List<_Chain> chains;

  /// Whether it began with `=` (it goes on from the line above) or ended with it (it waits for a result).
  final bool lead, trail;

  /// How it goes on from the statement before it.
  _Link link = _Link.none;

  /// What it says when it is an inequality (`2x < 8`, `x \le -2 \text{ or } x \ge 2`); then [chains] is empty.
  final _Relation? relation;

  /// The matrices of the line (`\begin{pmatrix}...`), which stand in the text as [matrixMark]s.
  final List<MatrixLiteral> matrices;

  /// What it says when it is about propositions (`\neg (p \land q) \equiv \neg p \lor \neg q`); then [chains] is empty.
  final LogicLine? logic;

  /// For `a \equiv b \pmod{m}`: the text of `m`.
  String? modulus;

  _Statement(this.chains, this.lead, this.trail, {this.relation, this.matrices = const [], this.logic});

  /// A statement of logic, or null when [text] is not one.
  static _Statement? parseLogic(String text) {
    final l = parseLogicLine(text);
    return l == null ? null : _Statement(const [], l.lead != null, false, logic: l);
  }

  _Chain get first => chains.first;
  bool get isList => chains.length > 1;

  /// null when it is not maths this can look at (words, sets, a half-finished line).
  static _Statement? parse(String text, [List<MatrixLiteral> matrices = const []]) {
    var t = text.trim();
    // a congruence: `a \equiv b \pmod{m}` (the modulus is not one of the sides)
    String? modulus;
    if (RegExp(r'\\equiv(?![a-zA-Z])|≡').hasMatch(t)) {
      final m = _modulus.firstMatch(t);
      if (m != null) {
        modulus = (m[1] ?? m[2] ?? m[3] ?? m[4])!.trim();
        t = t.substring(0, m.start).trim();
      }
    }
    final st = _parseStatement(t, matrices);
    st?.modulus = modulus;
    return modulus != null && st != null && st.chains.isEmpty ? null : st;
  }

  static _Statement? _parseStatement(String text, List<MatrixLiteral> matrices) {
    var t = text.trim();
    // (what is inside of `P(X \le 2)` or `P(A \cup B)` is not an inequality or a statement about sets)
    final probe = _maskStatistics(t);
    if (t.isEmpty || _setLike.hasMatch(probe) || t.contains(r'\text') && !_or.hasMatch(t)) return null;
    if (_orderRelation.hasMatch(probe)) {
      final r = _Relation.parse(t);
      return r == null ? null : _Statement(const [], false, false, relation: r);
    }
    final alternatives = <String>[];
    for (final a in _splitTop(t.replaceAll(RegExp(r'[;,]'), ' , '), [_or, RegExp(r',')], brackets: true).$1) {
      if (a.trim().isNotEmpty) alternatives.add(a.trim());
    }
    // \pm: both signs
    final expanded = <String>[];
    for (final a in alternatives) {
      if (a.contains(r'\pm') || a.contains(r'\mp')) {
        expanded.add(a.replaceAll(r'\pm', '+').replaceAll(r'\mp', '-'));
        expanded.add(a.replaceAll(r'\pm', '-').replaceAll(r'\mp', '+'));
      } else {
        expanded.add(a);
      }
    }
    if (expanded.isEmpty || expanded.length > 6) return null;
    final chains = <_Chain>[];
    var lead = false, trail = false;
    for (final a in expanded) {
      final (parts, seps) = _splitTop(a, [_relation], brackets: true);
      final relations = [...seps];
      if (parts.first.trim().isEmpty) {
        // began with the relation
        parts.removeAt(0);
        relations.removeAt(0);
        lead = true;
      }
      if (parts.isNotEmpty && parts.last.trim().isEmpty && relations.isNotEmpty) {
        parts.removeLast();
        relations.removeLast();
        trail = true;
      }
      if (parts.isEmpty || parts.any((p) => p.trim().isEmpty)) return null;
      chains.add(_Chain([for (final p in parts) p.trim()], [for (final r in relations) r.startsWith(r'\a') || r.startsWith(r'\s')]));
    }
    if (chains.length > 1 && chains.any((c) => c.parts.length != 2)) return null;
    // x_1 = 2, x_2 = 3: the solutions of x
    if (chains.length > 1) {
      final subscripted = [for (final c in chains) RegExp(r'^([a-zA-Z])\s*_\s*\{?\s*([^{}\s]+)\s*\}?$').firstMatch(c.parts.first)];
      if (subscripted.every((m) => m != null) &&
          subscripted.map((m) => m!.group(1)).toSet().length == 1 &&
          subscripted.map((m) => m!.group(2)).toSet().length == chains.length) {
        return _Statement([for (var k = 0; k < chains.length; k++) _Chain([subscripted[k]!.group(1)!, ...chains[k].parts.skip(1)], chains[k].approximate)], lead, trail, matrices: matrices);
      }
    }
    return _Statement(chains, lead, trail, matrices: matrices);
  }
}

// ---- numbers ----

/// Points to try an expression at: some fixed ones that people write, then random ones from ranges that suit square
/// roots, logarithms and inverse sine as well. The letters in [whole] (the limits of a sum, what a factorial is taken of)
/// only get whole numbers, from 1 to 12.
List<Map<String, double>> _points(List<String> vars, [Set<String> whole = const {}]) {
  final rnd = math.Random(7);
  final out = <Map<String, double>>[];
  const counts = [3.0, 2.0, 5.0, 4.0, 6.0, 1.0, 8.0, 7.0, 10.0, 9.0, 12.0, 11.0];
  var at = 0;
  Map<String, double> pick(double Function(String v, int k) real) {
    final index = at++;
    final point = <String, double>{};
    for (var k = 0; k < vars.length; k++) {
      final v = vars[k];
      point[v] = whole.contains(v) ? counts[(index * 5 + k * 3) % counts.length] : real(v, k);
    }
    return point;
  }

  for (final fixed in const [2.0, 0.5, 3.0, -1.0, 1.5, 0.25, -2.5]) {
    out.add(pick((v, k) => fixed + k * 0.37));
  }
  for (var i = 0; i < 40; i++) {
    out.add(pick((v, k) => switch (i % 5) {
          0 => 0.2 + rnd.nextDouble() * 2.8,
          1 => -3 + rnd.nextDouble() * 6,
          2 => 0.05 + rnd.nextDouble() * 0.9,
          3 => 3 + rnd.nextDouble() * 9, // (for \sqrt{x - 5}, \ln(x - 3) ...)
          _ => -12 + rnd.nextDouble() * 9,
        }));
  }
  return out;
}

/// The points to try [es] at.
List<Map<String, double>> _pointsFor(List<Expr> es) => _points(_varsOf(es), {for (final e in es) ...wholeNumberLetters(e)});

bool _close(double a, double b, [double tolerance = 1e-7]) => (a - b).abs() <= tolerance * math.max(1, math.max(a.abs(), b.abs()));

class _Diff {
  final bool equal;

  /// Where they differ.
  final Map<String, double>? at;
  final double? left, right;

  /// Always the same distance apart / always in the same proportion (so there is no solution at all).
  final bool constantDifference, constantRatio;
  const _Diff(this.equal, {this.at, this.left, this.right, this.constantDifference = false, this.constantRatio = false});
}

List<String> _varsOf(Iterable<Expr> es) {
  final out = <String>[];
  for (final e in es) {
    for (final v in freeVariables(e)) {
      if (!out.contains(v)) out.add(v);
    }
  }
  return out;
}

/// Whether [a] and [b] are the same function; null when there are too few points where both can be worked out.
_Diff? _compare(Expr a, Expr b) {
  var valid = 0;
  _Diff? firstDifference;
  double? diff, ratio;
  var constantDiff = true, constantRatio = true;
  // (formulas with random variables: the first difference in each kind of probability space, and the kinds that were looked at)
  final stat = containsStat(a) || containsStat(b);
  // (events that cannot happen together make every intersection and every condition 0: no excuse for a formula that has one, as it would
  // hold for the wrong reason)
  final exclusive = stat && !usesCall(a, const {r'\cap', callPGiven}) && !usesCall(b, const {r'\cap', callPGiven});
  final differs = <int, _Diff>{};
  final kinds = <int>{};
  for (final p in _pointsFor([a, b])) {
    final kind = (p[modelName] ?? 0).round().abs() % modelKinds;
    if (stat && kind == 2 && !exclusive) continue;
    final x = evaluate(a, p), y = evaluate(b, p);
    if (!x.isFinite || !y.isFinite) continue;
    valid++;
    if (stat) kinds.add(kind);
    if (!_close(x, y)) {
      if (stat) {
        differs.putIfAbsent(kind, () => _Diff(false, at: p, left: x, right: y));
      } else {
        firstDifference ??= _Diff(false, at: p, left: x, right: y);
      }
    }
    final d = x - y;
    diff ??= d;
    if (!_close(d, diff, 1e-9)) constantDiff = false;
    if (y.abs() > 1e-9) {
      final q = x / y;
      ratio ??= q;
      if (!_close(q, ratio, 1e-9)) constantRatio = false;
    } else {
      constantRatio = false;
    }
  }
  if (valid < 3) return null;
  if (stat) {
    if (differs.isEmpty) return const _Diff(true);
    // a formula that holds when the variables are independent, or when the events cannot happen together, may be what a note says in
    // words: only one that fails in every kind of space is called wrong
    if (kinds.any((k) => !differs.containsKey(k))) return null;
    firstDifference = differs[differs.keys.reduce(math.min)];
  }
  if (firstDifference == null) return const _Diff(true);
  return _Diff(false,
      at: firstDifference.at,
      left: firstDifference.left,
      right: firstDifference.right,
      constantDifference: constantDiff && diff != null && diff.abs() > 1e-9,
      constantRatio: constantRatio && ratio != null && (ratio - 1).abs() > 1e-9 && ratio.abs() > 1e-9);
}

String _example(_Diff d, {String relation = r'\neq'}) {
  final at = d.at!;
  final shown = at.entries.where((e) => !e.key.startsWith('‹'));
  final where = shown.isEmpty ? '' : '${shown.map((e) => '${e.key} = ${numberTex(e.value)}').join(', ')}:\\; ';
  return '$where${numberTex(d.left!)} $relation ${numberTex(d.right!)}';
}

/// Whether [part] holds something that is not an expression in numbers and letters: an unknown function (`f(x)`, `F(t)`,
/// `S_{xx}(\omega)`, which would be read as a product) or a differential (`\frac{dy}{dx}`, `\partial`, whose `d`s would
/// cancel as if they were letters).
bool _opaque(String part) => _opaqueUnmasked(_maskStatistics(part));

final _statisticCall = RegExp(r'(?<![A-Za-z\\])[EP]\s*[(\[]|\\(?:Pr|Var|Cov)\s*[(\[]');

/// [s] with every expectation, variance, covariance and probability (`E[X]`, `P(A \cup B)`) written as `1`: what is inside is not
/// for the tests of what kind of statement it is.
String _maskStatistics(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final m = _statisticCall.matchAsPrefix(s, i);
    if (m != null) {
      final open = m.end - 1;
      var depth = 0, close = -1;
      for (var j = open; j < s.length && close < 0; j++) {
        if ('([{'.contains(s[j])) depth++;
        if (')]}'.contains(s[j]) && --depth == 0) close = j;
      }
      if (close > 0 && (m[0]!.startsWith(r'\') || statisticalBrackets(s.substring(open + 1, close)))) {
        out.write('1');
        i = close + 1;
        continue;
      }
    }
    out.write(s[i]);
    i++;
  }
  return out.toString();
}

bool _opaqueUnmasked(String part) =>
    RegExp(r'(?<![A-Za-z\\])(?:[A-Z]|[fghpq])(?:_\{[^{}]*\}|_[A-Za-z0-9])?\s*\(|\\(?:phi|varphi|psi|gamma|chi|delta|Psi|Gamma|Delta|Omega|Sigma)\s*\(|\\Phi\s*\([^()]*[A-Za-z\\]').hasMatch(part) ||
    RegExp(r'\\partial|\\frac\{\s*d[^{}]*\}\{\s*d|\\mathrm\{\s*d').hasMatch(part);

/// Whether [part] is a measured or irrational value (a decimal, a root, \pi, a logarithm ...), which is rounded when it is
/// written as a whole number.
bool _looksMeasured(String part) => RegExp(r'\d\.\d|\\(?:sqrt|pi|ln|log|sin|cos|tan|exp)(?![a-zA-Z])|e\s*\^').hasMatch(part);

/// [a] / [b] when that is the same number at every point (and not 0); else null.
double? _constantRatio(Expr a, Expr b) {
  double? ratio;
  var valid = 0;
  for (final p in _pointsFor([a, b])) {
    final x = evaluate(a, p), y = evaluate(b, p);
    if (!x.isFinite || !y.isFinite || y.abs() < 1e-9) continue;
    valid++;
    final q = x / y;
    ratio ??= q;
    if (!_close(q, ratio, 1e-6)) return null;
  }
  return valid >= 3 && ratio != null && ratio.abs() > 1e-9 ? ratio : null;
}

/// How many decimals [source] is written with, when its last number is a decimal fraction; else null.
int? _decimalsOf(String source) {
  final m = RegExp(r'(\d*)\.(\d+)\s*(?:\^\s*\{?\s*\\circ\s*\}?|°|\\?%)?\s*$').firstMatch(source.trim());
  return m?.group(2)?.length;
}

/// What one unit of [source] is worth in the numbers the checker works in: degrees are radians.
double _unitOf(String source) => RegExp(r'\\circ\s*\}?\s*$|°\s*$').hasMatch(source.trim())
    ? math.pi / 180
    : RegExp(r'%\s*$').hasMatch(source.trim())
        ? 0.01
        : 1;

// ---- the line against itself ----

LineCheck? _checkOwn(_Statement st, Map<String, MExpr> names) {
  if (st.relation != null) return _checkRelation(st.relation!);
  if (st.logic != null) return _checkLogic(st.logic!);
  if (st.modulus != null) return _checkCongruence(st);
  if (st.chains.any((c) => c.parts.any((p) => _isMatrixText(p, names)))) return _checkMatrices(st, names);
  if (st.isList) return null;
  final chain = st.first;
  final head = chain.parts.first;
  if (_isNotation(head) && !st.lead) return _checkNotation(st);

  final exprs = [for (final p in chain.parts) _opaque(p) ? const Num(double.nan) : parseExpression(p)];
  final allVars = _varsOf(exprs);

  if (st.trail && chain.parts.length == 1 && !st.lead) {
    final e = exprs.single;
    if (allVars.isEmpty) {
      final v = evaluate(e, const {});
      return v.isFinite ? LineCheck(answer: numberTex(v)) : null;
    }
    return null;
  }

  LineCheck? result;
  for (var k = 0; k + 1 < exprs.length; k++) {
    // (not the pairs that are about an unknown function or a differential)
    if (_opaque(chain.parts[k]) || _opaque(chain.parts[k + 1])) continue;
    final a = exprs[k], b = exprs[k + 1];
    final varsA = freeVariables(a), varsB = freeVariables(b);
    if (varsA.isEmpty && varsB.isEmpty) {
      final x = evaluate(a, const {}), y = evaluate(b, const {});
      if (!x.isFinite || !y.isFinite) continue;
      if (_close(x, y, 1e-9)) {
        result = _worse(result, const LineCheck(verdict: Verdict.right));
        continue;
      }
      // rounded to the decimals of the side that has them (`0.333 = \frac{1}{3}`): off by at most half of the last one. With
      // \approx one of them (a cut-off figure) or 1% is fine. A whole number after a measured value (`150\sqrt{1.4} = 177`)
      // is rounded to the unit.
      final decimals = _decimalsOf(chain.parts[k + 1]) ?? _decimalsOf(chain.parts[k]);
      final unit = _decimalsOf(chain.parts[k + 1]) != null ? _unitOf(chain.parts[k + 1]) : _unitOf(chain.parts[k]);
      final approximate = chain.approximate[k];
      var slack = decimals == null ? 0.0 : 0.5 * math.pow(10, -decimals).toDouble() * unit;
      if (approximate) slack = math.max(decimals == null ? 0.0 : math.pow(10, -decimals).toDouble() * unit, 0.01 * math.max(1, y.abs()));
      // a figure written after \approx with decimals is the value rounded to them or cut off there (`0.9750 \approx 0.975`, `3.1623 \approx 3.16`),
      // not anything within a unit of the last one
      var cutOff = false;
      final written = _decimalsOf(chain.parts[k + 1]);
      if (approximate && written != null) {
        final step = math.pow(10, -written).toDouble() * _unitOf(chain.parts[k + 1]);
        slack = 0.5 * step;
        cutOff = x * y >= 0 && x.abs() - y.abs() >= -1e-12 * math.max(1, x.abs()) && x.abs() - y.abs() < step * 1.0001;
      }
      // (a whole number of percent is rounded as well: `\frac{3}{8} = 38\%`)
      final percent = RegExp(r'^-?\d+\s*\\?%$').hasMatch(chain.parts[k + 1].trim());
      final toUnit = decimals == null && !approximate && (percent || RegExp(r'^-?\d+$').hasMatch(chain.parts[k + 1].trim()) && _looksMeasured(chain.parts[k]));
      if (toUnit) slack = percent ? 0.005 : 0.5;
      if ((approximate || decimals != null || toUnit) && ((x - y).abs() <= slack * 1.0001 || cutOff)) {
        result = _worse(result, const LineCheck(verdict: Verdict.rounded));
      } else {
        result = _worse(
            result,
            LineCheck(
              verdict: Verdict.wrong,
              reason: Reason.arithmetic,
              expected: numberTex(x),
              counter: '${numberTex(x)} \\neq ${numberTex(y)}',
            ));
      }
      continue;
    }
    final d = _compare(a, b);
    if (d == null) continue;
    if (d.equal) {
      result = _worse(result, const LineCheck(verdict: Verdict.right));
      continue;
    }
    // \approx between formulas with letters (`\frac{1}{x} \approx 1 - x`) holds near a point: it can only be told when the two
    // are in a fixed proportion (`\pi r^2 \approx 3.14 r^2`)
    if (chain.approximate[k]) {
      final q = _constantRatio(a, b);
      if (q == null) continue;
      result = _worse(
          result,
          (q - 1).abs() <= 0.01
              ? const LineCheck(verdict: Verdict.rounded)
              : LineCheck(verdict: Verdict.wrong, reason: Reason.identity, expected: _simplified(a), counter: _example(d)));
      continue;
    }
    // sides that mix letters and numbers, or use other letters, are an equation or a formula, not a claim
    // (an expression that is one number whatever the letters are, such as sec^2 x - tan^2 x, against a number, is a claim)
    final constants = _isConstant(a) && _isConstant(b);
    final sameLetters = constants || varsA.length == varsB.length && varsA.toSet().containsAll(varsB);
    final claim = constants || isDiscrete(a) || isDiscrete(b) || chain.parts.length >= 3 || st.lead || chain.approximate[k] || d.constantDifference || d.constantRatio;
    if (!claim || !sameLetters) continue;
    result = _worse(
        result,
        LineCheck(
          verdict: Verdict.wrong,
          reason: Reason.identity,
          expected: _simplified(a),
          counter: _example(d),
        ));
  }
  return result;
}

String? _simplified(Expr e) {
  try {
    return latexOf(e);
  } catch (_) {
    return null;
  }
}

/// Whether [part] is a derivative, an integral or a limit that is still to be worked out.
bool _isNotation(String part) {
  final t = normalizeLatex(part).replaceAll(RegExp(r'\\left|\\right'), '').replaceAll(r'\limits', '').trim();
  return RegExp(r'^\\(?:int|lim)(?![a-zA-Z])|^\\frac\{\s*d').hasMatch(t);
}

/// `\frac{d}{dx} f = g`, `\int f \, dx = F + C` and `\int_a^b f \, dx = value`, `\lim ... = L`; and the lines that go on
/// from them (`= g = h`).
LineCheck? _checkNotation(_Statement st) {
  final chain = st.first;
  if (chain.parts.length < 2) {
    // (a line waiting for its result)
    if (!st.trail) return null;
    final head = normalizeLatex(chain.parts.first).replaceAll(r'\limits', '').trim();
    if (head.startsWith(r'\lim')) return null;
    final n = readNotation(chain.parts.first);
    if (n == null) return null;
    final r = calculate(chain.parts.first, n.kind, n.variable);
    return LineCheck(answer: r.solutions.join(r' \;\text{or}\; '));
  }
  var result = _notationClaim(chain.parts.first, chain.parts[1]);
  // (the claim may go on: `\frac{d}{dx} x^2 = 2x = 2 \cdot x`)
  for (var k = 1; k + 1 < chain.parts.length; k++) {
    result = _worse(result, _sameThing(parseExpression(chain.parts[k]), parseExpression(chain.parts[k + 1]), reason: Reason.step));
  }
  return result;
}

/// Whether [claimed] is what the derivative, integral or limit [head] works out to.
LineCheck? _notationClaim(String head, String claimedSource) {
  final cleanHead = normalizeLatex(head).replaceAll(r'\limits', '').trim();
  if (cleanHead.startsWith(r'\lim')) return _checkLimit(cleanHead, claimedSource);
  final n = readNotation(head, infinite: true);
  if (n == null) return null;
  if (_opaque(head.replaceFirst(RegExp(r'^\s*\\frac\{\s*d[^{}]*\}\{\s*d[^{}]*\}'), '')) || _opaque(claimedSource) || RegExp(r'\\(?:int|lim)(?![a-zA-Z])').hasMatch(claimedSource)) return null;
  // (letters other than the variable are numbers here; a body without the variable is more likely an unknown function of it)
  if (!contains(n.expr, n.variable) && freeVariables(n.expr).isNotEmpty) return null;
  final claimed = parseExpression(claimedSource, euler: true);
  switch (n.kind) {
    case CalcKind.derive:
      var d = n.expr;
      for (var i = 0; i < n.order; i++) {
        d = derivative(d, n.variable);
      }
      final diff = _compare(d, claimed);
      if (diff == null) return null;
      return diff.equal
          ? const LineCheck(verdict: Verdict.right)
          : LineCheck(verdict: Verdict.wrong, reason: Reason.derivative, expected: _simplified(d), counter: _example(diff));
    case CalcKind.integrate:
      if (n.lower == null || n.upper == null) {
        // the derivative of the result has to be what was integrated (whatever the constant)
        final back = derivative(claimed, n.variable);
        final diff = _compare(back, n.expr);
        if (diff == null) return null;
        if (diff.equal) return const LineCheck(verdict: Verdict.right);
        final anti = integrate(n.expr, n.variable);
        return LineCheck(
          verdict: Verdict.wrong,
          reason: Reason.integral,
          expected: anti == null ? null : '${latexOf(anti)} + C',
          counter: _example(diff),
        );
      }
      final value = _definiteIntegral(n);
      if (value == null) return null;
      if (freeVariables(claimed).isNotEmpty) return null;
      final c = evaluate(claimed, const {});
      if (!c.isFinite) return null;
      if (_close(value, c, 1e-6)) return const LineCheck(verdict: Verdict.right);
      final decimals = _decimalsOf(claimedSource);
      if (decimals != null && (value - c).abs() <= 0.5 * math.pow(10, -decimals) * 1.0001) return const LineCheck(verdict: Verdict.rounded);
      return LineCheck(verdict: Verdict.wrong, reason: Reason.integral, expected: numberTex(value), counter: '${numberTex(value)} \\neq ${numberTex(c)}');
    default:
      return null;
  }
}

/// The value of a definite integral: by Simpson's rule (also to an infinite limit, when the integral converges).
double? _definiteIntegral(Notation n) {
  if (freeVariables(n.lower!).isNotEmpty || freeVariables(n.upper!).isNotEmpty) return null;
  final lo = evaluate(n.lower!, const {}), hi = evaluate(n.upper!, const {});
  if (lo.isNaN || hi.isNaN) return null;
  if (freeVariables(n.expr).any((v) => v != n.variable)) return null;
  double f(double x) => evaluate(n.expr, {n.variable: x});
  if (lo.isFinite && hi.isFinite) return _simpson(f, lo, hi, 4000);
  if (lo == double.negativeInfinity && hi == double.infinity) {
    final left = _tail(f, 0, -1), right = _tail(f, 0, 1);
    return left == null || right == null ? null : left + right;
  }
  if (hi == double.infinity && lo.isFinite) return _tail(f, lo, 1);
  if (lo == double.negativeInfinity && hi.isFinite) return _tail(f, hi, -1);
  return null;
}

double? _simpson(double Function(double) f, double lo, double hi, int steps) {
  final h = (hi - lo) / steps;
  var sum = f(lo) + f(hi);
  if (!sum.isFinite) return null;
  for (var i = 1; i < steps; i++) {
    final y = f(lo + i * h);
    if (!y.isFinite) return null;
    sum += (i.isOdd ? 4 : 2) * y;
  }
  return sum * h / 3;
}

/// The integral of [f] from [from] to infinity ([direction] 1) or from minus infinity to [from] (-1), by the substitution
/// `x = from + direction * t / (1 - t)`; null when it does not settle on a value (it diverges, or is not smooth enough).
double? _tail(double Function(double) f, double from, double direction) {
  double g(double t) => f(from + direction * t / (1 - t)) / ((1 - t) * (1 - t));
  final near = _simpson(g, 0, 1 - 1e-6, 4000), far = _simpson(g, 0, 1 - 1e-9, 8000);
  if (near == null || far == null || !_close(near, far, 1e-6)) return null;
  return far;
}

/// `\lim_{x \to a} f = L`, estimated from both sides.
LineCheck? _checkLimit(String head, String claimedSource) {
  final m = RegExp(r'^\\lim\s*_\s*\{\s*([a-zA-Z])\s*(?:\\(?:to|rightarrow|longrightarrow)(?![a-zA-Z])|→)\s*([^}]*)\}\s*(.+)$', dotAll: true).firstMatch(head);
  if (m == null) return null;
  final v = m.group(1)!;
  final target = m.group(2)!.replaceAll(' ', '');
  if (_opaque(m.group(3)!) || _opaque(claimedSource)) return null;
  final f = parseExpression(m.group(3)!, euler: true);
  if (freeVariables(f).any((x) => x != v)) return null;
  double at(double x) => evaluate(f, {v: x});
  double? estimate;
  if (target == r'\infty' || target == r'+\infty') {
    final a = at(1e6), b = at(1e9);
    if (a.isFinite && b.isFinite && _close(a, b, 1e-4)) estimate = b;
  } else if (target == r'-\infty') {
    final a = at(-1e6), b = at(-1e9);
    if (a.isFinite && b.isFinite && _close(a, b, 1e-4)) estimate = b;
  } else {
    // (from one side: `0^+`, `0^-`)
    final oneSided = RegExp(r'^(.*?)\^\{?([+-])\}?$').firstMatch(target);
    final a = evaluate(parseExpression(oneSided?.group(1) ?? target), const {});
    if (!a.isFinite) return null;
    final side = oneSided == null ? const [1.0, -1.0] : [oneSided.group(2) == '+' ? 1.0 : -1.0];
    final sides = <double>[];
    for (final sign in side) {
      final x = at(a + sign * 1e-5), y = at(a + sign * 1e-7);
      if (x.isFinite && y.isFinite && _close(x, y, 1e-3)) sides.add(y);
    }
    if (sides.length == side.length && (sides.length == 1 || _close(sides[0], sides[1], 1e-3))) estimate = sides.reduce((a, b) => a + b) / sides.length;
  }
  if (estimate == null) return null;
  final claimed = parseExpression(claimedSource, euler: true);
  if (freeVariables(claimed).isNotEmpty) return null;
  final c = evaluate(claimed, const {});
  if (!c.isFinite) return null;
  if (_close(estimate, c, 1e-3)) return const LineCheck(verdict: Verdict.right);
  return LineCheck(verdict: Verdict.wrong, reason: Reason.limit, expected: numberTex(estimate), counter: '${numberTex(estimate)} \\neq ${numberTex(c)}');
}

// ---- a line against the line above ----

/// The equations a statement says (several when it lists solutions), or null when it is not an equation to solve.
List<(Expr, Expr)>? _equations(_Statement st) {
  final out = <(Expr, Expr)>[];
  for (final c in st.chains) {
    if (c.parts.length != 2 || c.approximate.any((a) => a) || st.lead || st.trail) return null;
    if (RegExp(r'^\\(?:int|lim|frac\{\s*d)').hasMatch(c.parts.first) || c.parts.any(_opaque)) return null;
    out.add((parseExpression(c.parts[0]), parseExpression(c.parts[1])));
  }
  final vars = _varsOf([for (final e in out) ...[e.$1, e.$2]]);
  return vars.isEmpty ? null : out;
}

LineCheck? _checkStep(_Statement before, _Statement now, Map<String, MExpr> names) {
  if (before.relation != null || now.relation != null) return _relationStep(before, now);
  if (before.logic != null || now.logic != null) return _logicStep(before, now);
  if (now.lead && before.chains.isNotEmpty && !before.isList && !before.trail && (_isMatrixText(before.first.parts.last, names) || _isMatrixText(now.first.parts.first, names))) {
    return _matrixPair(
      _matrixSide(before.first.parts.last, before, names),
      _matrixSide(now.first.parts.first, now, names),
      names,
    );
  }
  if (now.lead) {
    // "= ..." goes on from the last expression above
    if (before.isList || before.trail) return null;
    // (it goes on from a derivative, an integral or a limit that was not worked out yet)
    if (_isNotation(before.first.parts.last)) return _notationClaim(before.first.parts.last, now.first.parts.first);
    final last = parseExpression(before.first.parts.last);
    final next = parseExpression(now.first.parts.first);
    return _sameThing(last, next, reason: Reason.step);
  }
  final a = _equations(before), b = _equations(now);
  if (a == null || b == null) return null;
  return _equationStep(a, b, implication: now.link == _Link.implies);
}

LineCheck? _sameThing(Expr a, Expr b, {required Reason reason}) {
  final va = freeVariables(a), vb = freeVariables(b);
  if (va.isEmpty && vb.isEmpty) {
    final x = evaluate(a, const {}), y = evaluate(b, const {});
    if (!x.isFinite || !y.isFinite) return null;
    if (_close(x, y, 1e-9)) return const LineCheck(verdict: Verdict.right);
    return LineCheck(verdict: Verdict.wrong, reason: reason, expected: numberTex(x), counter: '${numberTex(x)} \\neq ${numberTex(y)}');
  }
  final d = _compare(a, b);
  if (d == null) return null;
  if (d.equal) return const LineCheck(verdict: Verdict.right);
  // other letters on one side: a value put in (`2x + 1` and then `2 \cdot 3 + 1`) is not a mistake, unless the expression is
  // the same number whatever the letters are
  if (va.length != vb.length || !va.toSet().containsAll(vb)) {
    final alone = va.length > vb.length ? a : b;
    final other = va.length > vb.length ? b : a;
    if (!_isConstant(alone) || freeVariables(other).isNotEmpty && !_isConstant(other)) return null;
  }
  return LineCheck(verdict: Verdict.wrong, reason: reason, expected: _simplified(a), counter: _example(d));
}

/// Whether [e] has the same value wherever it can be worked out.
bool _isConstant(Expr e) {
  double? first;
  var valid = 0;
  for (final p in _pointsFor([e])) {
    final y = evaluate(e, p);
    if (!y.isFinite) continue;
    valid++;
    first ??= y;
    if (!_close(y, first, 1e-9)) return false;
  }
  return valid >= 3;
}

/// [implication]: the new line only has to follow from the old one (it may have more solutions), not be the same.
LineCheck? _equationStep(List<(Expr, Expr)> before, List<(Expr, Expr)> now, {bool implication = false}) {
  final vars = _varsOf([for (final e in [...before, ...now]) ...[e.$1, e.$2]]);
  if (vars.isEmpty) return null;
  final fs = [for (final e in before) sub(e.$1, e.$2)];
  final gs = [for (final e in now) sub(e.$1, e.$2)];

  // one equation each: the same up to a factor (both sides added to, subtracted from, multiplied or divided)
  if (fs.length == 1 && gs.length == 1 && _proportional(fs.single, gs.single)) return const LineCheck(verdict: Verdict.right);

  // lines about different things are not steps of one another
  final shared = _varsOf([for (final e in before) ...[e.$1, e.$2]]).toSet().intersection(_varsOf([for (final e in now) ...[e.$1, e.$2]]).toSet());
  if (shared.isEmpty) return null;

  if (vars.length == 1) {
    final v = vars.single;
    final rootsBefore = _rootsOf(fs, v), rootsNow = _rootsOf(gs, v);
    if (rootsBefore == null || rootsNow == null) return null;
    if (rootsBefore.isEmpty && rootsNow.isEmpty) return null;
    final lost = [for (final r in rootsBefore) if (!_has(rootsNow, r)) r];
    final extra = [for (final r in rootsNow) if (!_has(rootsBefore, r)) r];
    if (lost.isEmpty && extra.isEmpty) return const LineCheck(verdict: Verdict.right);
    if (implication && lost.isEmpty) return const LineCheck(verdict: Verdict.right);
    String values(List<double> rs) => rs.map((r) => '$v = ${numberTex(r)}').join(r' \;\text{or}\; ');
    if (implication) return LineCheck(verdict: Verdict.wrong, reason: Reason.notImplied, expected: values(lost));
    if (extra.isEmpty) return LineCheck(verdict: Verdict.lost, reason: Reason.lostSolution, expected: values(lost));
    if (lost.isEmpty) return LineCheck(verdict: Verdict.widened, reason: Reason.extraSolution, expected: values(extra));
    return LineCheck(verdict: Verdict.wrong, reason: Reason.step, expected: values(rootsBefore));
  }

  // several letters: a line that solves for one letter has to satisfy the line above
  // (the same letters in both lines: with fewer, a value was put in, which the line above does not say)
  if (fs.length == 1 && gs.length == 1 && _sameLetters(before, now)) {
    final solved = _solvedFor(now.single);
    if (solved != null) {
      final (v, g) = solved;
      if (!contains(fs.single, v)) return null;
      final check = _compare(replace(fs.single, Sym(v), g), const Num(0));
      if (check == null) return null;
      return check.equal
          ? const LineCheck(verdict: Verdict.right)
          : LineCheck(verdict: Verdict.wrong, reason: Reason.notSolution, counter: _example(check));
    }
  }
  return null;
}

bool _sameLetters(List<(Expr, Expr)> a, List<(Expr, Expr)> b) {
  final x = _varsOf([for (final e in a) ...[e.$1, e.$2]]).toSet(), y = _varsOf([for (final e in b) ...[e.$1, e.$2]]).toSet();
  return x.length == y.length && x.containsAll(y);
}

/// `v = g` (or `g = v`) with g not containing v.
(String, Expr)? _solvedFor((Expr, Expr) eq) {
  final (l, r) = eq;
  if (l is Sym && !l.constant && !contains(r, l.name)) return (l.name, r);
  if (r is Sym && !r.constant && !contains(l, r.name)) return (r.name, l);
  return null;
}

/// Whether [g] is [f] times a constant that is not zero.
bool _proportional(Expr f, Expr g) {
  double? factor;
  var valid = 0;
  for (final p in _pointsFor([f, g])) {
    final x = evaluate(f, p), y = evaluate(g, p);
    if (!x.isFinite || !y.isFinite) continue;
    if (x.abs() < 1e-9 && y.abs() < 1e-9) {
      valid++;
      continue;
    }
    if (x.abs() < 1e-9 || y.abs() < 1e-9) return false;
    final q = y / x;
    factor ??= q;
    if (!_close(q, factor, 1e-8)) return false;
    valid++;
  }
  return valid >= 3;
}

bool _has(List<double> roots, double x) => roots.any((r) => (r - x).abs() <= 1e-5 * (1 + x.abs()));

/// All the real solutions of the equations (together) in one letter, or null when that cannot be told.
List<double>? _rootsOf(List<Expr> fs, String v) {
  final all = <double>[];
  for (final f in fs) {
    final r = _roots(f, v);
    if (r == null) return null;
    for (final x in r) {
      if (!_has(all, x)) all.add(x);
    }
  }
  all.sort();
  return all;
}

/// The real roots of [f] in [v] between about -1000 and 1000, or null when [f] is zero everywhere.
List<double>? _roots(Expr f, String v) {
  double at(double x) => evaluate(f, {v: x});
  // zero everywhere: every number is a solution (a line like 0 = 0)
  var zero = 0, valid = 0;
  for (final p in _points([v]).take(12)) {
    final y = at(p[v]!);
    if (!y.isFinite) continue;
    valid++;
    if (y.abs() < 1e-9) zero++;
  }
  if (valid > 0 && zero == valid) return null;

  final roots = <double>[];
  void keep(double x) {
    if (!roots.any((r) => (r - x).abs() <= 1e-6 * (1 + x.abs()))) roots.add(x);
  }

  void scan(double lo, double hi, int steps) {
    final h = (hi - lo) / steps;
    var x0 = lo, y0 = at(lo);
    double? xm, ym; // the point before x0
    for (var i = 1; i <= steps; i++) {
      final x1 = lo + i * h, y1 = at(x1);
      if (y0 == 0 && x0 != lo) keep(x0);
      if (y0.isFinite && y1.isFinite && y0 * y1 < 0) {
        var a = x0, b = x1, fa = y0;
        for (var k = 0; k < 70; k++) {
          final mid = (a + b) / 2, fm = at(mid);
          if (fm.isNaN) break;
          if (fa * fm <= 0) {
            b = mid;
          } else {
            a = mid;
            fa = fm;
          }
        }
        final r = (a + b) / 2, fr = at(r);
        // a jump over a pole is not a root
        final near = math.max(at(r - 1e-3).abs(), at(r + 1e-3).abs());
        if (fr.isFinite && fr.abs() <= 1e-5 * (1 + (near.isFinite ? near : 0))) keep(r);
      } else if (xm != null && y0.isFinite && ym!.isFinite && y1.isFinite && y0.abs() <= ym.abs() && y0.abs() <= y1.abs() && y0.abs() < 1e-2) {
        // a root that touches zero without crossing (a double root)
        var a = xm, b = x1;
        for (var k = 0; k < 100; k++) {
          final m1 = a + (b - a) / 3, m2 = b - (b - a) / 3;
          if (at(m1).abs() < at(m2).abs()) {
            b = m2;
          } else {
            a = m1;
          }
        }
        final r = (a + b) / 2;
        if (at(r).abs() < 1e-9) keep(r);
      }
      xm = x0;
      ym = y0;
      x0 = x1;
      y0 = y1;
    }
  }

  scan(-12, 12, 8000);
  scan(-1000, 1000, 8000);
  roots.sort();
  return roots;
}

// ---- solving ----

/// What the maths in [latex] works out to, as LaTeX: the value of a calculation, the solution of an equation, a
/// derivative or an integral. Null when that cannot be done.
String? answerFor(String latex) {
  try {
    final plan = planCalculation(latex);
    switch (plan.kind) {
      case CalcKind.solve:
        if (plan.variables.length != 1) return null;
        return calculate(latex, CalcKind.solve, plan.variables.single).latex;
      case CalcKind.derive || CalcKind.integrate:
        return calculate(latex, plan.kind, plan.variables.single).latex;
      case CalcKind.ask:
        return null;
      case CalcKind.none:
        final cleaned = latex.replaceAll(RegExp(r'=\s*$'), '');
        final v = evaluate(parseExpression(cleaned), const {});
        return v.isFinite ? numberTex(v) : null;
    }
  } catch (_) {
    return null;
  }
}
