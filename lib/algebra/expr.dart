import 'dart:math' as math;

part 'statistics.dart';

/// A small algebraic expression tree: just enough to solve school-level
/// equations. Subtraction is `a + (-1)*b` and division `a * b^-1`.
sealed class Expr {
  const Expr();
}

/// A number.
final class Num extends Expr {
  final double v;
  const Num(this.v);
}

/// A letter. [name] is how it is written in LaTeX (`x`, `x_{1}`, `\alpha`).
/// Constants (`\pi`, Euler's `e`) are never solved for.
final class Sym extends Expr {
  final String name;
  final bool constant;
  const Sym(this.name, {this.constant = false});
}

/// A sum of [terms] (subtraction is a sum with a negated term).
final class Add extends Expr {
  final List<Expr> terms;
  const Add(this.terms);
}

/// A product of [factors] (division is a product with a negative power).
final class Mul extends Expr {
  final List<Expr> factors;
  const Mul(this.factors);
}

/// [base] raised to [exp].
final class Pow extends Expr {
  final Expr base;
  final Expr exp;
  const Pow(this.base, this.exp);
}

/// `\sin`, `\ln`, ... applied to one argument.
final class Fn extends Expr {
  final String name;
  final Expr arg;
  const Fn(this.name, this.arg);
}

/// The standard normal distribution function `\Phi(z)`: written for a number only (`\Phi(1.96)`), as in the tables a course gives out.
const normalCdfName = r'\Phi';

/// The error function (to about 1e-14).
double erf(double x) {
  final a = x.abs();
  double r;
  if (a < 3) {
    // the series 2/sqrt(pi) * sum (-1)^n a^(2n+1) / (n! (2n+1))
    var term = a, sum = a;
    for (var n = 1; n < 100; n++) {
      term *= -a * a / n;
      sum += term / (2 * n + 1);
    }
    r = 2 / math.sqrt(math.pi) * sum;
  } else {
    // erfc as a continued fraction
    var t = a;
    for (var k = 80; k >= 1; k--) {
      t = a + (k / 2) / t;
    }
    r = 1 - math.exp(-a * a) / math.sqrt(math.pi) / t;
  }
  return x < 0 ? -r : r;
}

/// The standard normal distribution function: the probability of a value up to [z].
double normalCdf(double z) => 0.5 * (1 + erf(z / math.sqrt2));

/// The name of the factorial function in an [Fn] (`n!` for a letter or an expression; a whole number is worked out at once).
const factorialName = r'\fact';

/// `\sum_{k=from}^{to} body` or `\prod_{k=from}^{to} body` with limits that are not numbers (`n`, `n+1`): worked out
/// by adding up the terms, which needs whole-number limits (see [evaluate]).
final class Series extends Expr {
  final bool sum;

  /// The letter that counts (bound: it is not a letter of the whole expression).
  final String variable;
  final Expr from, to, body;
  const Series(this.sum, this.variable, this.from, this.to, this.body);
}

/// A function of two or more numbers: `a \bmod b`, `\gcd(a, b)`, `\lcm(a, b)`, `\min(a, b)`, `\max(a, b)`. [name] is one of [callNames].
final class Call extends Expr {
  final String name;
  final List<Expr> args;
  const Call(this.name, this.args);
}

const callMod = r'\bmod';
const callNames = {callMod, r'\gcd', r'\lcm', r'\min', r'\max'};

/// The functions of one number that round: `\lfloor x \rfloor` and `\lceil x \rceil`.
const floorName = r'\floor';
const ceilName = r'\ceil';

/// The most terms a [Series] is added up from.
const largestSeries = 5000;

const double _eps = 1e-12;

bool isNum(Expr e, [double? value]) => e is Num && (value == null || (e.v - value).abs() < _eps);

/// `p/q` when [d] is a ratio of small whole numbers.
(int, int)? ratOf(double d) {
  if (!d.isFinite || d.abs() > 1e9) return null;
  for (var q = 1; q <= 1000; q++) {
    final p = (d * q).roundToDouble();
    if ((d * q - p).abs() < 1e-9 * math.max(1, q)) return (p.toInt(), q);
  }
  return null;
}

// ---- smart constructors: fold numbers, drop 0 and 1 ----

Expr add(Iterable<Expr> xs) {
  final terms = <Expr>[];
  var sum = 0.0;
  void take(Expr e) {
    if (e is Add) {
      e.terms.forEach(take);
    } else if (e is Num) {
      sum += e.v;
    } else {
      terms.add(e);
    }
  }

  xs.forEach(take);
  // 2x + 3x = 5x: same rest, coefficients added
  final coefficients = <String, double>{};
  final rests = <String, Expr>{};
  for (final t in terms) {
    var c = 1.0;
    var rest = t;
    if (t is Mul && t.factors.first is Num) {
      c = (t.factors.first as Num).v;
      rest = mul(t.factors.skip(1));
    }
    final key = latexOf(rest);
    coefficients[key] = (coefficients[key] ?? 0) + c;
    rests.putIfAbsent(key, () => rest);
  }
  final out = <Expr>[
    for (final key in rests.keys)
      if (coefficients[key]!.abs() > _eps) mul([Num(coefficients[key]!), rests[key]!]),
  ];
  if (sum.abs() > _eps) out.add(Num(sum));
  if (out.isEmpty) return const Num(0);
  return out.length == 1 ? out.first : Add(out);
}

Expr mul(Iterable<Expr> xs) {
  final raw = <Expr>[];
  var product = 1.0;
  void take(Expr e) {
    if (e is Mul) {
      e.factors.forEach(take);
    } else if (e is Num) {
      product *= e.v;
    } else {
      raw.add(e);
    }
  }

  xs.forEach(take);
  if (product.abs() < _eps) return const Num(0);
  // x * x^2 = x^3: same base, exponents added
  final index = <String, int>{};
  final bases = <Expr>[];
  final exps = <Expr>[];
  for (final f in raw) {
    final base = f is Pow ? f.base : f;
    final exp = f is Pow ? f.exp : const Num(1);
    final key = latexOf(base);
    final at = index[key];
    if (at == null) {
      index[key] = bases.length;
      bases.add(base);
      exps.add(exp);
    } else {
      exps[at] = add([exps[at], exp]);
    }
  }
  final factors = <Expr>[];
  for (var i = 0; i < bases.length; i++) {
    final f = pow(bases[i], exps[i]);
    if (f is Num) {
      product *= f.v;
    } else if (f is Mul) {
      factors.addAll(f.factors);
    } else {
      factors.add(f);
    }
  }
  if (product.abs() < _eps) return const Num(0);
  if ((product - 1).abs() > _eps) factors.insert(0, Num(product));
  if (factors.isEmpty) return const Num(1);
  return factors.length == 1 ? factors.first : Mul(factors);
}

/// A function application; folds the obvious ones (`\ln 1`, `\cos 0`, `\ln e`).
Expr fn(String name, Expr arg) {
  if (name == r'\ln' && arg is Sym && arg.constant && arg.name == 'e') return const Num(1);
  if (arg is Num && name != r'\abs') {
    final r = evaluate(Fn(name, arg), const {});
    if (r.isFinite && ratOf(r)?.$2 == 1) return Num(r);
  }
  return Fn(name, arg);
}

Expr neg(Expr e) => mul([const Num(-1), e]);
Expr sub(Expr a, Expr b) => add([a, neg(b)]);
Expr div(Expr a, Expr b) => mul([a, pow(b, const Num(-1))]);

Expr pow(Expr b, Expr e) {
  if (isNum(e, 1)) return b;
  if (isNum(e, 0)) return const Num(1);
  if (b is Num && e is Num) {
    final r = math.pow(b.v, e.v).toDouble();
    // only fold what stays exact: 4^0.5 -> 2, but keep 5^0.5 as a root
    if (r.isFinite && (e.v == e.v.roundToDouble() || ratOf(r)?.$2 == 1)) return Num(r);
  }
  // (a b)^n = a^n b^n and (a^m)^n = a^(m n) for whole n
  if (e is Num && e.v == e.v.roundToDouble()) {
    if (b is Mul) return mul(b.factors.map((f) => pow(f, e)));
    if (b is Pow) return pow(b.base, mul([b.exp, e]));
  }
  return Pow(b, e);
}

// ---- inspection ----

bool contains(Expr e, String v) => switch (e) {
      Num() => false,
      Sym s => !s.constant && s.name == v,
      Add a => a.terms.any((t) => contains(t, v)),
      Mul m => m.factors.any((t) => contains(t, v)),
      Pow p => contains(p.base, v) || contains(p.exp, v),
      Fn f => contains(f.arg, v),
      Series r => contains(r.from, v) || contains(r.to, v) || (r.variable != v && contains(r.body, v)),
      Call c => c.args.any((a) => contains(a, v)),
    };

/// The letters that can be solved for, in order of appearance.
List<String> freeVariables(Expr e) {
  final seen = <String>[];
  void walk(Expr e) {
    switch (e) {
      case Num():
        break;
      case Sym s:
        if (!s.constant && !seen.contains(s.name)) seen.add(s.name);
      case Add a:
        a.terms.forEach(walk);
      case Mul m:
        m.factors.forEach(walk);
      case Pow p:
        walk(p.base);
        walk(p.exp);
      case Fn f:
        walk(f.arg);
      case Series r:
        walk(r.from);
        walk(r.to);
        // (the counting letter belongs to the sum: it is not a letter of the whole)
        final inner = freeVariables(r.body).where((v) => v != r.variable && !isIndexedBy(v, r.variable));
        for (final v in inner) {
          if (!seen.contains(v)) seen.add(v);
        }
      case Call c:
        if (statNames.contains(c.name)) {
          // (the random variables and events inside belong to the function; what it depends on is the other letters and the space)
          for (final a in c.args) {
            for (final v in freeVariables(a)) {
              if (!isRandomLetter(v) && !seen.contains(v)) seen.add(v);
            }
          }
          if (!seen.contains(modelName)) seen.add(modelName);
        } else {
          c.args.forEach(walk);
        }
    }
  }

  walk(e);
  return seen;
}

/// The letters that have to be whole numbers for [e] to be worked out: the ones in the limits of a sum or product and in a
/// factorial.
Set<String> wholeNumberLetters(Expr e) {
  final out = <String>{};
  void walk(Expr e) {
    switch (e) {
      case Num() || Sym():
        break;
      case Add a:
        a.terms.forEach(walk);
      case Mul m:
        m.factors.forEach(walk);
      case Pow p:
        walk(p.base);
        walk(p.exp);
      case Fn f:
        if (f.name == factorialName) out.addAll(freeVariables(f.arg));
        // (`\lfloor n/2 \rfloor`: n, i, k ... are counts by custom; `\lfloor x \rfloor` is for any number)
        if (f.name == floorName || f.name == ceilName) out.addAll(freeVariables(f.arg).where(_countLike.hasMatch));
        walk(f.arg);
      case Call c:
        if (statNames.contains(c.name)) out.add(modelName);
        if (c.name == callMod || c.name == r'\gcd' || c.name == r'\lcm') {
          for (final a in c.args) {
            out.addAll(freeVariables(a));
          }
        }
        c.args.forEach(walk);
      case Series r:
        out.addAll(freeVariables(r.from));
        out.addAll(freeVariables(r.to));
        walk(r.from);
        walk(r.to);
        walk(r.body);
    }
  }

  walk(e);
  return out;
}

/// The letters people count with.
final _countLike = RegExp(r'^[i-nN](?:_.*)?$');

/// Whether [e] has a sum, a product or a factorial of something that is not a number in it: what a claim such as
/// `\sum_{k=1}^{n} k = \frac{n(n+1)}{2}` is made of.
bool isDiscrete(Expr e) => switch (e) {
      Num() || Sym() => false,
      Add a => a.terms.any(isDiscrete),
      Mul m => m.factors.any(isDiscrete),
      Pow p => isDiscrete(p.base) || isDiscrete(p.exp),
      // (`\lfloor n/2 \rfloor = n` is a claim about counts; `\lfloor x \rfloor = x` may as well ask for the x it holds for)
      Fn f => f.name == factorialName || (f.name == floorName || f.name == ceilName) && freeVariables(f.arg).any(_countLike.hasMatch) || isDiscrete(f.arg),
      Series() => true,
      Call c => statNames.contains(c.name) || c.name != r'\min' && c.name != r'\max' || c.args.any(isDiscrete),
    };

/// The parts of an indexed letter such as `x_{i}`, `x_{i+1}`, `x_{3}`: what is indexed and what the subscript is.
final _indexed = RegExp(r'^([^_{}]+)_\{\s*(?:([a-zA-Z])\s*(?:([+-])\s*(\d+))?|(\d+))\s*\}$');

/// Whether [name] is a letter indexed by [variable] (`x_{i}`, `y_{i-1}` for `i`): the i-th value of a sum's body.
bool isIndexedBy(String name, String variable) => _indexed.firstMatch(name)?.group(2) == variable;

/// The value of the indexed letter [name] (`x_{i}`) when its subscript is a letter in [env] or a number: the number the letter itself was
/// given when there is one (`x_{2}` as a letter of its own), else the k-th value of the data the letter stands for ([dataValue]).
double _indexedValue(String name, Map<String, double> env) {
  final m = _indexed.firstMatch(name);
  if (m == null) return double.nan;
  double k;
  if (m.group(2) != null) {
    final i = env[m.group(2)!];
    if (i == null || !i.isFinite || i != i.roundToDouble()) return double.nan;
    k = i + (m.group(4) == null ? 0 : (m.group(3) == '-' ? -1 : 1) * int.parse(m.group(4)!));
  } else {
    k = double.parse(m.group(5)!);
  }
  if (k != k.roundToDouble() || k.abs() > 1e6) return double.nan;
  final base = m.group(1)!;
  return env['${base}_{${k.toInt()}}'] ?? dataValue(base, k.toInt());
}

/// The k-th value of the data that the letter [base] stands for in a sum (`x_1, x_2, ...`): made up, but always the same ones, so that
/// the two sides of a formula about them are worked out with the same data.
double dataValue(String base, int k) {
  var h = 7;
  for (final c in '$base#$k'.codeUnits) {
    h = (h * 31 + c) % 1000003;
  }
  return math.Random(h).nextDouble() * 10 - 2;
}

/// [n]! for a whole number, NaN for anything else.
double factorialOf(double n) {
  if (!n.isFinite || n < 0 || n > 170 || n != n.roundToDouble()) return double.nan;
  var r = 1.0;
  for (var k = 2; k <= n; k++) {
    r *= k;
  }
  return r;
}

double evaluate(Expr e, Map<String, double> env) {
  switch (e) {
    case Num n:
      return n.v;
    case Sym s:
      if (s.constant) return s.name == r'\pi' ? math.pi : math.e;
      return env[s.name] ?? _indexedValue(s.name, env);
    case Add a:
      return a.terms.fold(0.0, (t, x) => t + evaluate(x, env));
    case Mul m:
      return m.factors.fold(1.0, (t, x) => t * evaluate(x, env));
    case Pow p:
      return math.pow(evaluate(p.base, env), evaluate(p.exp, env)).toDouble();
    case Fn f:
      final x = evaluate(f.arg, env);
      return switch (f.name) {
        r'\sin' => math.sin(x),
        r'\cos' => math.cos(x),
        r'\tan' => math.tan(x),
        r'\sinh' => (math.exp(x) - math.exp(-x)) / 2,
        r'\cosh' => (math.exp(x) + math.exp(-x)) / 2,
        r'\tanh' => x > 20 ? 1.0 : (x < -20 ? -1.0 : (math.exp(2 * x) - 1) / (math.exp(2 * x) + 1)),
        r'\ln' => math.log(x),
        r'\log' => math.log(x) / math.ln10,
        r'\exp' => math.exp(x),
        r'\arcsin' => math.asin(x),
        r'\arccos' => math.acos(x),
        r'\arctan' => math.atan(x),
        r'\abs' => x.abs(),
        normalCdfName => normalCdf(x),
        factorialName => factorialOf(x),
        floorName => x.floorToDouble(),
        ceilName => x.ceilToDouble(),
        _ => double.nan,
      };
    case Series r:
      final from = evaluate(r.from, env), to = evaluate(r.to, env);
      if (!from.isFinite || !to.isFinite || from != from.roundToDouble() || to != to.roundToDouble()) return double.nan;
      if (to - from > largestSeries) return double.nan;
      var total = r.sum ? 0.0 : 1.0;
      // (`x_{i}` in the body is the i-th value, not a letter that was given a number)
      final inner = {...env}..removeWhere((name, _) => isIndexedBy(name, r.variable));
      for (var k = from; k <= to; k++) {
        inner[r.variable] = k;
        final y = evaluate(r.body, inner);
        total = r.sum ? total + y : total * y;
      }
      return total;
    case Call c:
      if (statNames.contains(c.name)) return _evaluateStat(c, env);
      final xs = [for (final a in c.args) evaluate(a, env)];
      if (xs.any((x) => !x.isFinite)) return double.nan;
      return switch (c.name) {
        r'\cup' => xs.reduce(math.max),
        r'\cap' => xs.reduce(math.min),
        '\\cmp<' => xs[0] < xs[1] ? 1 : 0,
        '\\cmp>' => xs[0] > xs[1] ? 1 : 0,
        '\\cmp<=' => xs[0] <= xs[1] ? 1 : 0,
        '\\cmp>=' => xs[0] >= xs[1] ? 1 : 0,
        '\\cmp=' => (xs[0] - xs[1]).abs() < 1e-9 ? 1 : 0,
        '\\cmp!=' => (xs[0] - xs[1]).abs() < 1e-9 ? 0 : 1,
        callMod => xs.length == 2 && xs[1] > 0 ? xs[0] - xs[1] * (xs[0] / xs[1]).floorToDouble() : double.nan,
        r'\gcd' => _wholeFold(xs, _gcd),
        r'\lcm' => _wholeFold(xs, (a, b) => a == 0 || b == 0 ? 0 : a ~/ _gcd(a, b) * b),
        r'\min' => xs.reduce(math.min),
        r'\max' => xs.reduce(math.max),
        _ => double.nan,
      };
  }
}

int _gcd(int a, int b) {
  a = a.abs();
  b = b.abs();
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  return a;
}

double _wholeFold(List<double> xs, int Function(int, int) f) {
  if (xs.any((x) => x != x.roundToDouble() || x.abs() > 1e12)) return double.nan;
  return xs.map((x) => x.toInt()).reduce(f).toDouble();
}

// ---- polynomials in one letter, coefficients are expressions ----

/// Coefficients of [e] as a polynomial in [v] (index = power), or null when it
/// is not one. The other letters stay inside the coefficients.
List<Expr>? polynomial(Expr e, String v) {
  if (!contains(e, v)) return _trim([e]);
  switch (e) {
    case Sym():
      return const [Num(0), Num(1)];
    case Add a:
      var sum = <Expr>[const Num(0)];
      for (final t in a.terms) {
        final p = polynomial(t, v);
        if (p == null) return null;
        sum = _plus(sum, p);
      }
      return _trim(sum);
    case Mul m:
      var product = <Expr>[const Num(1)];
      for (final f in m.factors) {
        final p = polynomial(f, v);
        if (p == null) return null;
        product = _times(product, p);
      }
      return _trim(product);
    case Pow p:
      final n = p.exp;
      if (contains(p.exp, v) || n is! Num || n.v < 0 || n.v != n.v.roundToDouble() || n.v > 8) return null;
      final base = polynomial(p.base, v);
      if (base == null) return null;
      var result = <Expr>[const Num(1)];
      for (var i = 0; i < n.v; i++) {
        result = _times(result, base);
      }
      return _trim(result);
    default:
      return null;
  }
}

List<Expr> _plus(List<Expr> a, List<Expr> b) =>
    [for (var i = 0; i < math.max(a.length, b.length); i++) add([if (i < a.length) a[i], if (i < b.length) b[i]])];

List<Expr> _times(List<Expr> a, List<Expr> b) {
  final out = List<Expr>.filled(a.length + b.length - 1, const Num(0));
  for (var i = 0; i < a.length; i++) {
    for (var j = 0; j < b.length; j++) {
      out[i + j] = add([out[i + j], mul([a[i], b[j]])]);
    }
  }
  return out;
}

List<Expr> _trim(List<Expr> p) {
  final out = List.of(p);
  while (out.isNotEmpty && isNum(out.last, 0)) {
    out.removeLast();
  }
  return out;
}

// ---- LaTeX output ----

String numberTex(double d) {
  final r = ratOf(d);
  if (r == null) {
    var s = d.toStringAsPrecision(6);
    if (s.contains('.') && !s.contains('e')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s;
  }
  final (p, q) = r;
  if (q == 1) return '$p';
  return '${p < 0 ? '-' : ''}\\frac{${p.abs()}}{$q}';
}

String latexOf(Expr e) => switch (e) {
      Num n => numberTex(n.v),
      Sym s => s.name,
      Add a => _addTex(a),
      Mul m => _signedMul(m).$1 ? '-${_signedMul(m).$2}' : _signedMul(m).$2,
      Pow p => _powTex(p),
      Series r => '${r.sum ? r'\sum' : r'\prod'}_{${r.variable}=${latexOf(r.from)}}^{${latexOf(r.to)}}${r.body is Add ? '\\left(${latexOf(r.body)}\\right)' : latexOf(r.body)}',
      Call c when c.name == callE => 'E\\left[${latexOf(c.args[0])}\\right]',
      Call c when c.name == callVar => '\\operatorname{Var}\\left(${latexOf(c.args[0])}\\right)',
      Call c when c.name == callCov => '\\operatorname{Cov}\\left(${latexOf(c.args[0])}, ${latexOf(c.args[1])}\\right)',
      Call c when c.name == callP => 'P\\left(${latexOf(c.args[0])}\\right)',
      Call c when c.name == callPGiven => 'P\\left(${latexOf(c.args[0])} \\mid ${latexOf(c.args[1])}\\right)',
      Call c when c.name == r'\cup' || c.name == r'\cap' => '${latexOf(c.args[0])} ${c.name} ${latexOf(c.args[1])}',
      Call c when c.name.startsWith('\\cmp') => '${latexOf(c.args[0])} ${const {'<': '<', '>': '>', '<=': r'\leq', '>=': r'\geq', '=': '=', '!=': r'\neq'}[c.name.substring(4)]} ${latexOf(c.args[1])}',
      Call c when c.name == callMod => '${_wrapSum(c.args[0])} \\bmod ${_wrapSum(c.args[1])}',
      Call c => '${c.name}\\left(${c.args.map(latexOf).join(', ')}\\right)',
      Fn f when f.name == floorName => '\\left\\lfloor ${latexOf(f.arg)} \\right\\rfloor',
      Fn f when f.name == ceilName => '\\left\\lceil ${latexOf(f.arg)} \\right\\rceil',
      Fn f when f.name == factorialName => f.arg is Sym || (f.arg is Num && (f.arg as Num).v >= 0) ? '${latexOf(f.arg)}!' : '\\left(${latexOf(f.arg)}\\right)!',
      Fn f => f.name == r'\abs'
          ? '\\left|${latexOf(f.arg)}\\right|'
          : f.arg is Fn && (f.arg as Fn).name == r'\abs'
              ? '${f.name}${latexOf(f.arg)}'
              : '${f.name}\\left(${latexOf(f.arg)}\\right)',
    };

String _wrapSum(Expr e) => e is Add || e is Mul && e.factors.length > 1 && e.factors.first is Num && (e.factors.first as Num).v < 0 ? '\\left(${latexOf(e)}\\right)' : latexOf(e);

(bool, String) _signedTerm(Expr t) {
  if (t is Num) return (t.v < 0, numberTex(t.v.abs()));
  if (t is Mul) return _signedMul(t);
  return (false, latexOf(t));
}

String _addTex(Add a) {
  final sb = StringBuffer();
  for (var i = 0; i < a.terms.length; i++) {
    final (negative, body) = _signedTerm(a.terms[i]);
    if (i == 0) {
      if (negative) sb.write('-');
    } else {
      sb.write(negative ? ' - ' : ' + ');
    }
    sb.write(body);
  }
  return sb.toString();
}

(bool, String) _signedMul(Mul m) {
  var coefficient = 1.0;
  final numer = <Expr>[];
  final denom = <Expr>[];
  for (final f in m.factors) {
    if (f is Num) {
      coefficient *= f.v;
    } else if (f is Pow && f.exp is Num && (f.exp as Num).v < 0) {
      denom.add(pow(f.base, Num(-(f.exp as Num).v)));
    } else {
      numer.add(f);
    }
  }
  // letters first, then powers, constants' powers, functions, sums
  int rank(Expr f) => switch (f) {
        Sym() => 0,
        Pow(base: Sym(constant: false)) => 1,
        Pow() => 2,
        Fn() => 3,
        _ => 4,
      };
  numer.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 || a is! Sym || b is! Sym ? byRank : (a).name.compareTo((b).name);
  });
  final negative = coefficient < 0;
  final c = coefficient.abs();
  final r = ratOf(c);
  var top = <String>[], bottom = <String>[];
  final fraction = denom.isNotEmpty || (r != null && r.$2 != 1);
  String part(Expr f, int count, [bool top = false]) => f is Add && (count > 1 || (top && negative && !fraction)) ? '\\left(${latexOf(f)}\\right)' : latexOf(f);
  String? lead, trail;
  if (r == null) {
    lead = numberTex(c);
  } else {
    if (r.$2 != 1) trail = '${r.$2}';
    if (r.$1 != 1 || numer.isEmpty) lead = '${r.$1}';
  }
  final topCount = numer.length + (lead != null ? 1 : 0);
  final bottomCount = denom.length + (trail != null ? 1 : 0);
  top = [?lead, for (final f in numer) part(f, topCount, true)];
  bottom = [?trail, for (final f in denom) part(f, bottomCount)];
  if (bottom.isEmpty) return (negative, _joinFactors(top));
  return (negative, '\\frac{${_joinFactors(top)}}{${_joinFactors(bottom)}}');
}

String _joinFactors(List<String> parts) {
  final sb = StringBuffer();
  for (final part in parts) {
    if (sb.isNotEmpty) {
      final prev = sb.toString();
      if (RegExp(r'\d$').hasMatch(prev) && RegExp(r'^\d').hasMatch(part)) {
        sb.write(r' \cdot ');
      } else if (RegExp(r'\\[a-zA-Z]+$').hasMatch(prev) && RegExp(r'^[a-zA-Z]').hasMatch(part)) {
        sb.write(' ');
      }
    }
    sb.write(part);
  }
  return sb.toString();
}

String _powTex(Pow p) {
  final x = p.exp;
  if (x is Num) {
    if (x.v < 0) return '\\frac{1}{${latexOf(pow(p.base, Num(-x.v)))}}';
    final r = ratOf(x.v);
    if (r != null && r.$1 == 1 && r.$2 >= 2) {
      return r.$2 == 2 ? '\\sqrt{${latexOf(p.base)}}' : '\\sqrt[${r.$2}]{${latexOf(p.base)}}';
    }
  }
  final b = p.base;
  final wrap = b is Add || b is Mul || b is Pow || b is Fn || (b is Num && (b.v < 0 || ratOf(b.v)?.$2 != 1));
  final base = wrap ? '\\left(${latexOf(b)}\\right)' : latexOf(b);
  return '$base^{${latexOf(x)}}';
}
