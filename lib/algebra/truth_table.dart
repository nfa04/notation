import 'logic.dart';

/// Truth tables for the formulas of [logic.dart]: the table with a column for every part of the formula, what kind of formula it is
/// (always true, never true, sometimes), the same formula in other forms (the rows that make it true, the shortest sum of products), and
/// the table as Markdown or LaTeX.

/// The most letters a table is made for (2^10 rows).
const largestTruthTable = 10;

// ---- writing a formula ----

int _binding(Logic f) => switch (f) {
      LVar() || LConst() => 9,
      LNot() => 8,
      LBinary b => switch (b.op) {
          LogicOp.and || LogicOp.nand => 6,
          LogicOp.xor => 5,
          LogicOp.or || LogicOp.nor => 4,
          LogicOp.implies => 3,
          LogicOp.iff => 2,
        },
    };

String _sign(LogicOp op, {required bool tex}) => switch (op) {
      LogicOp.and => tex ? r'\land' : '∧',
      LogicOp.or => tex ? r'\lor' : '∨',
      LogicOp.xor => tex ? r'\oplus' : '⊕',
      LogicOp.implies => tex ? r'\to' : '→',
      LogicOp.iff => tex ? r'\leftrightarrow' : '↔',
      LogicOp.nand => tex ? r'\uparrow' : '↑',
      LogicOp.nor => tex ? r'\downarrow' : '↓',
    };

String _write(Logic f, {required bool tex}) {
  String wrap(Logic g, bool paren) => paren ? '(${_write(g, tex: tex)})' : _write(g, tex: tex);
  switch (f) {
    case LVar v:
      return v.name;
    case LConst c:
      return c.value ? (tex ? r'\top' : '⊤') : (tex ? r'\bot' : '⊥');
    case LNot n:
      // (¬ binds the tightest: only a letter, a constant or another ¬ goes without brackets)
      final inner = n.a;
      final plain = inner is LVar || inner is LConst || inner is LNot;
      return '${tex ? r'\neg ' : '¬'}${wrap(inner, !plain)}';
    case LBinary b:
      final mine = _binding(b);
      // and, or and xor can be chained, → goes to the right; round anything else of the same strength there are brackets
      final chains = b.op == LogicOp.and || b.op == LogicOp.or || b.op == LogicOp.xor;
      final left = wrap(b.a, _binding(b.a) < mine || _binding(b.a) == mine && !(chains && _sameOp(b, b.a)));
      final right = wrap(b.b, _binding(b.b) < mine || _binding(b.b) == mine && !((chains && _sameOp(b, b.b)) || (b.op == LogicOp.implies && _sameOp(b, b.b))));
      return '$left ${_sign(b.op, tex: tex)} $right';
  }
}

bool _sameOp(LBinary a, Logic b) => b is LBinary && b.op == a.op;

/// [f] as LaTeX, with as few brackets as the binding allows (`¬`, `∧`, `⊕`, `∨`, `→`, `↔`, strongest first).
String logicTex(Logic f) => _write(f, tex: true);

/// [f] in the signs `¬ ∧ ∨ ⊕ → ↔ ↑ ↓ ⊤ ⊥`.
String logicText(Logic f) => _write(f, tex: false);

// ---- the table ----

enum LogicKind { tautology, contradiction, contingent }

class TruthTable {
  /// The letters.
  final List<String> variables;

  /// A column for every letter, then for every part of the formulas, parts before the whole.
  final List<Logic> columns;

  /// Which columns are the formulas that were asked about (the last column of each).
  final List<int> results;

  /// One row for each assignment of the letters: the value of every column.
  final List<List<bool>> rows;

  const TruthTable(this.variables, this.columns, this.results, this.rows);

  int get variableCount => variables.length;

  String header(int column, {bool tex = false}) => tex ? logicTex(columns[column]) : logicText(columns[column]);

  /// The values of the letters in [row] (what the first columns say).
  Map<String, bool> assignment(int row) => {for (var i = 0; i < variableCount; i++) variables[i]: rows[row][i]};

  /// The number of the row as a binary number with the first letter as the highest digit (all false is 0).
  int number(int row) {
    var n = 0;
    for (var i = 0; i < variableCount; i++) {
      n = n << 1 | (rows[row][i] ? 1 : 0);
    }
    return n;
  }

  List<bool> _column(int c) => [for (final r in rows) r[c]];

  /// What kind of formula the [which]-th one is.
  LogicKind kind([int which = 0]) {
    final v = _column(results[which]);
    if (v.every((x) => x)) return LogicKind.tautology;
    if (v.every((x) => !x)) return LogicKind.contradiction;
    return LogicKind.contingent;
  }

  /// How many rows make the [which]-th formula true.
  int trueRows([int which = 0]) => _column(results[which]).where((x) => x).length;

  /// Whether the formulas asked about all have the same value in every row.
  bool get equivalent => rows.every((r) => results.every((c) => r[c] == r[results.first]));

  /// The rows in which the [a]-th and the [b]-th formula differ.
  List<int> differing([int a = 0, int b = 1]) => [for (var i = 0; i < rows.length; i++) if (rows[i][results[a]] != rows[i][results[b]]) i];

  /// Whether the [b]-th formula follows from the [a]-th (no row makes the first true and the second false).
  bool implies([int a = 0, int b = 1]) => rows.every((r) => !r[results[a]] || r[results[b]]);

  /// The numbers of the rows that make the [which]-th formula true / false.
  List<int> minterms([int which = 0]) => _numbers(which, true)..sort();
  List<int> maxterms([int which = 0]) => _numbers(which, false)..sort();

  List<int> _numbers(int which, bool value) => [for (var i = 0; i < rows.length; i++) if (rows[i][results[which]] == value) number(i)];

  /// The [which]-th formula as the sum of the rows that make it true: each a product of letters and their negations.
  Logic? canonicalSumOfProducts([int which = 0]) {
    final ms = minterms(which);
    if (ms.isEmpty) return null;
    return _join(LogicOp.or, [for (final m in ms) _cube(m, variableCount, variables)]);
  }

  /// The [which]-th formula as the product of the rows that make it false: each a sum of letters and their negations.
  Logic? canonicalProductOfSums([int which = 0]) {
    final ms = maxterms(which);
    if (ms.isEmpty) return null;
    return _join(LogicOp.and, [for (final m in ms) _clause(m, variableCount, variables)]);
  }

  /// A shortest sum of products for the [which]-th formula (Quine-McCluskey; null when it is never true). A formula that is always true is `⊤`.
  Logic? minimalSumOfProducts([int which = 0]) {
    final ms = minterms(which);
    if (ms.isEmpty) return null;
    if (ms.length == rows.length) return const LConst(true);
    final cubes = _minimalCover(ms, variableCount);
    return _join(LogicOp.or, [for (final c in cubes) _literals(c, variableCount, variables)]);
  }

  /// A shortest product of sums for the [which]-th formula (null when it is always true). A formula that is never true is `⊥`.
  Logic? minimalProductOfSums([int which = 0]) {
    final ms = maxterms(which);
    if (ms.isEmpty) return null;
    if (ms.length == rows.length) return const LConst(false);
    // the cubes that cover where it is false, read the other way round: a clause for each
    final cubes = _minimalCover(ms, variableCount);
    return _join(LogicOp.and, [for (final c in cubes) _clauseOf(c, variableCount, variables)]);
  }

  // ---- as text ----

  List<String> _headers(bool tex) => [for (var c = 0; c < columns.length; c++) header(c, tex: tex)];

  String _cell(bool v, bool tf) => tf ? (v ? 'T' : 'F') : (v ? '1' : '0');

  /// The cells of the table as text: the headers, then a list for each row.
  List<List<String>> cells({bool letters = false}) => [
        _headers(false),
        for (final r in rows) [for (final v in r) _cell(v, letters)],
      ];

  /// A Markdown table (the letters first, the formulas asked about last in bold).
  String markdown({bool letters = false}) {
    final header = _headers(false);
    final bold = {for (final r in results) r};
    String h(int c) => bold.contains(c) && c >= variableCount ? '**${header[c]}**' : header[c];
    final out = StringBuffer()
      ..writeln('| ${[for (var c = 0; c < header.length; c++) h(c)].join(' | ')} |')
      ..writeln('|${List.filled(header.length, ':-:').join('|')}|');
    for (final r in rows) {
      out.writeln('| ${[for (final v in r) _cell(v, letters)].join(' | ')} |');
    }
    return out.toString().trimRight();
  }

  /// A LaTeX `tabular` (needs amssymb for `\top` and `\bot` only if those are in the formula).
  String latex({bool letters = false}) {
    final n = columns.length;
    final spec = [for (var c = 0; c < n; c++) c == variableCount && variableCount > 0 ? '|c' : 'c'].join();
    final out = StringBuffer()
      ..writeln('\\begin{tabular}{$spec}')
      ..writeln('  ${[for (final h in _headers(true)) '\$$h\$'].join(' & ')} \\\\ \\hline');
    for (final r in rows) {
      out.writeln('  ${[for (final v in r) _cell(v, letters)].join(' & ')} \\\\');
    }
    out.write('\\end{tabular}');
    return out.toString();
  }
}

Logic _join(LogicOp op, List<Logic> parts) => parts.reduce((a, b) => LBinary(op, a, b));

/// The product of the letters that row [m] has true, and the negations of the others.
Logic _cube(int m, int n, List<String> vars) => _join(LogicOp.and, [
      for (var i = 0; i < n; i++) (m >> (n - 1 - i)) & 1 == 1 ? LVar(vars[i]) : LNot(LVar(vars[i])),
    ]);

/// The sum that is false in row [m] only.
Logic _clause(int m, int n, List<String> vars) => _join(LogicOp.or, [
      for (var i = 0; i < n; i++) (m >> (n - 1 - i)) & 1 == 1 ? LNot(LVar(vars[i])) : LVar(vars[i]),
    ]);

/// A cube of the cover as a product: `values[i]` is 1, 0 or null (the letter does not matter).
Logic _literals(List<int?> cube, int n, List<String> vars) => _join(LogicOp.and, [
      for (var i = 0; i < n; i++)
        if (cube[i] != null) cube[i] == 1 ? LVar(vars[i]) : LNot(LVar(vars[i])),
    ]);

/// The same cube read for a formula that is false there: a sum of the opposite literals.
Logic _clauseOf(List<int?> cube, int n, List<String> vars) => _join(LogicOp.or, [
      for (var i = 0; i < n; i++)
        if (cube[i] != null) cube[i] == 1 ? LNot(LVar(vars[i])) : LVar(vars[i]),
    ]);

/// The prime implicants of [ms] (Quine-McCluskey) and a small set of them that covers every one: those that are the only cover of a
/// row, then the one that covers most of the rest, over and over.
List<List<int?>> _minimalCover(List<int> ms, int n) {
  // a cube is (the bits, the mask of the letters that do not matter)
  var level = {for (final m in ms) (m, 0)};
  final primes = <(int, int)>{};
  while (level.isNotEmpty) {
    final next = <(int, int)>{};
    final merged = <(int, int)>{};
    final list = level.toList();
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        final (a, ma) = list[i];
        final (b, mb) = list[j];
        if (ma != mb) continue;
        final diff = a ^ b;
        if (diff != 0 && diff & (diff - 1) == 0) {
          next.add((a & ~diff, ma | diff));
          merged..add(list[i])..add(list[j]);
        }
      }
    }
    primes.addAll(level.difference(merged));
    level = next;
  }
  bool covers((int, int) p, int m) => (m & ~p.$2) == (p.$1 & ~p.$2);
  final remaining = {...ms};
  final chosen = <(int, int)>[];
  // the primes that are the only ones to cover some row
  for (final m in ms) {
    final cover = primes.where((p) => covers(p, m)).toList();
    if (cover.length == 1 && !chosen.contains(cover.first)) chosen.add(cover.first);
  }
  for (final p in chosen) {
    remaining.removeWhere((m) => covers(p, m));
  }
  while (remaining.isNotEmpty) {
    (int, int)? best;
    var bestCount = -1;
    var bestSize = 0;
    for (final p in primes) {
      final count = remaining.where((m) => covers(p, m)).length;
      final size = n - _ones(p.$2); // (the letters it has)
      if (count > bestCount || count == bestCount && size < bestSize) {
        best = p;
        bestCount = count;
        bestSize = size;
      }
    }
    chosen.add(best!);
    remaining.removeWhere((m) => covers(best!, m));
  }
  chosen.sort((a, b) => a.$1.compareTo(b.$1));
  return [
    for (final (bits, mask) in chosen)
      [for (var i = 0; i < n; i++) (mask >> (n - 1 - i)) & 1 == 1 ? null : (bits >> (n - 1 - i)) & 1],
  ];
}

int _ones(int x) {
  var c = 0;
  for (var v = x; v != 0; v &= v - 1) {
    c++;
  }
  return c;
}

/// The table of [formulas] (one, or several to compare): null when there are more than [largestTruthTable] letters or none are given.
/// The rows count up as binary numbers (all false first), or with [onesFirst] down from all true, as many books write them.
TruthTable? buildTruthTable(List<Logic> formulas, {bool onesFirst = false}) {
  if (formulas.isEmpty) return null;
  final vars = logicVariables(formulas);
  if (vars.length > largestTruthTable) return null;
  final columns = <Logic>[for (final v in vars) LVar(v)];
  final seen = {for (final v in vars) logicTex(LVar(v))};
  final results = <int>[];
  void add(Logic f) {
    switch (f) {
      case LVar() || LConst():
        break;
      case LNot n:
        add(n.a);
      case LBinary b:
        add(b.a);
        add(b.b);
    }
    final key = logicTex(f);
    if (f is LVar) return;
    if (seen.add(key)) columns.add(f);
  }

  for (final f in formulas) {
    add(f);
    results.add(f is LVar ? vars.indexOf(f.name) : columns.indexWhere((c) => logicTex(c) == logicTex(f)));
  }
  final count = 1 << vars.length;
  final rows = <List<bool>>[];
  for (var k = 0; k < count; k++) {
    final bits = onesFirst ? count - 1 - k : k;
    final row = {for (var i = 0; i < vars.length; i++) vars[i]: (bits >> (vars.length - 1 - i)) & 1 == 1};
    rows.add([for (final c in columns) evalLogic(c, row)]);
  }
  return TruthTable(vars, columns, results, rows);
}

// ---- reading what a person types ----

/// What people type as logic, as one formula or several to compare: besides the LaTeX and the signs of [parseLogicLine], also `&`, `&&`, `|`,
/// `||`, `!`, `~`, `->`, `<->`, `^` (exclusive or) and the words and, or, not, xor, nand, nor, implies, iff, true, false (and 1 and 0 for
/// the last two). `=`, `==` and `\equiv` between formulas say they are the same; `|=`, `\models` and `⊨` say the second follows from the
/// first. Null when it is not a formula.
LogicLine? parseFormulaText(String text) {
  var s = ' ${text.trim()} ';
  s = s
      .replaceAll(RegExp(r'\\(?:models|vDash)(?![A-Za-z])'), ' ⊨ ')
      .replaceAll('|=', ' ⊨ ')
      .replaceAll('<=>', r' \leftrightarrow ')
      .replaceAll('<-->', r' \leftrightarrow ')
      .replaceAll('<->', r' \leftrightarrow ')
      .replaceAll('==>', r' \to ')
      .replaceAll('-->', r' \to ')
      .replaceAll('=>', r' \to ')
      .replaceAll('->', r' \to ')
      .replaceAll('&&', r' \land ')
      .replaceAll('||', r' \lor ')
      .replaceAll('==', ' ≡ ')
      .replaceAll(r'\equiv', ' ≡ ')
      .replaceAll('&', r' \land ')
      .replaceAll('|', r' \lor ')
      .replaceAll('^', r' \oplus ')
      .replaceAll('!', r' \neg ')
      .replaceAll('~', r' \neg ');
  void word(String w, String to) => s = s.replaceAllMapped(RegExp('(?<![A-Za-z\\\\])$w(?![A-Za-z])', caseSensitive: false), (_) => ' $to ');
  word('and', r'\land');
  word('or', r'\lor');
  word('not', r'\neg');
  word('xor', r'\oplus');
  word('nand', r'\uparrow');
  word('nor', r'\downarrow');
  word('implies', r'\to');
  word('iff', r'\leftrightarrow');
  word('true', r'\top');
  word('false', r'\bot');
  s = s
      .replaceAll(RegExp(r'(?<![\w\\])1(?![\w])'), r' \top ')
      .replaceAll(RegExp(r'(?<![\w\\])0(?![\w])'), r' \bot ')
      .replaceAllMapped(RegExp(r'(?<![<>=≡])=(?![=>])'), (_) => ' ≡ ');
  // cut at the signs "the same" and "follows" outside of brackets
  final pieces = <String>[''];
  final relations = <LogicRelation>[];
  var depth = 0;
  for (final c in s.split('')) {
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if (depth == 0 && (c == '≡' || c == '⊨')) {
      relations.add(c == '≡' ? LogicRelation.equivalent : LogicRelation.implies);
      pieces.add('');
    } else {
      pieces.last += c;
    }
  }
  if (depth != 0 || pieces.any((p) => p.trim().isEmpty)) return null;
  final formulas = <Logic>[];
  for (final p in pieces) {
    final f = parseLogicFormula(p.trim());
    if (f == null) return null;
    formulas.add(f);
  }
  return LogicLine(formulas, relations, null);
}
