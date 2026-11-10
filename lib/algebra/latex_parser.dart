import 'calculus.dart' show replace;
import 'expr.dart';

/// Thrown for LaTeX the solver does not understand.
class ParseException implements Exception {
  final String message;
  ParseException(this.message);
  @override
  String toString() => message;
}

const _greek = {
  'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'varepsilon', 'zeta', 'eta', 'theta', 'vartheta', 'iota', 'kappa',
  'lambda', 'mu', 'nu', 'xi', 'rho', 'sigma', 'tau', 'upsilon', 'phi', 'varphi', 'chi', 'psi', 'omega',
  'Gamma', 'Delta', 'Theta', 'Lambda', 'Xi', 'Sigma', 'Phi', 'Psi', 'Omega',
};
const _functions = {'sin', 'cos', 'tan', 'sinh', 'cosh', 'tanh', 'ln', 'log', 'exp', 'arcsin', 'arccos', 'arctan'};
const _inverseOf = {'sin': 'arcsin', 'cos': 'arccos', 'tan': 'arctan'};
const _largestSum = 2000;
const _operators = {'cdot', 'times', 'div', 'pm', 'mp'};

/// Parses `left = right` written in LaTeX.
(Expr, Expr) parseEquation(String source) {
  final p = _Parser(source);
  final left = p.expression();
  p.expect('=');
  final right = p.expression();
  p.end();
  return (left, right);
}

/// Parses one side or a whole expression.
///
/// [euler]: a lone `e` is Euler's number (for the claimed value of a limit or an integral, where a letter makes no sense).
Expr parseExpression(String source, {bool euler = false}) {
  final p = _Parser(source, euler: euler);
  final e = p.expression();
  p.end();
  return e;
}

/// Whether [source] has an equals sign at the top level.
bool looksLikeEquation(String source) => source.contains('=') && !source.contains(RegExp(r'\\(neq|leq|geq|le|ge)\b'));

/// [raw] without dollar signs, sizing commands and thin spaces.
String cleanLatex(String raw) => normalizeLatex(raw)
    .replaceAll(r'$', '')
    .replaceAll(RegExp(r'\\(left|right|displaystyle|quad|qquad|limits|nolimits)(?![a-zA-Z])'), '')
    .replaceAll(RegExp(r'\\(lvert|rvert|vert)(?![a-zA-Z])'), '|')
    .replaceAll(RegExp(r'\\[,;:! ]'), ' ')
    .replaceAll(r'\{', '(')
    .replaceAll(r'\}', ')')
    .trim();

/// What a handwriting model (or a person) writes in other ways, as one: spaces around braces and after `\frac`, the signs
/// `× ÷ · − √ π ° ² ³`, `\mathrm{d}`, German decimal commas, `1{,}5`.
String normalizeLatex(String raw) {
  var s = raw
      .replaceAll('−', '-')
      .replaceAll('–', '-')
      .replaceAll('×', r' \times ')
      .replaceAll('÷', r' \div ')
      .replaceAll(RegExp('[·⋅∙]'), r' \cdot ')
      .replaceAll('π', r' \pi ')
      .replaceAll('°', r'^{\circ}')
      .replaceAll('⌊', r' \lfloor ')
      .replaceAll('⌋', r' \rfloor ')
      .replaceAll('⌈', r' \lceil ')
      .replaceAll('⌉', r' \rceil ')
      .replaceAll('²', '^2')
      .replaceAll('³', '^3')
      .replaceAllMapped(RegExp(r'√\s*(\d+(?:\.\d+)?|[a-zA-Z])'), (m) => '\\sqrt{${m[1]}}')
      .replaceAll('√', r'\sqrt')
      .replaceAllMapped(RegExp(r'\\(?:mathrm|operatorname|mathit|text)\{\s*([de])\s*\}'), (m) => m[1]!)
      .replaceAll('{,}', ',')
      // a dot after a bracket or a letter is a times dot written low (`2^{2}.3`, `x.y`), not a decimal point; one at the end is
      // a full stop
      .replaceAllMapped(RegExp(r'(?<=[})A-Za-z])\s*\.\s*(?=[\dA-Za-z(\\])'), (_) => r' \cdot ')
      .replaceAll(RegExp(r'\s*\.\s*$'), '')
      // (\div13 is \div 13)
      .replaceAllMapped(RegExp(r'(\\[A-Za-z]+)(?=\d)'), (m) => '${m[1]} ')
      // 12\frac{3}{11} is twelve and three elevenths (a whole number and a proper fraction of whole numbers)
      .replaceAllMapped(RegExp(r'(?<![\w.^_{}])(\d+)\s*\\d?frac\{(\d+)\}\{(\d+)\}'), (m) {
        final n = int.parse(m[2]!), d = int.parse(m[3]!);
        return n < d ? '(${m[1]}+\\frac{$n}{$d})' : m[0]!;
      })
      // sin, cos, ln ... written without the backslash (`\mathrm{sin}`, `lnx`, `cos(x)`)
      .replaceAllMapped(RegExp(r'\\(?:operatorname|mathrm|mathit|textrm)\{\s*(arcsin|arccos|arctan|sinh|cosh|tanh|sin|cos|tan|cot|sec|csc|ln|log|exp|lim|gcd|lcm|min|max|mod)\s*\}'), (m) => '\\${m[1]}')
      .replaceAllMapped(RegExp(r'(?<![\\A-Za-z])(arcsin|arccos|arctan|sinh|cosh|tanh|sin|cos|tan|cot|sec|csc|ln|log|exp|lim|gcd|lcm|min|max|mod)(?![A-Za-z])'), (m) => '\\${m[1]}')
      .replaceAllMapped(RegExp(r'(?<![\\A-Za-z])(sin|cos|tan|ln|log|exp)([a-zA-Z])(?![A-Za-z])'), (m) => '\\${m[1]} ${m[2]}')
      // \mathrm{x}, \mathrm{ d x }: the letters
      .replaceAllMapped(RegExp(r'\\(?:mathrm|mathit)\{\s*([A-Za-z0-9 ]+?)\s*\}'), (m) => m[1]!.replaceAll(' ', ''))
      // Var, Cov, Pr, and the E and P of the expectation and the probability (`\mathbb{E}[X]`, `\operatorname{Var}(X)`, `\text{Cov}`)
      .replaceAllMapped(RegExp(r'\\(?:operatorname|text|textrm|mathbb)\{\s*(Var|Cov|Pr)\s*\}'), (m) => '\\${m[1]}')
      .replaceAllMapped(RegExp(r'\\(?:operatorname|text|textrm|mathbb)\{\s*([EP])\s*\}'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'(?<![A-Za-z\\])(Var|Cov|Pr)(?![A-Za-z])'), (m) => '\\${m[1]}')
      .replaceAllMapped(RegExp(r'(\\(?:[dt]?frac|sqrt|binom|mathrm|operatorname))\s+(?=[{\[])'), (m) => m[1]!)
      .replaceAll(RegExp(r'\}\s+\{'), '}{')
      .replaceAll(RegExp(r'\{\s+'), '{')
      .replaceAll(RegExp(r'\s+\}'), '}');
  return _decimalCommas(s);
}

/// `1,5` is one and a half (not two numbers) when the comma is outside of brackets, has a digit on both sides and is not
/// followed by exactly three digits (`1,000`).
String _decimalCommas(String s) {
  if (!s.contains(',')) return s;
  final sb = StringBuffer();
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if (c == ',' && depth <= 0 && i > 0 && i + 1 < s.length && RegExp(r'\d').hasMatch(s[i - 1])) {
      final after = RegExp(r'^\d+').stringMatch(s.substring(i + 1));
      if (after != null && after.length != 3) {
        sb.write('.');
        continue;
      }
    }
    sb.write(c);
  }
  return sb.toString();
}

/// The letters whose mean is written with a bar (`\bar{x}`) in the lines being checked, next to their values (`x_i`), each with the
/// letter of the number of values: there the bar is the mean of `x_1 ... x_n` (so that `\sum (x_i - \bar{x})^2` can be worked out),
/// elsewhere it is a letter with a bar. Set by [withSampleMeans].
Map<String, String> _means = const {};

/// Runs [body] with the letters of [lines] that have a mean written (see [_means]).
T withSampleMeans<T>(Iterable<String?> lines, T Function() body) {
  final text = [for (final l in lines) if (l != null) cleanLatex(l)].join('\n');
  final found = <String, String>{};
  final size = RegExp(r'\\sum\s*_\s*\{\s*[A-Za-z]\s*=\s*1\s*\}\s*\^\s*\{?\s*([A-Za-z])(?![A-Za-z])').firstMatch(text)?.group(1) ?? 'n';
  for (final m in RegExp(r'\\(?:bar|overline)\s*\{?\s*([A-Za-z])\s*\}?').allMatches(text)) {
    final letter = m.group(1)!;
    if (RegExp('(?<![A-Za-z\\\\])$letter\\s*_').hasMatch(text)) found[letter] = size;
  }
  if (found.isEmpty) return body();
  final before = _means;
  _means = found;
  try {
    return body();
  } finally {
    _means = before;
  }
}

/// Whether what is in the brackets of an `E[...]` or a `P(...)` is random variables and events (a capital letter, or an operator of events),
/// not a function of a number (`P(x)`).
bool statisticalBrackets(String inner) {
  final bare = inner
      .replaceAll(RegExp(r'\\(?:cup|cap|setminus|mid|bar|overline|neg|lnot|leq|geq|le|ge|neq|ne|complement)(?![A-Za-z])'), ' ')
      .replaceAll(RegExp(r'\\[A-Za-z]+'), ' ');
  return RegExp(r'[A-Z]').hasMatch(bare) || RegExp(r'\\(?:cup|cap|mid)(?![A-Za-z])').hasMatch(inner);
}

class _Parser {
  final String s;
  int i = 0;

  /// How many `|...|` are open (a bar then closes one instead of starting a factor).
  int _bars = 0;

  _Parser(String raw, {bool euler = false}) : s = cleanLatex(raw), _euler = euler;

  final bool _euler;

  /// Whether `e^...` (or `\ln e`) is in the formula: then every `e` in it is Euler's number.
  late final bool _eulerInUse = _euler || RegExp(r'(?<![a-zA-Z\\])e\s*\^|\\ln\s*\(?\s*e(?![a-zA-Z])|\\log\s*_\s*\{?\s*e\s*\}?').hasMatch(s);

  String? get peek => i < s.length ? s[i] : null;

  void skipSpace() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
  }

  bool _is(String c) {
    skipSpace();
    return i < s.length && s[i] == c;
  }

  void expect(String c) {
    if (!_is(c)) throw ParseException(c == '=' ? 'There is no equals sign' : 'Expected "$c"');
    i++;
  }

  void end() {
    skipSpace();
    if (i < s.length) throw ParseException('Could not read "${s.substring(i)}"');
  }

  Expr expression() {
    var terms = <Expr>[term()];
    while (true) {
      skipSpace();
      if (peek == '+') {
        i++;
        terms.add(term());
      } else if (peek == '-') {
        i++;
        terms.add(neg(term()));
      } else if (peek == '\\' && (_commandAt(i) == 'bmod' || _commandAt(i) == 'mod')) {
        // `a + b \bmod m` is the sum taken mod m, as it is written in number theory
        i += _commandAt(i).length + 1;
        terms = [Call(callMod, [add(terms), term()])];
      } else {
        break;
      }
    }
    return add(terms);
  }

  Expr term() {
    skipSpace();
    var negative = false;
    while (peek == '-' || peek == '+') {
      if (peek == '-') negative = !negative;
      i++;
      skipSpace();
    }
    var left = power();
    while (true) {
      skipSpace();
      final c = peek;
      if (c == null) break;
      if (c == '*') {
        i++;
        left = mul([left, _operand()]);
      } else if (c == '/') {
        i++;
        left = div(left, _operand());
      } else if (c == '\\') {
        final name = _commandAt(i);
        if (name == 'cdot' || name == 'times') {
          i += name.length + 1;
          left = mul([left, _operand()]);
        } else if (name == 'div') {
          i += name.length + 1;
          left = div(left, _operand());
        } else if (_operators.contains(name) || !_startsFactor(c)) {
          break;
        } else {
          left = mul([left, power()]);
        }
      } else if (_startsFactor(c)) {
        left = mul([left, power()]);
      } else {
        break;
      }
    }
    return negative ? neg(left) : left;
  }

  /// What follows `\cdot` or `/`: a factor that may carry a sign (`2 \cdot -3`).
  Expr _operand() {
    skipSpace();
    var negative = false;
    while (peek == '-' || peek == '+') {
      if (peek == '-') negative = !negative;
      i++;
      skipSpace();
    }
    final p = power();
    return negative ? neg(p) : p;
  }

  bool _startsFactor(String c) {
    if (c == '\\') {
      final name = _commandAt(i);
      return name.isNotEmpty && !_operators.contains(name) && !const {'leq', 'geq', 'neq', 'le', 'ge', 'ne', 'rfloor', 'rceil', 'bmod', 'mod', 'pmod', 'equiv', 'cup', 'cap', 'setminus', 'mid'}.contains(name);
    }
    if (c == '|') return _bars == 0;
    return RegExp(r'[a-zA-Z0-9.({]').hasMatch(c);
  }

  String _commandAt(int at) {
    var j = at + 1;
    while (j < s.length && RegExp(r'[a-zA-Z]').hasMatch(s[j])) {
      j++;
    }
    return s.substring(at + 1, j);
  }

  Expr power() {
    var base = atom();
    while (peek == '!') {
      i++;
      base = _factorial(base);
    }
    // 20\% is 0.2
    if (s.startsWith(r'\%', i) || s.startsWith('%', i)) {
      i += s[i] == '%' ? 1 : 2;
      base = mul([base, const Num(0.01)]);
    }
    skipSpace();
    if (peek == '^') {
      i++;
      skipSpace();
      // 30^\circ is 30 degrees
      final degrees = RegExp(r'\{\s*\\circ\s*\}|\\circ').matchAsPrefix(s, i);
      if (degrees != null) {
        i = degrees.end;
        return mul([base, div(const Sym(r'\pi', constant: true), const Num(180))]);
      }
      return pow(base, exponent());
    }
    return base;
  }

  Expr _factorial(Expr e) {
    // (a letter or an expression stays a factorial to be worked out for whole numbers: `n!`, `(n+1)!`)
    if (e is! Num) return Fn(factorialName, e);
    final r = factorialOf(e.v);
    if (r.isNaN) throw ParseException('Only the factorial of a whole number is supported');
    return Num(r);
  }

  Expr exponent() {
    skipSpace();
    final c = peek;
    if (c == '{') return group();
    if (c == '-') {
      i++;
      return neg(exponent());
    }
    if (c != null && RegExp(r'\d').hasMatch(c)) {
      i++;
      return Num(double.parse(c));
    }
    return atom();
  }

  /// `{...}` or a single token, as after `\frac`.
  Expr group() {
    skipSpace();
    if (peek == '{') {
      i++;
      final e = expression();
      expect('}');
      return e;
    }
    final c = peek;
    if (c != null && RegExp(r'\d').hasMatch(c)) {
      i++;
      return Num(double.parse(c));
    }
    return atom();
  }

  Expr atom() {
    skipSpace();
    final c = peek;
    if (c == null) throw ParseException('The formula ends too early');
    if (RegExp(r'[0-9.]').hasMatch(c)) {
      final m = RegExp(r'\d*\.?\d+|\d+\.?').matchAsPrefix(s, i);
      if (m == null) throw ParseException('Could not read a number');
      i = m.end;
      return Num(double.parse(m.group(0)!));
    }
    if (c == '(' || c == '[') {
      i++;
      final e = expression();
      expect(c == '(' ? ')' : ']');
      return e;
    }
    if (c == '{') return group();
    if (c == '|') {
      i++;
      _bars++;
      final e = expression();
      _bars--;
      expect('|');
      return fn(r'\abs', e);
    }
    if (c == '\\') return _command();
    // E[X] and P(A): the expectation and the probability, when what is in the brackets looks like random variables and events
    if ((c == 'E' || c == 'P') && _statisticAhead()) {
      i++;
      return _statistic(c);
    }
    if (RegExp(r'[a-zA-Z]').hasMatch(c)) {
      i++;
      var name = c;
      var after = i;
      while (after < s.length && s[after] == ' ') {
        after++;
      }
      if (after < s.length && s[after] == '_') {
        i = after + 1;
        skipSpace();
        if (peek == '{') {
          final close = s.indexOf('}', i);
          if (close < 0) throw ParseException('Unclosed subscript');
          name = '${c}_{${s.substring(i + 1, close).trim()}}';
          i = close + 1;
        } else if (peek != null) {
          name = '${c}_{${s[i]}}';
          i++;
        }
      }
      // e is Euler's number only as in e^x
      return Sym(name, constant: name == 'e' && (peek == '^' || _eulerInUse));
    }
    throw ParseException('Could not read "$c"');
  }

  /// The index of the bracket that closes the one at [open], or -1.
  int _closing(int open) {
    var depth = 0;
    for (var j = open; j < s.length; j++) {
      if ('([{'.contains(s[j])) depth++;
      if (')]}'.contains(s[j]) && --depth == 0) return j;
    }
    return -1;
  }

  /// Whether the `E` or `P` at the cursor is an expectation or a probability: brackets follow, with a capital letter in them (the random
  /// variable or the event) or an operator of events. (`P(x)` is a function or a product.)
  bool _statisticAhead() {
    var j = i + 1;
    while (j < s.length && s[j] == ' ') {
      j++;
    }
    if (j >= s.length || (s[j] != '(' && s[j] != '[')) return false;
    final close = _closing(j);
    if (close < 0) return false;
    return statisticalBrackets(s.substring(j + 1, close));
  }

  /// [text] cut at the places where [separator] matches outside of brackets.
  List<String> _splitOutside(String text, RegExp separator) {
    final out = <String>[];
    var depth = 0, start = 0, j = 0;
    while (j < text.length) {
      final c = text[j];
      if ('([{'.contains(c)) {
        depth++;
      } else if (')]}'.contains(c)) {
        depth--;
      } else if (depth == 0) {
        final hit = separator.matchAsPrefix(text, j);
        if (hit != null && hit.end > hit.start) {
          out.add(text.substring(start, j));
          j = start = hit.end;
          continue;
        }
      }
      j++;
    }
    out.add(text.substring(start));
    return out;
  }

  Expr _inner(String text) {
    final p = _Parser(text, euler: _euler);
    final e = p.expression();
    p.end();
    return e;
  }

  Expr _eventIn(String text) {
    final p = _Parser(text, euler: _euler);
    final e = p._eventUnion();
    p.end();
    return e;
  }

  /// `E[2X+1]`, `\Var(X)`, `\Cov(X, Y)`, `P(A \cup B)`, `\Pr(A \mid B)`: the cursor is at the bracket.
  Expr _statistic(String name) {
    skipSpace();
    final open = peek;
    if (open != '(' && open != '[') throw ParseException('\\$name needs its brackets');
    final close = _closing(i);
    if (close < 0) throw ParseException('Unclosed bracket');
    final inner = s.substring(i + 1, close);
    i = close + 1;
    switch (name) {
      case 'E':
        return Call(callE, [_inner(inner)]);
      case 'Var':
        return Call(callVar, [_inner(inner)]);
      case 'Cov':
        final parts = _splitOutside(inner, RegExp(','));
        if (parts.length != 2) throw ParseException('Cov needs two random variables');
        return Call(callCov, [_inner(parts[0]), _inner(parts[1])]);
      default:
        final parts = _splitOutside(inner, RegExp(r'\|(?!\|)|\\mid(?![A-Za-z])'));
        if (parts.length == 1) return Call(callP, [_eventIn(parts[0])]);
        if (parts.length == 2) return Call(callPGiven, [_eventIn(parts[0]), _eventIn(parts[1])]);
        throw ParseException('A probability has one condition at most');
    }
  }

  bool _takeCommand(String name) {
    skipSpace();
    if (!s.startsWith('\\$name', i)) return false;
    final end = i + name.length + 1;
    if (end < s.length && RegExp(r'[A-Za-z]').hasMatch(s[end])) return false;
    i = end;
    return true;
  }

  /// An event: letters (A to H), comparisons (`X \le 2`) and `\cup`, `\cap`, `\setminus`, a complement (`A^c`, `A'`, `\bar{A}`). It is worked
  /// out as 1 where it happens and 0 where it does not.
  Expr _eventUnion() {
    var left = _eventIntersection();
    while (_takeCommand('cup') || _takeCommand('vee') || _takeCommand('lor')) {
      left = Call(r'\cup', [left, _eventIntersection()]);
    }
    return left;
  }

  Expr _eventIntersection() {
    var left = _eventAtom();
    while (true) {
      if (_takeCommand('cap') || _takeCommand('wedge') || _takeCommand('land')) {
        left = Call(r'\cap', [left, _eventAtom()]);
      } else if (_takeCommand('setminus')) {
        left = Call(r'\cap', [left, sub(const Num(1), _eventAtom())]);
      } else {
        return left;
      }
    }
  }

  Expr _eventAtom() {
    skipSpace();
    if (_takeCommand('bar') || _takeCommand('overline')) {
      final p = _Parser(_braced(), euler: _euler);
      final e = p._eventUnion();
      p.end();
      return sub(const Num(1), e);
    }
    if (_takeCommand('neg') || _takeCommand('lnot')) return sub(const Num(1), _eventAtom());
    Expr e;
    if (peek == '(') {
      final save = i;
      try {
        i++;
        e = _eventUnion();
        expect(')');
      } on ParseException {
        i = save;
        e = _comparison();
      }
    } else {
      e = _comparison();
    }
    // A^c, A^{c}, A'
    while (true) {
      final mark = RegExp(r"\s*(?:\^\s*\{?\s*(?:c|\\complement)\s*\}?|')").matchAsPrefix(s, i);
      if (mark == null) return e;
      i = mark.end;
      e = sub(const Num(1), e);
    }
  }

  final _eventLetter = RegExp(r'[A-Z](?:_\{[^{}]*\}|_[A-Za-z0-9])?');
  final _afterEvent = RegExp(r"^\s*(?:\^\s*\{?\s*(?:c|\\complement)\s*\}?|')?\s*(?:$|\)|\\(?:cup|cap|setminus|vee|wedge|lor|land)(?![A-Za-z]))");

  /// A letter that is an event, or a comparison of two numbers (an event as well).
  Expr _comparison() {
    skipSpace();
    final letter = _eventLetter.matchAsPrefix(s, i);
    if (letter != null && _afterEvent.hasMatch(s.substring(letter.end))) {
      final name = letter.group(0)!;
      if (!isEventLetter(name)) throw ParseException('$name is not an event');
      i = letter.end;
      return Sym(name);
    }
    final left = expression();
    skipSpace();
    String? op;
    for (final (text, value) in const [
      (r'\leq', '<='), (r'\le', '<='), (r'\geq', '>='), (r'\ge', '>='), (r'\neq', '!='), (r'\ne', '!='),
      ('≤', '<='), ('≥', '>='), ('≠', '!='), ('<=', '<='), ('>=', '>='), ('<', '<'), ('>', '>'), ('=', '='),
    ]) {
      if (!s.startsWith(text, i)) continue;
      final end = i + text.length;
      if (text.startsWith(r'\') && end < s.length && RegExp(r'[A-Za-z]').hasMatch(s[end])) continue;
      i = end;
      op = value;
      break;
    }
    if (op == null) throw ParseException('An event is a letter such as A or a comparison such as X \\le 2');
    return Call('\\cmp$op', [left, expression()]);
  }

  /// `\sum_{k=1}^{5} body` and `\prod`, with limits that are numbers: written out term by term.
  Expr _series(bool sum) {
    skipSpace();
    if (peek != '_') throw ParseException('A sum needs its limits');
    i++;
    final lower = _braced();
    skipSpace();
    if (peek != '^') throw ParseException('A sum needs its limits');
    i++;
    final upper = group();
    final eq = lower.indexOf('=');
    if (eq < 0) throw ParseException('A sum needs a start such as k=1');
    final name = lower.substring(0, eq).trim();
    final fromExpr = parseExpression(lower.substring(eq + 1));
    final variable = Sym(name);
    final from = freeVariables(fromExpr).isEmpty ? evaluate(fromExpr, const {}) : double.nan;
    final to = upper is Num ? upper.v : double.nan;
    final body = term();
    // (a sum of the values x_i stays a sum: they are looked up, not written out)
    if (from.isFinite && to.isFinite && !freeVariables(body).any((v) => isIndexedBy(v, name))) {
      if (from != from.roundToDouble() || to != to.roundToDouble()) throw ParseException('Only sums with whole number limits are supported');
      if (to - from > _largestSum) throw ParseException('That sum has too many terms');
      final parts = [for (var k = from; k <= to; k++) replace(body, variable, Num(k))];
      return sum ? add(parts) : mul(parts);
    }
    // a letter as a limit (`n`, `n+1`): kept as a sum to be worked out for whole numbers
    if (!RegExp(r'^[a-zA-Z](?:_\{[^{}]*\}|_[A-Za-z0-9])?$|^\\[a-zA-Z]+$').hasMatch(name)) throw ParseException('A sum needs a letter to count with');
    return Series(sum, name, fromExpr, upper, body);
  }

  /// `\gcd(a, b)`, `\min(a, b, c)`: the arguments in brackets, apart by commas.
  Expr _call(String name) {
    skipSpace();
    if (peek != '(') throw ParseException('$name needs its numbers in brackets');
    i++;
    final args = <Expr>[expression()];
    skipSpace();
    while (peek == ',') {
      i++;
      args.add(expression());
      skipSpace();
    }
    expect(')');
    if (args.length < 2) throw ParseException('$name needs two numbers');
    if (args.every((a) => a is Num)) {
      final v = evaluate(Call(name, args), const {});
      if (v.isFinite) return Num(v);
    }
    return Call(name, args);
  }

  /// The text inside `{...}` at the cursor (or the next single character).
  String _braced() {
    skipSpace();
    if (peek != '{') {
      final c = peek;
      if (c == null) throw ParseException('The formula ends too early');
      i++;
      return c;
    }
    var depth = 0;
    for (var j = i; j < s.length; j++) {
      if (s[j] == '{') depth++;
      if (s[j] == '}' && --depth == 0) {
        final inner = s.substring(i + 1, j);
        i = j + 1;
        return inner;
      }
    }
    throw ParseException('Unclosed bracket');
  }

  /// What a function is applied to when it is written without brackets: `\sin x`, `\sin 2x` (a number takes the letters
  /// that follow it: sin(2x)), `\sin 2\pi`; but not `\sin x \cos x`, which is two functions.
  Expr _argument() {
    skipSpace();
    if (peek == '(') return atom();
    final c = peek;
    final startsWithNumber = c != null && RegExp(r'[0-9.]').hasMatch(c);
    var arg = power();
    if (!startsWithNumber) return arg;
    while (true) {
      skipSpace();
      final next = peek;
      if (next == null) break;
      final isLetter = RegExp(r'[a-zA-Z(]').hasMatch(next);
      final isConstant = next == '\\' && (_commandAt(i) == 'pi' || _greek.contains(_commandAt(i)));
      if (!isLetter && !isConstant) break;
      arg = mul([arg, power()]);
    }
    return arg;
  }

  /// `\sin x`, `\sin^2 x`, `\sin^{-1} x`, `\log_2 x`, `\sec x` ...
  Expr _function(String name) {
    skipSpace();
    // \log_2 x
    Expr? base;
    if (name == 'log' && peek == '_') {
      i++;
      base = group();
      skipSpace();
    }
    // \sin^2 x is (\sin x)^2, and \sin^{-1} x is \arcsin x
    Expr? exponent;
    var fname = name;
    if (peek == '^') {
      i++;
      exponent = this.exponent();
      if (isNum(exponent, -1) && _inverseOf.containsKey(name)) {
        fname = _inverseOf[name]!;
        exponent = null;
      }
      skipSpace();
    }
    final arg = _argument();
    final Expr f = switch (fname) {
      'cot' => div(fn(r'\cos', arg), fn(r'\sin', arg)),
      'sec' => pow(fn(r'\cos', arg), const Num(-1)),
      'csc' => pow(fn(r'\sin', arg), const Num(-1)),
      _ when base != null => div(fn(r'\ln', arg), fn(r'\ln', base)),
      _ => fn('\\$fname', arg),
    };
    return exponent == null ? f : pow(f, exponent);
  }

  Expr _command() {
    final name = _commandAt(i);
    if (name.isEmpty) throw ParseException('Could not read "${s.substring(i)}"');
    i += name.length + 1;
    switch (name) {
      case 'frac' || 'dfrac' || 'tfrac':
        final a = group();
        final b = group();
        return div(a, b);
      case 'sqrt':
        skipSpace();
        Expr n = const Num(2);
        if (peek == '[') {
          i++;
          n = expression();
          expect(']');
        }
        return pow(group(), div(const Num(1), n));
      case 'pi':
        return const Sym(r'\pi', constant: true);
      case 'binom' || 'dbinom' || 'tbinom':
        final n = group(), k = group();
        if (n is! Num || k is! Num) {
          // n over k with a letter: n! / (k! (n-k)!), worked out for whole numbers
          return div(Fn(factorialName, n), mul([Fn(factorialName, k), Fn(factorialName, sub(n, k))]));
        }
        if (n.v != n.v.roundToDouble() || k.v != k.v.roundToDouble() || n.v < 0 || n.v > 170) {
          throw ParseException('Only the binomial coefficient of whole numbers is supported');
        }
        if (k.v < 0 || k.v > n.v) return const Num(0);
        var r = 1.0;
        for (var j = 1; j <= k.v; j++) {
          r = r * (n.v - k.v + j) / j;
        }
        return Num(r.roundToDouble());
      case 'sum' || 'prod':
        return _series(name == 'sum');
      case 'lfloor' || 'lceil':
        final inner = expression();
        skipSpace();
        final closing = name == 'lfloor' ? 'rfloor' : 'rceil';
        if (peek != '\\' || _commandAt(i) != closing) throw ParseException('Expected \\$closing');
        i += closing.length + 1;
        return fn(name == 'lfloor' ? floorName : ceilName, inner);
      case 'gcd' || 'lcm' || 'min' || 'max':
        return _call('\\$name');
      case 'Var' || 'Cov' || 'Pr':
        return _statistic(name);
      case 'bar' || 'overline':
        final inner = _braced().trim();
        // (the mean of the values x_1 ... x_n when a formula has both, as in the variance; else just a letter with a bar)
        final size = _means[inner];
        if (size != null) return div(Series(true, 'j', const Num(1), Sym(size), Sym('${inner}_{j}')), Sym(size));
        return Sym('\\bar{$inner}');
      case 'hat' || 'widehat' || 'tilde' || 'widetilde':
        return Sym('\\$name{${_braced().trim()}}');
      case 'cot' || 'sec' || 'csc':
        return _function(name);
    }
    // \Phi(1.96): the normal distribution function of a number (otherwise the letter, or an unknown function)
    if (name == 'Phi') {
      skipSpace();
      if (peek == '(') {
        final arg = atom();
        if (freeVariables(arg).isNotEmpty) throw ParseException('\\Phi is only worked out for a number');
        return fn(normalCdfName, arg);
      }
    }
    if (_greek.contains(name)) return Sym('\\$name');
    if (_functions.contains(name)) return _function(name);
    throw ParseException('\\$name is not supported');
  }
}

/// Evaluates [source] with the given letters (handy in tests).
double evalLatex(String source, [Map<String, double> env = const {}]) => evaluate(parseExpression(source), env);
