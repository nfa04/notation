part of 'checker.dart';

/// What the units of one side of a statement turned out to be: the exponents of the base units (kg, m, s, A, K, mol), each twice (a square
/// root of an area is a length, and a root of a length has half an exponent); null when the side adds or compares things of different units.
class _Dimension {
  final List<int>? twice;
  const _Dimension(this.twice);

  bool get fits => twice != null;

  /// The units as LaTeX, or null when there is no way to put them well (half exponents).
  String? get tex => twice == null || twice!.any((t) => t.isOdd) ? null : unitTex([for (final t in twice!) t ~/ 2]);
}

/// Whether the units in [clean] (the statement with its units worked out to SI numbers, which is what is checked as maths) fit: both sides of
/// `=` and `\approx` must be made of the same base units (`0.5\,kg \cdot 9.81\,m/s^2 = 4.9\,N` but not `= 4.9\,J`), and nothing may add
/// a length to a mass. Only what is made of numbers and units alone is looked at: with a letter in it (`m g h`), the units of a side are not
/// known.
LineCheck? _checkUnits(UnitReading reading, _Statement clean) {
  if (clean.relation != null || clean.logic != null || clean.modulus != null || clean.isList || clean.chains.isEmpty) return null;
  final withUnits = _Statement.parse(reading.dims);
  if (withUnits == null || withUnits.isList || withUnits.chains.length != 1 || withUnits.first.parts.length != clean.first.parts.length) return null;
  final parts = withUnits.first.parts;
  final dims = [for (final p in parts) _dimensionOf(p)];
  LineCheck? result;
  for (var k = 0; k < dims.length; k++) {
    final d = dims[k];
    if (d != null && !d.fits) {
      result = const LineCheck(verdict: Verdict.wrong, reason: Reason.units);
    }
  }
  for (var k = 0; k + 1 < dims.length && result == null; k++) {
    final a = dims[k], b = dims[k + 1];
    if (a == null || b == null || !a.fits || !b.fits) continue;
    var same = true;
    for (var i = 0; i < 6; i++) {
      if (a.twice![i] != b.twice![i]) same = false;
    }
    if (same) continue;
    final left = a.tex, right = b.tex;
    result = LineCheck(verdict: Verdict.wrong, reason: Reason.units, counter: left == null || right == null ? null : '$left \\neq $right');
  }
  return result;
}

/// The units of [part] (written with the formal unit variables of [UnitReading.dims]); null when it has no units, or letters of other kinds.
_Dimension? _dimensionOf(String part) {
  if (!part.contains('Q_{u') || _opaque(part)) return null;
  final e = parseExpression(part);
  final vars = freeVariables(e);
  if (vars.isEmpty || vars.any((v) => !isUnitVariable(v))) return null;
  final base = {for (final v in vars) v: 1.3 + 0.37 * unitIndex(v)};
  final v0 = evaluate(e, base);
  if (!v0.isFinite || v0.abs() < 1e-12) return null;
  final twice = List<int>.filled(6, 0);
  var fits = true;
  for (final v in vars) {
    final ratios = <double>[];
    for (final factor in const [2.0, 3.0]) {
      final moved = evaluate(e, {...base, v: base[v]! * factor});
      if (!moved.isFinite) return null;
      ratios.add(moved / v0);
    }
    if (ratios[0] <= 0 || ratios[1] <= 0) {
      fits = false;
      continue;
    }
    final exponent = math.log(ratios[0]) / math.log(2);
    final rounded = (2 * exponent).round();
    if ((2 * exponent - rounded).abs() > 1e-6 || !_close(ratios[1], math.pow(3, rounded / 2).toDouble(), 1e-6)) {
      fits = false;
      continue;
    }
    twice[unitIndex(v)] = rounded;
  }
  if (fits) return _Dimension(twice);
  // (a sine or an exponential of a quantity with units is not homogeneous either, and is what a person may write: not judged)
  if (RegExp(r'\\(?:sin|cos|tan|cot|sec|csc|ln|log|exp|sinh|cosh|tanh|arcsin|arccos|arctan)(?![a-zA-Z])|(?<![A-Za-z\\])e\s*\^').hasMatch(part)) return null;
  return const _Dimension(null);
}
