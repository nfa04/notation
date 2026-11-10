import 'expr.dart';

Expr _ln(Expr b) => fn(r'\ln', b);

/// d[e]/d[v]; every other letter counts as a constant.
Expr derivative(Expr e, String v) {
  switch (e) {
    case Num():
      return const Num(0);
    case Sym s:
      return !s.constant && s.name == v ? const Num(1) : const Num(0);
    case Add a:
      return add(a.terms.map((t) => derivative(t, v)));
    case Mul m:
      return add([
        for (var i = 0; i < m.factors.length; i++)
          mul([derivative(m.factors[i], v), for (var j = 0; j < m.factors.length; j++) if (j != i) m.factors[j]]),
      ]);
    case Pow p:
      if (!contains(p.exp, v)) {
        return mul([p.exp, pow(p.base, add([p.exp, const Num(-1)])), derivative(p.base, v)]);
      }
      if (!contains(p.base, v)) return mul([p, _ln(p.base), derivative(p.exp, v)]);
      return mul([
        p,
        add([
          mul([derivative(p.exp, v), _ln(p.base)]),
          mul([p.exp, derivative(p.base, v), pow(p.base, const Num(-1))]),
        ]),
      ]);
    case Fn f:
      final u = f.arg;
      final Expr outer;
      switch (f.name) {
        case r'\sin':
          outer = fn(r'\cos', u);
        case r'\cos':
          outer = neg(fn(r'\sin', u));
        case r'\tan':
          outer = pow(fn(r'\cos', u), const Num(-2));
        case r'\sinh':
          outer = fn(r'\cosh', u);
        case r'\cosh':
          outer = fn(r'\sinh', u);
        case r'\tanh':
          outer = pow(fn(r'\cosh', u), const Num(-2));
        case r'\ln':
          outer = pow(u, const Num(-1));
        case r'\exp':
          outer = f;
        case r'\log':
          outer = mul([pow(u, const Num(-1)), const Num(1 / 2.302585092994046)]);
        case r'\arcsin':
          outer = pow(sub(const Num(1), pow(u, const Num(2))), const Num(-0.5));
        case r'\arccos':
          outer = neg(pow(sub(const Num(1), pow(u, const Num(2))), const Num(-0.5)));
        case r'\arctan':
          outer = pow(add([const Num(1), pow(u, const Num(2))]), const Num(-1));
        case r'\abs':
          outer = mul([u, pow(f, const Num(-1))]); // (the sign of u)
        default:
          // (also the floor and the ceiling, which are flat between whole numbers: no derivative to give)
          throw UnsupportedError('derivative of ${f.name}');
      }
      return mul([outer, derivative(u, v)]);
    case Series r:
      // a sum of terms is derived term by term; the limits may not depend on the letter (and a product has no such rule)
      if (!r.sum || contains(r.from, v) || contains(r.to, v)) throw UnsupportedError('derivative of a series');
      return Series(true, r.variable, r.from, r.to, derivative(r.body, v));
    case Call():
      throw UnsupportedError('derivative of a function of several numbers');
  }
}

/// [e] with every occurrence of [from] replaced by [to].
Expr replace(Expr e, Expr from, Expr to) {
  final key = latexOf(from);
  Expr go(Expr e) {
    if (latexOf(e) == key) return to;
    return switch (e) {
      Num() || Sym() => e,
      Add a => add(a.terms.map(go)),
      Mul m => mul(m.factors.map(go)),
      Pow p => pow(go(p.base), go(p.exp)),
      Fn f => fn(f.name, go(f.arg)),
      Series r => Series(r.sum, r.variable, go(r.from), go(r.to), r.variable == key ? r.body : go(r.body)),
      Call c => Call(c.name, [for (final a in c.args) go(a)]),
    };
  }

  return go(e);
}

/// `a v + c` as (a, c) when [g] is linear in [v].
(Expr, Expr)? _linear(Expr g, String v) {
  final co = polynomial(g, v);
  if (co == null || co.length != 2) return null;
  return (co[1], co[0]);
}

bool _isE(Expr b) => b is Sym && b.constant && b.name == 'e';

/// An antiderivative of [e] with respect to [v], or null when no rule applies.
/// The constant of integration is left out.
Expr? integrate(Expr e, String v, {int depth = 0}) {
  if (!contains(e, v)) return mul([e, Sym(v)]);
  if (e is Add) {
    final parts = <Expr>[];
    for (final t in e.terms) {
      final i = integrate(t, v, depth: depth);
      if (i == null) return null;
      parts.add(i);
    }
    return add(parts);
  }
  if (e is Mul) {
    final constants = e.factors.where((f) => !contains(f, v)).toList();
    if (constants.isNotEmpty) {
      final i = integrate(mul(e.factors.where((f) => contains(f, v))), v, depth: depth);
      return i == null ? null : mul([...constants, i]);
    }
    return _byPolynomial(e, v) ?? _byParts(e, v) ?? _expSinCos(e, v) ?? _bySubstitution(e, v, depth);
  }
  return _atom(e, v) ?? _byPolynomial(e, v) ?? _bySubstitution(e, v, depth);
}

Expr? _byPolynomial(Expr e, String v) {
  final co = polynomial(e, v);
  if (co == null) return null;
  return add([
    for (var k = 0; k < co.length; k++) mul([co[k], pow(Sym(v), Num(k + 1.0)), Num(1 / (k + 1))]),
  ]);
}

Expr? _atom(Expr e, String v) {
  if (e is Sym) return mul([const Num(0.5), pow(e, const Num(2))]);
  if (e is Pow) {
    final b = e.base, x = e.exp;
    if (!contains(x, v)) {
      final lin = _linear(b, v);
      if (lin != null && x is Num) {
        final (a, _) = lin;
        if ((x.v + 1).abs() < 1e-12) return div(_lnAbs(b), a);
        return div(pow(b, Num(x.v + 1)), mul([Num(x.v + 1), a]));
      }
      // 1 / (a x^2 + c) = arctan
      if (x is Num && (x.v + 1).abs() < 1e-12) {
        final co = polynomial(b, v);
        if (co != null && co.length == 3 && isNum(co[1], 0) && co[0] is Num && co[2] is Num) {
          final c = (co[0] as Num).v, a = (co[2] as Num).v;
          if (a > 0 && c > 0) {
            return mul([pow(Num(a * c), const Num(-0.5)), fn(r'\arctan', mul([pow(Num(c / a), const Num(-0.5)), Sym(v)]))]);
          }
        }
      }
      return null;
    }
    if (!contains(b, v)) {
      final lin = _linear(x, v);
      if (lin == null) return null;
      final (a, _) = lin;
      return _isE(b) ? div(e, a) : div(e, mul([a, _ln(b)]));
    }
    return null;
  }
  if (e is Fn) {
    final lin = _linear(e.arg, v);
    if (lin == null) return null;
    final (a, _) = lin;
    final u = e.arg;
    final Expr? anti = switch (e.name) {
      r'\sin' => neg(fn(r'\cos', u)),
      r'\cos' => fn(r'\sin', u),
      r'\tan' => neg(_lnAbs(fn(r'\cos', u))),
      r'\exp' => e,
      r'\ln' => sub(mul([u, e]), u),
      r'\arctan' => sub(mul([u, e]), mul([const Num(0.5), _ln(add([const Num(1), pow(u, const Num(2))]))])),
      _ => null,
    };
    return anti == null ? null : div(anti, a);
  }
  return null;
}

Expr _lnAbs(Expr u) => _ln(Fn(r'\abs', u));

/// polynomial * (e^x | sin | cos | ln x), by repeated integration by parts.
Expr? _byParts(Mul m, String v) {
  final poly = <Expr>[], rest = <Expr>[];
  for (final f in m.factors) {
    final co = polynomial(f, v);
    (co != null && f is! Num ? poly : rest).add(f);
  }
  if (poly.isEmpty || rest.length != 1) return null;
  final p = mul(poly);
  final f = rest.first;
  if (f is Fn && f.name == r'\ln' && f.arg is Sym && (f.arg as Sym).name == v) {
    final q = integrate(p, v);
    final co = q == null ? null : polynomial(q, v);
    if (q == null || co == null || (co.isNotEmpty && !isNum(co.first, 0))) return null;
    // q / x is a polynomial too, since q has no constant term
    final tail = add([for (var k = 1; k < co.length; k++) mul([co[k], pow(Sym(v), Num(k.toDouble())), Num(1 / k)])]);
    return sub(mul([q, f]), tail);
  }
  final isTrig = f is Fn && const {r'\sin', r'\cos', r'\exp'}.contains(f.name) && _linear(f.arg, v) != null;
  final isExp = f is Pow && !contains(f.base, v) && _linear(f.exp, v) != null;
  if (!isTrig && !isExp) return null;
  final degree = polynomial(p, v)!.length - 1;
  var derivP = p;
  var anti = f;
  final terms = <Expr>[];
  for (var k = 0; k <= degree; k++) {
    final next = integrate(anti, v);
    if (next == null) return null;
    anti = next;
    terms.add(mul([Num(k.isEven ? 1 : -1), derivP, anti]));
    derivP = derivative(derivP, v);
  }
  return add(terms);
}

/// e^(a x) * sin(b x) and cos: the classic closed forms.
Expr? _expSinCos(Mul m, String v) {
  if (m.factors.length != 2) return null;
  Expr? ex, tr;
  for (final f in m.factors) {
    if (f is Pow && !contains(f.base, v)) ex = f;
    if (f is Fn && (f.name == r'\sin' || f.name == r'\cos')) tr = f;
  }
  if (ex is! Pow || tr is! Fn) return null;
  final ea = _linear(ex.exp, v), tb = _linear(tr.arg, v);
  if (ea == null || tb == null || !isNum(ea.$2, 0) || !isNum(tb.$2, 0)) return null;
  final a = _isE(ex.base) ? ea.$1 : mul([ea.$1, _ln(ex.base)]);
  final b = tb.$1;
  final den = add([pow(a, const Num(2)), pow(b, const Num(2))]);
  final sin = fn(r'\sin', tr.arg), cos = fn(r'\cos', tr.arg);
  final inner = tr.name == r'\sin' ? sub(mul([a, sin]), mul([b, cos])) : add([mul([a, cos]), mul([b, sin])]);
  return div(mul([ex, inner]), den);
}

/// u-substitution: find an inner part g so that e / g' depends on g alone.
Expr? _bySubstitution(Expr e, String v, int depth) {
  if (depth > 0) return null;
  final candidates = <String, Expr>{};
  void collect(Expr x) {
    switch (x) {
      case Num() || Sym():
        break;
      case Add a:
        a.terms.forEach(collect);
      case Mul m:
        m.factors.forEach(collect);
      case Pow p:
        if (contains(p.base, v) && p.base is! Sym) candidates[latexOf(p.base)] = p.base;
        if (contains(p.exp, v) && p.exp is! Sym) candidates[latexOf(p.exp)] = p.exp;
        collect(p.base);
        collect(p.exp);
      case Fn f:
        if (f.arg is! Sym) candidates[latexOf(f.arg)] = f.arg;
        candidates[latexOf(f)] = f;
        collect(f.arg);
      case Series() || Call():
        break;
    }
  }

  collect(e);
  const u = Sym('u_{s}');
  for (final g in candidates.values) {
    final dg = derivative(g, v);
    if (isNum(dg, 0)) continue;
    final t = replace(mul([e, pow(dg, const Num(-1))]), g, u);
    if (contains(t, v)) continue;
    final i = integrate(t, 'u_{s}', depth: depth + 1);
    if (i != null) return replace(i, u, g);
  }
  return null;
}
