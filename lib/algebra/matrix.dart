import 'dart:math' as math;

import 'expr.dart';
import 'latex_parser.dart';

/// Matrices for the maths check: the ones written out in LaTeX (`\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}`) and what
/// is done with them: sums, products, a number times a matrix, `^T`, `^{-1}`, powers and `\det`. A matrix may have
/// letters in it (they are tried at several values, like everywhere in the checker) and a letter such as `A` can stand for
/// a matrix that was written before.

/// A matrix written out in LaTeX: what is between `\begin{...}` and `\end{...}`.
class MatrixLiteral {
  final String body;

  /// Between bars (`vmatrix`): its determinant.
  final bool determinant;
  const MatrixLiteral(this.body, {this.determinant = false});
}

const matrixOpen = '‹';
const matrixClose = '›';

/// What stands in the text of a line for its [i]th matrix literal, so that the `\\` and `&` in it are not taken for
/// the line breaks and alignment marks of the line.
String matrixMark(int i) => '$matrixOpen$i$matrixClose';

final _environment = RegExp(r'\\begin\{(array|[pbB]?matrix|vmatrix|smallmatrix)\}(?:\{[^{}]*\})?(.*?)\\end\{\1\}', dotAll: true);

/// [raw] with every matrix taken out, added to [into] and replaced by its mark.
String maskMatrices(String raw, List<MatrixLiteral> into) {
  return raw.replaceAllMapped(_environment, (m) {
    into.add(MatrixLiteral(m[2]!, determinant: m[1] == 'vmatrix'));
    return ' ${matrixMark(into.length - 1)} ';
  });
}

// ---- values ----

/// A matrix of numbers.
class Matrix {
  final List<List<double>> a;
  Matrix(this.a);

  int get rows => a.length;
  int get cols => a.first.length;
  bool get isSquare => rows == cols;

  static Matrix identity(int n) => Matrix([
        for (var i = 0; i < n; i++) [for (var j = 0; j < n; j++) i == j ? 1.0 : 0.0],
      ]);

  Matrix map(double Function(double) f) => Matrix([for (final r in a) [for (final x in r) f(x)]]);
  Matrix get transposed => Matrix([for (var j = 0; j < cols; j++) [for (var i = 0; i < rows; i++) a[i][j]]]);
}

/// `k` times an identity matrix whose size is not known yet (`I`, `2I`): it takes the size of what it meets.
class ScaledIdentity {
  final double k;
  const ScaledIdentity(this.k);
}

enum MatrixProblem {
  /// The sizes do not fit (adding a 2x2 and a 3x3, multiplying a 2x3 by a 2x3, the determinant of a 2x3).
  shape,

  /// The inverse of a matrix that has none.
  singular,

  /// Something that cannot be worked out (a letter that makes a division by zero, an identity matrix of unknown size).
  undefined,
}

class MatrixError implements Exception {
  final MatrixProblem problem;

  /// An example in LaTeX of what does not fit (`(2 \times 3)\,(2 \times 3)`).
  final String? tex;
  MatrixError(this.problem, [this.tex]);
  @override
  String toString() => 'MatrixError($problem)';
}

String _size(Matrix m) => '${m.rows} \\times ${m.cols}';

/// A value as LaTeX: a number, a `pmatrix`, or the identity.
String matrixTex(Object v) => switch (v) {
      double d => numberTex(d),
      Matrix m => '\\begin{pmatrix} ${m.a.map((r) => r.map(numberTex).join(' & ')).join(r' \\ ')} \\end{pmatrix}',
      ScaledIdentity i => i.k == 1 ? 'I' : '${numberTex(i.k)} I',
      _ => '',
    };

bool _near(double a, double b) => (a - b).abs() <= 1e-7 * math.max(1, math.max(a.abs(), b.abs()));

/// Whether two values (numbers, matrices, identities) are the same.
bool matrixEqual(Object x, Object y) {
  if (x is double && y is double) return _near(x, y);
  if (x is Matrix && y is Matrix) {
    if (x.rows != y.rows || x.cols != y.cols) return false;
    for (var i = 0; i < x.rows; i++) {
      for (var j = 0; j < x.cols; j++) {
        if (!_near(x.a[i][j], y.a[i][j])) return false;
      }
    }
    return true;
  }
  if (x is ScaledIdentity && y is ScaledIdentity) return _near(x.k, y.k);
  if (x is ScaledIdentity && y is Matrix) return matrixEqual(y, x);
  if (x is Matrix && y is ScaledIdentity) return x.isSquare && matrixEqual(x, Matrix.identity(x.rows).map((e) => e * y.k));
  return false;
}

// ---- expressions ----

sealed class MExpr {
  const MExpr();
}

/// A number or a formula in letters.
final class MScalar extends MExpr {
  final Expr e;
  const MScalar(this.e);
}

final class MLiteral extends MExpr {
  final List<List<Expr>> cells;
  const MLiteral(this.cells);
}

final class MIdentity extends MExpr {
  const MIdentity();
}

final class MSum extends MExpr {
  final MExpr a, b;
  final bool minus;
  const MSum(this.a, this.b, this.minus);
}

final class MProduct extends MExpr {
  final MExpr a, b;
  const MProduct(this.a, this.b);
}

final class MNegate extends MExpr {
  final MExpr a;
  const MNegate(this.a);
}

final class MTranspose extends MExpr {
  final MExpr a;
  const MTranspose(this.a);
}

/// [a] to a whole power (`-1`: the inverse).
final class MPower extends MExpr {
  final MExpr a;
  final int n;
  const MPower(this.a, this.n);
}

/// `\det A`; for bars (`|A|`) a number's absolute value.
final class MDeterminant extends MExpr {
  final MExpr a;
  final bool bars;
  const MDeterminant(this.a, {this.bars = false});
}

/// The letters in [e] that are not matrices, in order of appearance.
List<String> matrixVariables(MExpr e) {
  final out = <String>[];
  void add(Iterable<String> vs) {
    for (final v in vs) {
      if (!out.contains(v)) out.add(v);
    }
  }

  void walk(MExpr e) {
    switch (e) {
      case MScalar s:
        add(freeVariables(s.e));
      case MLiteral l:
        for (final r in l.cells) {
          for (final c in r) {
            add(freeVariables(c));
          }
        }
      case MIdentity():
        break;
      case MSum s:
        walk(s.a);
        walk(s.b);
      case MProduct p:
        walk(p.a);
        walk(p.b);
      case MNegate n:
        walk(n.a);
      case MTranspose t:
        walk(t.a);
      case MPower p:
        walk(p.a);
      case MDeterminant d:
        walk(d.a);
    }
  }

  walk(e);
  return out;
}

// ---- working them out ----

/// What [e] is worth when the letters have the values in [env]: a `double`, a [Matrix] or a [ScaledIdentity]. Throws a
/// [MatrixError] when it does not work.
Object evalMatrix(MExpr e, Map<String, double> env) {
  switch (e) {
    case MScalar s:
      final v = evaluate(s.e, env);
      if (!v.isFinite) throw MatrixError(MatrixProblem.undefined);
      return v;
    case MLiteral l:
      final rows = <List<double>>[];
      for (final r in l.cells) {
        final row = <double>[];
        for (final c in r) {
          final v = evaluate(c, env);
          if (!v.isFinite) throw MatrixError(MatrixProblem.undefined);
          row.add(v);
        }
        rows.add(row);
      }
      return Matrix(rows);
    case MIdentity():
      return const ScaledIdentity(1);
    case MSum s:
      return _sum(evalMatrix(s.a, env), evalMatrix(s.b, env), s.minus);
    case MProduct p:
      return _product(evalMatrix(p.a, env), evalMatrix(p.b, env));
    case MNegate n:
      return _scale(evalMatrix(n.a, env), -1);
    case MTranspose t:
      final v = evalMatrix(t.a, env);
      return v is Matrix ? v.transposed : v;
    case MPower p:
      return _power(evalMatrix(p.a, env), p.n);
    case MDeterminant d:
      final v = evalMatrix(d.a, env);
      if (v is double) {
        if (d.bars) return v.abs();
        throw MatrixError(MatrixProblem.shape, '\\det\\,${numberTex(v)}');
      }
      if (v is Matrix) {
        if (!v.isSquare) throw MatrixError(MatrixProblem.shape, '\\det\\,(${_size(v)})');
        return _determinant(v);
      }
      throw MatrixError(MatrixProblem.undefined);
  }
}

Object _scale(Object v, double k) => switch (v) {
      double d => d * k,
      Matrix m => m.map((x) => x * k),
      ScaledIdentity i => ScaledIdentity(i.k * k),
      _ => v,
    };

Object _sum(Object x, Object y, bool minus) {
  final s = minus ? -1.0 : 1.0;
  if (x is double && y is double) return x + s * y;
  if (x is Matrix && y is Matrix) {
    if (x.rows != y.rows || x.cols != y.cols) throw MatrixError(MatrixProblem.shape, '(${_size(x)}) ${minus ? '-' : '+'} (${_size(y)})');
    return Matrix([
      for (var i = 0; i < x.rows; i++) [for (var j = 0; j < x.cols; j++) x.a[i][j] + s * y.a[i][j]],
    ]);
  }
  if (x is ScaledIdentity && y is ScaledIdentity) return ScaledIdentity(x.k + s * y.k);
  if (x is Matrix && y is ScaledIdentity) {
    if (!x.isSquare) throw MatrixError(MatrixProblem.shape, '(${_size(x)}) ${minus ? '-' : '+'} I');
    return _sum(x, Matrix.identity(x.rows).map((e) => e * y.k), minus);
  }
  if (x is ScaledIdentity && y is Matrix) {
    if (!y.isSquare) throw MatrixError(MatrixProblem.shape, 'I ${minus ? '-' : '+'} (${_size(y)})');
    return _sum(Matrix.identity(y.rows).map((e) => e * x.k), y, minus);
  }
  // a number and a matrix
  throw MatrixError(MatrixProblem.shape, '${x is Matrix ? '(${_size(x)})' : 'n'} ${minus ? '-' : '+'} ${y is Matrix ? '(${_size(y)})' : 'n'}');
}

Object _product(Object x, Object y) {
  if (x is double) return _scale(y, x);
  if (y is double) return _scale(x, y);
  if (x is ScaledIdentity) return _scale(y, x.k);
  if (y is ScaledIdentity) return _scale(x, y.k);
  final a = x as Matrix, b = y as Matrix;
  if (a.cols != b.rows) throw MatrixError(MatrixProblem.shape, '(${_size(a)})\\,(${_size(b)})');
  return Matrix([
    for (var i = 0; i < a.rows; i++)
      [
        for (var j = 0; j < b.cols; j++)
          () {
            var t = 0.0;
            for (var k = 0; k < a.cols; k++) {
              t += a.a[i][k] * b.a[k][j];
            }
            return t;
          }(),
      ],
  ]);
}

double _determinant(Matrix m) {
  final n = m.rows;
  final a = [for (final r in m.a) List.of(r)];
  var det = 1.0;
  for (var c = 0; c < n; c++) {
    var p = c;
    for (var r = c + 1; r < n; r++) {
      if (a[r][c].abs() > a[p][c].abs()) p = r;
    }
    if (a[p][c].abs() < 1e-12) return 0;
    if (p != c) {
      final t = a[p];
      a[p] = a[c];
      a[c] = t;
      det = -det;
    }
    det *= a[c][c];
    for (var r = c + 1; r < n; r++) {
      final f = a[r][c] / a[c][c];
      for (var k = c; k < n; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  return det;
}

Matrix _inverse(Matrix m) {
  if (!m.isSquare) throw MatrixError(MatrixProblem.shape, '(${_size(m)})^{-1}');
  final n = m.rows;
  final scale = m.a.fold<double>(0, (t, r) => math.max(t, r.fold<double>(0, (u, x) => math.max(u, x.abs()))));
  final a = [for (var i = 0; i < n; i++) [...m.a[i], for (var j = 0; j < n; j++) i == j ? 1.0 : 0.0]];
  for (var c = 0; c < n; c++) {
    var p = c;
    for (var r = c + 1; r < n; r++) {
      if (a[r][c].abs() > a[p][c].abs()) p = r;
    }
    if (a[p][c].abs() <= 1e-10 * math.max(1, scale)) throw MatrixError(MatrixProblem.singular, '\\det = 0');
    final t = a[p];
    a[p] = a[c];
    a[c] = t;
    final d = a[c][c];
    for (var k = 0; k < 2 * n; k++) {
      a[c][k] /= d;
    }
    for (var r = 0; r < n; r++) {
      if (r == c) continue;
      final f = a[r][c];
      if (f == 0) continue;
      for (var k = 0; k < 2 * n; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  return Matrix([for (final r in a) r.sublist(n)]);
}

Object _power(Object v, int n) {
  if (v is double) return math.pow(v, n).toDouble();
  if (v is ScaledIdentity) return ScaledIdentity(math.pow(v.k, n).toDouble());
  var m = v as Matrix;
  if (!m.isSquare) throw MatrixError(MatrixProblem.shape, '(${_size(m)})^{$n}');
  if (n < 0) {
    m = _inverse(m);
    n = -n;
  }
  var result = Matrix.identity(m.rows);
  var base = m;
  while (n > 0) {
    if (n.isOdd) result = _product(result, base) as Matrix;
    n >>= 1;
    if (n > 0) base = _product(base, base) as Matrix;
  }
  return result;
}

// ---- reading ----

/// The rows and cells of what is inside of a matrix environment.
List<List<Expr>> _cells(String body) {
  List<String> split(String s, bool rows) {
    final out = <String>[];
    var depth = 0, start = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '{') depth++;
      if (c == '}') depth--;
      if (depth != 0) continue;
      if (rows && s.startsWith(r'\\', i)) {
        out.add(s.substring(start, i));
        i++;
        start = i + 1;
        // (`\\[2pt]`: a space between the rows)
        final skip = RegExp(r'^\[[^\]]*\]').matchAsPrefix(s, start);
        if (skip != null) {
          start = skip.end;
          i = start - 1;
        }
      } else if (!rows && c == '&') {
        out.add(s.substring(start, i));
        start = i + 1;
      }
    }
    out.add(s.substring(start));
    return out;
  }

  final rows = [for (final r in split(body.trim(), true)) if (r.trim().isNotEmpty) r];
  if (rows.isEmpty || rows.length > 8) throw ParseException('Not a matrix this can read');
  final cells = [
    for (final r in rows) [for (final c in split(r, false)) parseExpression(c)],
  ];
  if (cells.any((r) => r.length != cells.first.length) || cells.first.length > 8) throw ParseException('The rows of a matrix are of different lengths');
  // (one cell is brackets round a number, most likely)
  if (cells.length == 1 && cells.first.length == 1) throw ParseException('A matrix of one number');
  return cells;
}

/// [text] (a line or a part of one, with matrices as marks) as a matrix expression. [names] are the letters that stand for
/// matrices written before. Throws a [ParseException] for what it cannot read.
MExpr parseMatrixExpr(String text, List<MatrixLiteral> literals, Map<String, MExpr> names) {
  final p = _MatrixParser(cleanLatex(text), literals, names);
  final e = p.expression();
  p.end();
  return e;
}

/// `A` from `A`, `\mathbf{A}`, `\boldsymbol{A}`; null for anything else.
String? matrixName(String part) {
  final m = RegExp(r'^\s*(?:\\(?:mathbf|boldsymbol|bm|mathbb|mathcal)\s*\{\s*([A-Z])\s*\}|([A-Z]))\s*$').firstMatch(part);
  return m?.group(1) ?? m?.group(2);
}

class _MatrixParser {
  final String s;
  final List<MatrixLiteral> literals;
  final Map<String, MExpr> names;
  int i = 0;
  int _bars = 0;

  _MatrixParser(this.s, this.literals, this.names);

  String? get peek => i < s.length ? s[i] : null;

  void skipSpace() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
  }

  void expect(String c) {
    skipSpace();
    if (peek != c) throw ParseException('Expected "$c"');
    i++;
  }

  void end() {
    skipSpace();
    if (i < s.length) throw ParseException('Could not read "${s.substring(i)}"');
  }

  String _commandAt(int at) {
    var j = at + 1;
    while (j < s.length && RegExp(r'[a-zA-Z]').hasMatch(s[j])) {
      j++;
    }
    return s.substring(at + 1, j);
  }

  MExpr expression() {
    skipSpace();
    var negative = false;
    while (peek == '-' || peek == '+') {
      if (peek == '-') negative = !negative;
      i++;
      skipSpace();
    }
    var left = term();
    if (negative) left = MNegate(left);
    while (true) {
      skipSpace();
      final c = peek;
      if (c != '+' && c != '-') break;
      i++;
      left = MSum(left, term(), c == '-');
    }
    return left;
  }

  static const _atomCommands = {'det', 'operatorname', 'mathrm', 'mathsf', 'frac', 'dfrac', 'tfrac', 'sqrt', 'pi', 'mathbf', 'boldsymbol', 'bm'};

  bool _startsAtom(String c) {
    if (c == matrixOpen || c == '(' || c == '[' || c == '{' || c == '.') return true;
    if (c == '|') return _bars == 0;
    if (RegExp(r'[a-zA-Z0-9]').hasMatch(c)) return true;
    if (c == '\\') {
      final name = _commandAt(i);
      return _atomCommands.contains(name) || _greek.contains(name);
    }
    return false;
  }

  MExpr term() {
    var left = power();
    while (true) {
      skipSpace();
      final c = peek;
      if (c == null) break;
      if (c == '*') {
        i++;
        left = MProduct(left, power());
      } else if (c == '\\' && const {'cdot', 'times'}.contains(_commandAt(i))) {
        i += _commandAt(i).length + 1;
        left = MProduct(left, power());
      } else if (_startsAtom(c)) {
        left = MProduct(left, power());
      } else {
        break;
      }
    }
    return left;
  }

  MExpr power() {
    skipSpace();
    if (peek == '-') {
      i++;
      return MNegate(power());
    }
    var base = atom();
    while (true) {
      skipSpace();
      if (peek != '^') break;
      i++;
      base = _exponent(base);
    }
    return base;
  }

  MExpr _exponent(MExpr base) {
    skipSpace();
    String text;
    if (peek == '{') {
      text = _braced();
    } else if (peek == '\\') {
      final name = _commandAt(i);
      i += name.length + 1;
      text = '\\$name';
    } else if (peek == '-') {
      i++;
      final digit = RegExp(r'\d').matchAsPrefix(s, i);
      if (digit == null) throw ParseException('Could not read the power');
      i = digit.end;
      text = '-${digit.group(0)}';
    } else if (peek != null) {
      text = peek!;
      i++;
    } else {
      throw ParseException('The formula ends too early');
    }
    final t = text.replaceAll(' ', '');
    if (RegExp(r'^(?:T|\\top|\\intercal|\\mathsf\{T\}|\\mathrm\{T\}|\\textsf\{T\}|\\mathsf T)$').hasMatch(t)) return MTranspose(base);
    final n = int.tryParse(t);
    if (n == null || n.abs() > 64) throw ParseException('Only whole powers of a matrix are supported');
    return MPower(base, n);
  }

  /// The text inside `{...}` at the cursor.
  String _braced() {
    skipSpace();
    if (peek != '{') throw ParseException('Expected "{"');
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

  MExpr _named(String name) {
    if (name == 'I' && !names.containsKey('I')) return const MIdentity();
    final known = names[name];
    if (known == null) throw ParseException('$name is not a matrix I know');
    return known;
  }

  MExpr atom() {
    skipSpace();
    final c = peek;
    if (c == null) throw ParseException('The formula ends too early');
    if (c == matrixOpen) {
      final close = s.indexOf(matrixClose, i);
      final index = close < 0 ? null : int.tryParse(s.substring(i + 1, close));
      if (index == null || index >= literals.length) throw ParseException('A matrix is missing');
      i = close + 1;
      final lit = literals[index];
      final m = MLiteral(_cells(lit.body));
      return lit.determinant ? MDeterminant(m) : m;
    }
    if (c == '(' || c == '[') {
      i++;
      final e = expression();
      expect(c == '(' ? ')' : ']');
      return e;
    }
    if (c == '{') {
      final inner = _braced();
      final p = _MatrixParser(inner, literals, names);
      final e = p.expression();
      p.end();
      return e;
    }
    if (c == '|') {
      i++;
      _bars++;
      final e = expression();
      _bars--;
      expect('|');
      return MDeterminant(e, bars: true);
    }
    if (RegExp(r'[0-9.]').hasMatch(c)) {
      final m = RegExp(r'\d*\.?\d+|\d+\.?').matchAsPrefix(s, i);
      if (m == null) throw ParseException('Could not read a number');
      i = m.end;
      return MScalar(Num(double.parse(m.group(0)!)));
    }
    if (c == '\\') return _command();
    if (RegExp(r'[A-Z]').hasMatch(c)) {
      i++;
      return _named(c);
    }
    if (RegExp(r'[a-z]').hasMatch(c)) {
      i++;
      var name = c;
      final sub = RegExp(r'_\{\s*([^{}]*?)\s*\}|_([A-Za-z0-9])').matchAsPrefix(s, i);
      if (sub != null) {
        name = '${c}_{${sub.group(1) ?? sub.group(2)}}';
        i = sub.end;
      }
      return MScalar(Sym(name));
    }
    throw ParseException('Could not read "$c"');
  }

  MExpr _command() {
    final name = _commandAt(i);
    if (name.isEmpty) throw ParseException('Could not read "${s.substring(i)}"');
    i += name.length + 1;
    switch (name) {
      case 'det':
        return MDeterminant(power());
      case 'operatorname' || 'mathrm' || 'mathsf':
        final inner = _braced().trim();
        if (inner == 'det') return MDeterminant(power());
        final n = matrixName(inner);
        if (n == null) throw ParseException('Could not read \\$name{$inner}');
        return _named(n);
      case 'mathbf' || 'boldsymbol' || 'bm':
        final n = matrixName(_braced());
        if (n == null) throw ParseException('Could not read a bold letter');
        return _named(n);
      case 'frac' || 'dfrac' || 'tfrac':
        final a = _braced(), b = _braced();
        return MScalar(parseExpression('\\frac{$a}{$b}'));
      case 'sqrt':
        skipSpace();
        var root = '';
        if (peek == '[') {
          final close = s.indexOf(']', i);
          if (close < 0) throw ParseException('Unclosed bracket');
          root = s.substring(i, close + 1);
          i = close + 1;
        }
        return MScalar(parseExpression('\\sqrt$root{${_braced()}}'));
      case 'pi':
        return MScalar(parseExpression(r'\pi'));
    }
    if (_greek.contains(name)) return MScalar(Sym('\\$name'));
    throw ParseException('\\$name is not supported');
  }
}

const _greek = {
  'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'varepsilon', 'zeta', 'eta', 'theta', 'vartheta', 'iota', 'kappa',
  'lambda', 'mu', 'nu', 'xi', 'rho', 'sigma', 'tau', 'upsilon', 'phi', 'varphi', 'chi', 'psi', 'omega',
};
