part of 'checker.dart';

// ---- inequalities ----

enum _Op { lt, le, gt, ge, ne, eq }

/// What makes a line an inequality.
final _orderRelation = RegExp(r'[<>≤≥≠]|\\(?:leqslant|geqslant|leq|geq|neq|le|ge|ne|lt|gt)(?![a-zA-Z])');

/// Any relation sign, `=` too (one inequality may have it in a chain: `x = 2 < y`).
final _anyRelation = RegExp(r'\\(?:leqslant|geqslant|leq|geq|neq|le|ge|ne|lt|gt)(?![a-zA-Z])|<=|>=|!=|[<>=≤≥≠]');

_Op _opOf(String t) => switch (t) {
      '<' || r'\lt' => _Op.lt,
      '>' || r'\gt' => _Op.gt,
      '≤' || '<=' || r'\le' || r'\leq' || r'\leqslant' => _Op.le,
      '≥' || '>=' || r'\ge' || r'\geq' || r'\geqslant' => _Op.ge,
      '≠' || '!=' || r'\ne' || r'\neq' => _Op.ne,
      _ => _Op.eq,
    };

bool _holdsOp(_Op op, double a, double b) {
  final eps = 1e-9 * math.max(1, math.max(a.abs(), b.abs()));
  return switch (op) {
    _Op.lt => a < b - eps,
    _Op.le => a <= b + eps,
    _Op.gt => a > b + eps,
    _Op.ge => a >= b - eps,
    _Op.ne => (a - b).abs() > eps,
    _Op.eq => (a - b).abs() <= eps,
  };
}

String _opTex(_Op op) => switch (op) {
      _Op.lt => '<',
      _Op.le => r'\le',
      _Op.gt => '>',
      _Op.ge => r'\ge',
      _Op.ne => r'\neq',
      _Op.eq => '=',
    };

/// `a < b \le c`: the expressions and the signs between them.
class _RelChain {
  final List<String> parts;
  final List<_Op> ops;
  _RelChain(this.parts, this.ops);
}

/// An inequality, or several joined by "or" (`x \le -2 \text{ or } x \ge 2`) and "and": [groups] are the alternatives, each
/// of them holds when all its chains do.
class _Relation {
  final List<List<_RelChain>> groups;
  _Relation(this.groups);

  static _RelChain? _chainOf(String piece) {
    final (parts, seps) = _splitTop(piece.trim(), [_anyRelation]);
    if (parts.length < 2 || parts.any((p) => p.trim().isEmpty)) return null;
    return _RelChain([for (final p in parts) p.trim()], [for (final s in seps) _opOf(s)]);
  }

  /// null when it is not an inequality this can look at.
  static _Relation? parse(String t) {
    if (t.contains(',') || t.contains(';')) return null;
    final (pieces, seps) = _splitTop(t, [_or]);
    final groups = <List<_RelChain>>[[]];
    for (var i = 0; i < pieces.length; i++) {
      final chain = _chainOf(pieces[i]);
      if (chain == null) return null;
      groups.last.add(chain);
      if (i < seps.length && RegExp(r'or|oder|lor|vee').hasMatch(seps[i])) groups.add([]);
    }
    if (groups.every((g) => g.every((c) => c.ops.every((o) => o == _Op.eq)))) return null;
    return _Relation(groups);
  }

  late final List<List<List<Expr>>> exprs = [
    for (final g in groups)
      [
        for (final c in g)
          [
            for (final p in c.parts)
              if (_opaque(p)) throw ParseException('Not an expression') else parseExpression(p),
          ],
      ],
  ];

  late final List<String> vars = _varsOf([for (final g in exprs) for (final c in g) ...c]);

  /// Whether it holds with the letters worth [env]; null when it cannot be worked out there.
  bool? holds(Map<String, double> env) {
    bool? any = false;
    for (var gi = 0; gi < groups.length; gi++) {
      bool? all = true;
      for (var ci = 0; ci < groups[gi].length; ci++) {
        final chain = groups[gi][ci];
        final values = [for (final e in exprs[gi][ci]) evaluate(e, env)];
        if (values.any((v) => !v.isFinite)) {
          all = all == false ? false : null;
          continue;
        }
        for (var k = 0; k < chain.ops.length; k++) {
          if (!_holdsOp(chain.ops[k], values[k], values[k + 1])) all = false;
        }
      }
      if (all == true) return true;
      if (all == null) any = null;
    }
    return any;
  }

  /// Where the sides meet: the zeros of each difference, for a single letter [v].
  List<double> roots(String v) {
    final out = <double>[];
    for (final g in exprs) {
      for (final c in g) {
        for (var k = 0; k + 1 < c.length; k++) {
          for (final r in _roots(sub(c[k], c[k + 1]), v) ?? const <double>[]) {
            if (!_has(out, r)) out.add(r);
          }
        }
      }
    }
    out.sort();
    return out;
  }
}

String _pointTex(Map<String, double> p) => p.entries.map((e) => '${e.key} = ${numberTex(e.value)}').join(r',\; ');

/// The points to try two inequalities in one letter at: where their sides meet, between those, and a grid.
List<Map<String, double>> _setPoints(String v, List<double> roots) {
  final xs = <double>{for (var i = -48; i <= 48; i++) i * 0.25, -500, -50, 50, 500, ...roots};
  for (var i = 0; i + 1 < roots.length; i++) {
    xs.add((roots[i] + roots[i + 1]) / 2);
  }
  if (roots.isNotEmpty) {
    xs.add(roots.first - 1);
    xs.add(roots.last + 1);
  }
  return [for (final x in xs) {v: x}];
}

/// The inequality as a line says it, for the example: `x > -3`, `-1 < x \le 4`, `x \le -2 \text{ or } x \ge 2`. Null when it
/// is not a handful of intervals.
String? _describeSet(bool Function(double) inSet, List<double> roots, String v) {
  final m = roots.length;
  final truth = <bool>[];
  for (var s = 0; s <= 2 * m; s++) {
    double x;
    if (s.isOdd) {
      x = roots[s ~/ 2];
    } else {
      final j = s ~/ 2;
      x = m == 0 ? 0 : j == 0 ? roots.first - 1 : j == m ? roots.last + 1 : (roots[j - 1] + roots[j]) / 2;
    }
    truth.add(inSet(x));
  }
  // maximal runs of true segments
  final pieces = <(double?, bool, double?, bool)>[];
  var s = 0;
  while (s < truth.length) {
    if (!truth[s]) {
      s++;
      continue;
    }
    final start = s;
    while (s + 1 < truth.length && truth[s + 1]) {
      s++;
    }
    final end = s;
    s++;
    final double? lo = start.isEven ? (start == 0 ? null : roots[start ~/ 2 - 1]) : roots[start ~/ 2];
    final double? hi = end.isEven ? (end == 2 * m ? null : roots[end ~/ 2]) : roots[end ~/ 2];
    pieces.add((lo, start.isOdd, hi, end.isOdd));
  }
  if (pieces.length > 4) return null;
  bool inPieces(double x) {
    for (final (lo, loIn, hi, hiIn) in pieces) {
      final aboveLo = lo == null || (loIn ? x >= lo - 1e-9 : x > lo + 1e-9);
      final belowHi = hi == null || (hiIn ? x <= hi + 1e-9 : x < hi - 1e-9);
      if (aboveLo && belowHi) return true;
    }
    return false;
  }

  // a pole or a gap that the zeros do not show would make the description wrong: it has to agree with the line on a grid
  for (var i = -96; i <= 96; i++) {
    final x = i * 0.125;
    if (roots.any((r) => (r - x).abs() < 1e-6)) continue;
    if (inPieces(x) != inSet(x)) return null;
  }
  if (pieces.isEmpty) return '$v \\in \\varnothing';
  final out = <String>[];
  for (final (lo, loIn, hi, hiIn) in pieces) {
    if (lo == null && hi == null) {
      out.add('$v \\in \\mathbb{R}');
    } else if (lo != null && hi != null && loIn && hiIn && (lo - hi).abs() < 1e-12) {
      out.add('$v = ${numberTex(lo)}');
    } else if (lo == null) {
      out.add('$v ${hiIn ? r'\le' : '<'} ${numberTex(hi!)}');
    } else if (hi == null) {
      out.add('$v ${loIn ? r'\ge' : '>'} ${numberTex(lo)}');
    } else {
      out.add('${numberTex(lo)} ${loIn ? r'\le' : '<'} $v ${hiIn ? r'\le' : '<'} ${numberTex(hi)}');
    }
  }
  return out.join(r' \;\text{or}\; ');
}

/// An inequality with numbers only (`3 < 5`, `\sqrt{2} < 1.5`) is right or it is not.
LineCheck? _checkRelation(_Relation r) {
  if (r.vars.isNotEmpty) return null;
  final holds = r.holds(const {});
  if (holds == null) return null;
  if (holds) return const LineCheck(verdict: Verdict.right);
  // what it should have said, for a single chain
  String? expected;
  if (r.groups.length == 1 && r.groups.single.length == 1) {
    final chain = r.groups.single.single;
    final values = [for (final e in r.exprs.single.single) evaluate(e, const {})];
    final parts = <String>[numberTex(values.first)];
    for (var k = 0; k < chain.ops.length; k++) {
      final a = values[k], b = values[k + 1];
      parts
        ..add(_holdsOp(chain.ops[k], a, b) ? _opTex(chain.ops[k]) : (_holdsOp(_Op.eq, a, b) ? '=' : (a < b ? '<' : '>')))
        ..add(numberTex(b));
    }
    expected = parts.join(' ');
  }
  return LineCheck(verdict: Verdict.wrong, reason: Reason.order, expected: expected);
}

/// An inequality against the one above it: the same solutions (or, after an arrow, at least the ones of the line above
/// still hold).
LineCheck? _relationStep(_Statement before, _Statement now) {
  final a = before.relation, b = now.relation;
  if (a == null || b == null) return null;
  final vars = a.vars;
  if (vars.isEmpty || vars.length != b.vars.length || !vars.toSet().containsAll(b.vars)) return null;
  final implication = now.link == _Link.implies;

  final single = vars.length == 1 ? vars.single : null;
  final roots = single == null ? const <double>[] : ([...a.roots(single), ...b.roots(single)]..sort());
  final points = single == null ? _pointsFor([for (final r in [a, b]) for (final g in r.exprs) for (final c in g) ...c]) : _setPoints(single, roots);

  final lost = <Map<String, double>>[], added = <Map<String, double>>[];
  var valid = 0;
  for (final p in points) {
    final x = a.holds(p), y = b.holds(p);
    if (x == null || y == null) continue;
    valid++;
    if (x && !y) lost.add(p);
    if (y && !x) added.add(p);
  }
  if (valid < 3) return null;
  if (lost.isEmpty && added.isEmpty) return const LineCheck(verdict: Verdict.right);
  if (implication && lost.isEmpty) return const LineCheck(verdict: Verdict.right);

  Map<String, double> nicest(List<Map<String, double>> ps) {
    double cost(Map<String, double> p) => p.values.fold(0.0, (t, x) => t + x.abs() + (ratOf(x)?.$2 ?? 50) * 0.01);
    return ps.reduce((x, y) => cost(x) <= cost(y) ? x : y);
  }

  // the values that went missing or were let in, as a line: `x \le -2`
  String? describe(bool Function(Map<String, double>) which) =>
      single == null ? null : _describeSet((x) => which({single: x}), roots, single);
  bool lostAt(Map<String, double> p) => (a.holds(p) ?? false) && !(b.holds(p) ?? true);
  bool addedAt(Map<String, double> p) => (b.holds(p) ?? false) && !(a.holds(p) ?? true);

  if (implication) {
    return LineCheck(
      verdict: Verdict.wrong,
      reason: Reason.notImplied,
      expected: describe(lostAt),
      counter: _pointTex(nicest(lost)),
    );
  }
  if (added.isEmpty) {
    return LineCheck(verdict: Verdict.lost, reason: Reason.lostSolution, expected: describe(lostAt) ?? _pointTex(nicest(lost)));
  }
  if (lost.isEmpty) {
    return LineCheck(verdict: Verdict.widened, reason: Reason.extraSolution, expected: describe(addedAt) ?? _pointTex(nicest(added)));
  }
  // different solutions altogether (a sign that should have turned over)
  final had = single == null ? null : _describeSet((x) => a.holds({single: x}) ?? false, roots, single);
  return LineCheck(verdict: Verdict.wrong, reason: Reason.setDiffers, expected: had, counter: _pointTex(nicest(lost)));
}
