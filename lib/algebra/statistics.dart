part of 'expr.dart';

// Expectation, variance, covariance and probability, as they are written in a statistics course: `E[2X + 1]`, `\operatorname{Var}(X)`,
// `\operatorname{Cov}(X, Y)`, `P(A \cup B)`, `P(A \mid B)`. They are [Call]s with the names below.
//
// The random variables (`X`, `Y`, ...) and the events (`A` to `H`) are not numbers: they are worked out on a small made-up probability
// space, where each of them has a value in each outcome. An identity that holds for every random variable holds there (`\operatorname{Var}(X) =
// E[X^2] - E[X]^2`), and one that does not almost never does. What only holds when the variables are independent (`E[XY] = E[X]E[Y]`) or
// the events cannot happen together (`P(A \cup B) = P(A) + P(B)`) is something a note often says in words: so there are three kinds of space,
// and the checker only calls a formula wrong when it fails in all of them.

/// The expectation of one expression.
const callE = r'\E';
const callVar = r'\Var';
const callCov = r'\Cov';

/// The probability of an event (an expression that is 1 where it happens and 0 where it does not).
const callP = r'\P';

/// The probability of the first event given the second.
const callPGiven = r'\Pc';

/// The statistics functions: they stand for numbers that do not depend on the letters inside of them.
const statNames = {callE, callVar, callCov, callP, callPGiven};

/// The union and the intersection of events (the larger and the smaller of two indicators), and a comparison of two numbers as an event
/// (`X \le 2`): 1 where it is true, else 0. They are only worked out inside of [statNames].
const eventNames = {r'\cup', r'\cap', '\\cmp<', '\\cmp>', '\\cmp<=', '\\cmp>=', '\\cmp=', '\\cmp!='};

/// A hidden letter that picks the space (and which of its three kinds) a statistics function is worked out on: sampled like any other
/// letter, and whole.
const modelName = '‹model›';

/// How many kinds of space there are: for the seed `s` the kind is `s % 3` (0: any, 1: independent, 2: events that cannot happen together).
const modelKinds = 3;

/// Whether [name] is a random variable or an event: a capital letter, with or without a subscript.
bool isRandomLetter(String name) => _randomLetter.hasMatch(name);
final _randomLetter = RegExp(r'^[A-Z](?:_.*)?$');

/// Events are the letters A to H: they are 1 or 0 in an outcome; the other letters are whole numbers from 0 to 5.
bool isEventLetter(String name) => RegExp(r'^[A-H](?:_.*)?$').hasMatch(name);

/// Whether [e] has a call named one of [names] in it.
bool usesCall(Expr e, Set<String> names) => switch (e) {
      Num() || Sym() => false,
      Add a => a.terms.any((t) => usesCall(t, names)),
      Mul m => m.factors.any((t) => usesCall(t, names)),
      Pow p => usesCall(p.base, names) || usesCall(p.exp, names),
      Fn f => usesCall(f.arg, names),
      Series r => usesCall(r.from, names) || usesCall(r.to, names) || usesCall(r.body, names),
      Call c => names.contains(c.name) || c.args.any((a) => usesCall(a, names)),
    };

/// Whether [e] has a statistics function in it.
bool containsStat(Expr e) => switch (e) {
      Num() || Sym() => false,
      Add a => a.terms.any(containsStat),
      Mul m => m.factors.any(containsStat),
      Pow p => containsStat(p.base) || containsStat(p.exp),
      Fn f => containsStat(f.arg),
      Series r => containsStat(r.from) || containsStat(r.to) || containsStat(r.body),
      Call c => statNames.contains(c.name) || c.args.any(containsStat),
    };

class _Space {
  final List<double> weights;
  final Map<String, List<double>> values;
  _Space(this.weights, this.values);
}

final _spaces = <String, _Space>{};

int _spaceHash(String s) {
  var h = 11;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) % 1000003;
  }
  return h;
}

double _draw(String key) => math.Random(_spaceHash(key)).nextDouble();

double _valueOf(String letter, double u) => isEventLetter(letter) ? (u < 0.5 ? 1 : 0) : (u * 6).floorToDouble();

/// The space for [letters] of the kind that [seed] says: the weights of its outcomes and the value of each letter in each of them.
_Space _spaceFor(int seed, List<String> letters) {
  final key = '$seed|${letters.join(',')}';
  final known = _spaces[key];
  if (known != null) return known;
  if (_spaces.length > 400) _spaces.clear();
  final kind = seed % modelKinds;
  late final _Space space;
  if (kind == 1) {
    // independent: every letter has outcomes of its own (three), and the space is all combinations of them
    final perLetter = <String, (List<double>, List<double>)>{};
    for (final l in letters) {
      final w = [for (var j = 0; j < 3; j++) 0.3 + _draw('$seed|$l|w$j')];
      final total = w.fold(0.0, (a, b) => a + b);
      final v = [for (var j = 0; j < 3; j++) _valueOf(l, _draw('$seed|$l|v$j'))];
      if (v.every((x) => x == v.first)) v[0] = isEventLetter(l) ? 1 - v[0] : v[0] + 1;
      perLetter[l] = ([for (final x in w) x / total], v);
    }
    final size = math.pow(3, letters.length).toInt();
    final weights = List<double>.filled(size, 1);
    final values = {for (final l in letters) l: List<double>.filled(size, 0)};
    for (var o = 0; o < size; o++) {
      var rest = o;
      for (final l in letters) {
        final c = rest % 3;
        rest ~/= 3;
        weights[o] *= perLetter[l]!.$1[c];
        values[l]![o] = perLetter[l]!.$2[c];
      }
    }
    space = _Space(weights, values);
  } else {
    // (kind 2 has more outcomes: each event gets some of its own)
    final size = kind == 2 ? 24 : 8;
    final raw = [for (var o = 0; o < size; o++) 0.3 + _draw('$seed|w$o')];
    final total = raw.fold(0.0, (a, b) => a + b);
    final values = <String, List<double>>{};
    for (final l in letters) {
      if (kind == 2 && isEventLetter(l)) {
        // events that cannot happen together: each outcome belongs to one event at most (the first ones to A, B, ...)
        final id = l.length == 1 ? l.codeUnitAt(0) - 65 : 8 + _spaceHash(l) % 8;
        values[l] = [for (var o = 0; o < size; o++) o < 16 && o == id ? 1.0 : 0.0];
      } else {
        values[l] = [for (var o = 0; o < size; o++) _valueOf(l, _draw('$seed|$l|$o'))];
      }
      final v = values[l]!;
      if (v.every((x) => x == v.first)) v[0] = isEventLetter(l) ? 1 - v[0] : v[0] + 1;
    }
    space = _Space([for (final x in raw) x / total], values);
  }
  return _spaces[key] = space;
}

/// The value of the statistics function [c] with the letters of [env] (and the space the hidden letter [modelName] says).
double _evaluateStat(Call c, Map<String, double> env) {
  final letters = <String>{
    for (final a in c.args) ...freeVariables(a).where(isRandomLetter),
  }.toList()
    ..sort();
  if (letters.length > 4) return double.nan;
  final seed = (env[modelName] ?? 1).round().abs();
  final space = _spaceFor(seed, letters);
  final n = space.weights.length;
  List<double> vector(Expr a) => [
        for (var o = 0; o < n; o++) evaluate(a, {...env, for (final l in letters) l: space.values[l]![o]}),
      ];
  double mean(List<double> v) {
    var t = 0.0;
    for (var o = 0; o < n; o++) {
      t += space.weights[o] * v[o];
    }
    return t;
  }

  switch (c.name) {
    case callE || callP:
      return mean(vector(c.args[0]));
    case callVar:
      final v = vector(c.args[0]);
      final m = mean(v);
      return mean([for (final x in v) (x - m) * (x - m)]);
    case callCov:
      final a = vector(c.args[0]), b = vector(c.args[1]);
      final ma = mean(a), mb = mean(b);
      return mean([for (var o = 0; o < n; o++) (a[o] - ma) * (b[o] - mb)]);
    case callPGiven:
      final a = vector(c.args[0]), b = vector(c.args[1]);
      final pb = mean(b);
      if (pb < 1e-9) return double.nan;
      return mean([for (var o = 0; o < n; o++) a[o] * b[o]]) / pb;
  }
  return double.nan;
}
