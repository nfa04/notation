part of 'checker.dart';

// ---- matrices ----

/// Whether [part] is about matrices: it has one written out, or names one that was written above, or takes a determinant of one.
bool _isMatrixText(String part, Map<String, MExpr> names) {
  if (part.contains(matrixOpen)) return true;
  if (names.isEmpty) return false;
  final t = part.replaceAllMapped(RegExp(r'\\(?:mathbf|boldsymbol|bm|mathbb|mathcal)\s*\{\s*([A-Z])\s*\}'), (m) => m[1]!);
  for (final name in names.keys) {
    if (RegExp('(?<![A-Za-z\\\\])$name(?![A-Za-z])').hasMatch(t)) return true;
  }
  return false;
}

/// [part] of [st] as a matrix expression, or null when it cannot be read.
MExpr? _matrixSide(String part, _Statement st, Map<String, MExpr> names) {
  try {
    return parseMatrixExpr(part, st.matrices, names);
  } on ParseException {
    return null;
  }
}

LineCheck? _matrixError(MatrixError e) => switch (e.problem) {
      MatrixProblem.shape => LineCheck(verdict: Verdict.wrong, reason: Reason.shape, counter: e.tex),
      MatrixProblem.singular => LineCheck(verdict: Verdict.wrong, reason: Reason.singular, counter: e.tex),
      MatrixProblem.undefined => null,
    };

/// A line about matrices: `A = \begin{pmatrix}...` names one, and `A B = \begin{pmatrix}...`, `\det A = 5`, `A^T = ...`
/// and `A^{-1} = ...` are claims.
LineCheck? _checkMatrices(_Statement st, Map<String, MExpr> names) {
  LineCheck? result;
  for (final chain in st.chains) {
    if (chain.parts.length < 2) {
      // a line that waits for its result (`A B =`)
      if (st.trail && chain.parts.length == 1 && !st.lead) {
        final e = _matrixSide(chain.parts.first, st, names);
        if (e == null || matrixVariables(e).isNotEmpty) continue;
        try {
          result = _worse(result, LineCheck(answer: matrixTex(evalMatrix(e, const {}))));
        } on MatrixError catch (error) {
          result = _worse(result, _matrixError(error));
        }
      }
      continue;
    }
    var from = 0;
    final name = matrixName(chain.parts.first);
    if (name != null && !st.lead && _isMatrixText(chain.parts[1], names)) {
      // a letter for a matrix: from here on the letter is what stands on the right
      final rhs = _matrixSide(chain.parts[1], st, names);
      if (rhs != null) {
        names[name] = rhs;
        from = 1;
      }
    }
    final sides = [for (var k = from; k < chain.parts.length; k++) _matrixSide(chain.parts[k], st, names)];
    for (var k = 0; k + 1 < sides.length; k++) {
      if (chain.approximate[from + k]) continue;
      result = _worse(result, _matrixPair(sides[k], sides[k + 1], names));
    }
  }
  return result;
}

/// Whether the matrix expressions [a] and [b] are the same thing.
LineCheck? _matrixPair(MExpr? a, MExpr? b, Map<String, MExpr> names) {
  if (a == null || b == null) return null;
  final vars = <String>[...matrixVariables(a), for (final v in matrixVariables(b)) if (!matrixVariables(a).contains(v)) v];
  final points = vars.isEmpty ? [<String, double>{}] : _points(vars).take(12).toList();
  var valid = 0;
  for (final p in points) {
    Object x, y;
    try {
      x = evalMatrix(a, p);
      y = evalMatrix(b, p);
    } on MatrixError catch (e) {
      // (a letter that happens to make a matrix singular is not a mistake of the line)
      if (vars.isNotEmpty && e.problem == MatrixProblem.singular) continue;
      return _matrixError(e);
    }
    // (a number against a matrix is notation this does not know, such as the units of a quaternion: not for a verdict)
    if ((x is double) != (y is double)) return null;
    // (two numbers with other letters on one side are an equation or a definition, as everywhere else)
    if (x is double && y is double && !(matrixVariables(a).toSet().containsAll(matrixVariables(b)) && matrixVariables(b).toSet().containsAll(matrixVariables(a)))) return null;
    valid++;
    if (matrixEqual(x, y)) continue;
    final plain = x is double && y is double;
    final where = p.isEmpty ? '' : '${p.entries.map((e) => '${e.key} = ${numberTex(e.value)}').join(', ')}:\\; ';
    return LineCheck(
      verdict: Verdict.wrong,
      reason: plain ? Reason.arithmetic : Reason.matrix,
      expected: vars.isEmpty || plain ? matrixTex(x) : null,
      counter: plain ? '$where${matrixTex(x)} \\neq ${matrixTex(y)}' : (vars.isEmpty ? null : '$where${matrixTex(x)} \\neq ${matrixTex(y)}'),
    );
  }
  return valid > 0 ? const LineCheck(verdict: Verdict.right) : null;
}
