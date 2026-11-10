part of 'checker.dart';

// ---- logic ----

/// The most letters a truth table is made for (2^10 rows).
const _largestTable = 10;

/// A line of logic: each formula against the next, by the sign between them.
LineCheck? _checkLogic(LogicLine line) {
  LineCheck? result;
  for (var k = 0; k + 1 < line.formulas.length; k++) {
    result = _worse(result, _logicPair(line.formulas[k], line.formulas[k + 1], line.relations[k]));
  }
  return result;
}

/// A line that goes on from the one above with a sign (`\equiv \neg p \lor q`).
LineCheck? _logicStep(_Statement before, _Statement now) {
  final a = before.logic, b = now.logic;
  if (a == null || b == null || b.lead == null) return null;
  return _logicPair(a.formulas.last, b.formulas.first, b.lead!);
}

/// Whether [a] and [b] are the same ([relation] equivalent) or [b] follows from [a] (implies), by going through the truth table.
LineCheck? _logicPair(Logic a, Logic b, LogicRelation relation) {
  // a lone letter that the other side does not have is a name for it (`g = a \oplus b`), not a claim
  if (relation == LogicRelation.equivalent) {
    bool name(Logic f, Logic other) => f is LVar && !logicVariables([other]).contains(f.name);
    if (name(a, b) || name(b, a)) return null;
  }
  final vars = logicVariables([a, b]);
  if (vars.length > _largestTable) return null;
  for (var bits = 0; bits < 1 << vars.length; bits++) {
    final row = {for (var k = 0; k < vars.length; k++) vars[k]: (bits >> (vars.length - 1 - k)) & 1 == 1};
    final x = evalLogic(a, row), y = evalLogic(b, row);
    final holds = relation == LogicRelation.equivalent ? x == y : (!x || y);
    if (holds) continue;
    String v(bool b) => b ? '1' : '0';
    final where = vars.isEmpty ? '' : '${vars.map((n) => '$n = ${v(row[n]!)}').join(r',\; ')}:\\; ';
    return LineCheck(
      verdict: Verdict.wrong,
      reason: relation == LogicRelation.equivalent ? Reason.notEquivalent : Reason.notImplied,
      counter: '$where${v(x)} ${relation == LogicRelation.equivalent ? r'\neq' : r'\nRightarrow'} ${v(y)}',
    );
  }
  return const LineCheck(verdict: Verdict.right);
}

// ---- congruences ----

/// `a \equiv b \pmod{m}`: the difference is a multiple of m. Letters are whole numbers here.
LineCheck? _checkCongruence(_Statement st) {
  if (st.isList || st.lead || st.trail) return null;
  final chain = st.first;
  if (chain.parts.any(_opaque) || _opaque(st.modulus!)) return null;
  final m = parseExpression(st.modulus!);
  final exprs = [for (final p in chain.parts) parseExpression(p)];
  LineCheck? result;
  for (var k = 0; k + 1 < exprs.length; k++) {
    final a = exprs[k], b = exprs[k + 1];
    final vars = _varsOf([a, b, m]);
    final points = vars.isEmpty ? [<String, double>{}] : _points(vars, vars.toSet()).take(30).toList();
    var valid = 0;
    LineCheck? bad;
    for (final p in points) {
      final mv = evaluate(m, p), av = evaluate(a, p), bv = evaluate(b, p);
      if ([mv, av, bv].any((x) => !x.isFinite || x != x.roundToDouble()) || mv < 1) continue;
      valid++;
      final r = (av - bv) - mv * ((av - bv) / mv).floorToDouble();
      if (r.abs() < 1e-9) continue;
      final where = p.isEmpty ? '' : '${p.entries.map((e) => '${e.key} = ${numberTex(e.value)}').join(r',\; ')}:\\; ';
      final mod = numberTex(mv);
      bad = LineCheck(
        verdict: Verdict.wrong,
        reason: Reason.congruence,
        expected: p.isEmpty ? '${numberTex(av)} \\equiv ${numberTex(av - mv * (av / mv).floorToDouble())} \\pmod{$mod}' : null,
        counter: p.isEmpty ? null : '$where${numberTex(av)} \\not\\equiv ${numberTex(bv)} \\pmod{$mod}',
      );
      break;
    }
    if (valid == 0) continue;
    result = _worse(result, bad ?? const LineCheck(verdict: Verdict.right));
  }
  return result;
}
