import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/logic.dart';
import 'package:notes/algebra/truth_table.dart';

Logic f(String text) => parseFormulaText(text)!.formulas.first;
TruthTable t(String text) => buildTruthTable([f(text)])!;

void main() {
  group('reading what is typed', () {
    test('signs, LaTeX, ASCII and words are the same formula', () {
      final forms = [r'p \to q', 'p → q', 'p -> q', 'p implies q', 'p => q', r'\neg p \lor q', '!p | q', 'not p or q', '~p || q'];
      final tables = [for (final s in forms) buildTruthTable([f(s)])!.minterms()];
      expect(tables.every((m) => m.toString() == tables.first.toString()), isTrue);
    });

    test('a line with several formulas is a comparison', () {
      final line = parseFormulaText(r'p \to q \equiv \neg p \lor q')!;
      expect(line.formulas.length, 2);
      expect(line.relations.single, LogicRelation.equivalent);
      expect(parseFormulaText('p xor q == (p | q) & !(p & q)')!.formulas.length, 2);
    });

    test('constants and rubbish', () {
      expect(buildTruthTable([f('p & 1')])!.minterms(), [1]);
      expect(buildTruthTable([f('p | false')])!.minterms(), [1]);
      expect(parseFormulaText('p +'), isNull);
      expect(parseFormulaText(''), isNull);
      expect(parseFormulaText('x squared'), isNull);
    });
  });

  group('the table', () {
    test('columns: the letters, then the parts before the whole', () {
      final table = t(r'(p \to q) \land (q \to r)');
      expect(table.variables, ['p', 'q', 'r']);
      expect([for (var c = 0; c < table.columns.length; c++) table.header(c)], ['p', 'q', 'r', 'p → q', 'q → r', '(p → q) ∧ (q → r)']);
      expect(table.rows.length, 8);
      expect(table.results, [5]);
    });

    test('rows count up from all false, or down from all true', () {
      final up = t('p & q');
      expect([for (final r in up.rows) r.take(2).map((v) => v ? 1 : 0).join()], ['00', '01', '10', '11']);
      final down = buildTruthTable([f('p & q')], onesFirst: true)!;
      expect([for (final r in down.rows) r.take(2).map((v) => v ? 1 : 0).join()], ['11', '10', '01', '00']);
      expect(down.minterms(), [3]);
    });

    test('a part that is written twice is one column', () {
      final table = t(r'(p \land q) \lor \neg(p \land q)');
      expect(table.columns.where((c) => logicTex(c) == r'p \land q').length, 1);
      expect(table.kind(), LogicKind.tautology);
    });

    test('a single letter', () {
      final table = t('p');
      expect(table.columns.length, 1);
      expect(table.results, [0]);
      expect(table.kind(), LogicKind.contingent);
    });

    test('too many letters', () {
      expect(buildTruthTable([f('a & b & c & d & e & f & g & h & i & j & k')]), isNull);
      expect(buildTruthTable([f('a & b & c & d & e & f & g & h & i & j')]), isNotNull);
    });
  });

  group('what kind of formula', () {
    test('always, never, sometimes', () {
      expect(t(r'p \lor \neg p').kind(), LogicKind.tautology);
      expect(t(r'p \land \neg p').kind(), LogicKind.contradiction);
      expect(t(r'p \to q').kind(), LogicKind.contingent);
      expect(t(r'((p \to q) \land p) \to q').kind(), LogicKind.tautology);
      expect(t(r'p \to q').trueRows(), 3);
    });

    test('comparing formulas', () {
      final same = buildTruthTable([f(r'p \to q'), f(r'\neg p \lor q')])!;
      expect(same.equivalent, isTrue);
      expect(same.differing(), isEmpty);
      final other = buildTruthTable([f(r'p \to q'), f(r'q \to p')])!;
      expect(other.equivalent, isFalse);
      expect(other.differing(), [1, 2]);
      expect(buildTruthTable([f(r'p \land q'), f('p')])!.implies(), isTrue);
      expect(buildTruthTable([f('p'), f(r'p \land q')])!.implies(), isFalse);
    });

    test('de Morgan and the like', () {
      for (final pair in [
        (r'\neg(p \land q)', r'\neg p \lor \neg q'),
        (r'\neg(p \lor q)', r'\neg p \land \neg q'),
        (r'p \to q', r'\neg q \to \neg p'),
        (r'p \leftrightarrow q', r'(p \to q) \land (q \to p)'),
        (r'p \oplus q', r'(p \lor q) \land \neg(p \land q)'),
      ]) {
        expect(buildTruthTable([f(pair.$1), f(pair.$2)])!.equivalent, isTrue, reason: '$pair');
      }
    });
  });

  group('other forms', () {
    test('the numbers of the rows', () {
      final table = t(r'p \to q');
      expect(table.minterms(), [0, 1, 3]);
      expect(table.maxterms(), [2]);
    });

    test('canonical forms', () {
      final table = t(r'p \to q');
      expect(logicText(table.canonicalSumOfProducts()!), '¬p ∧ ¬q ∨ ¬p ∧ q ∨ p ∧ q');
      expect(logicText(table.canonicalProductOfSums()!), '¬p ∨ q');
      expect(t(r'p \land \neg p').canonicalSumOfProducts(), isNull);
    });

    test('the shortest sum of products', () {
      expect(logicText(t(r'p \to q').minimalSumOfProducts()!), '¬p ∨ q');
      expect(logicText(t(r'(p \land q) \lor (p \land \neg q)').minimalSumOfProducts()!), 'p');
      expect(logicText(t(r'p \oplus q').minimalSumOfProducts()!), '¬p ∧ q ∨ p ∧ ¬q');
      expect(logicText(t(r'p \lor \neg p').minimalSumOfProducts()!), '⊤');
      expect(t(r'p \land \neg p').minimalSumOfProducts(), isNull);
      // a classic: abc + abc' + a'bc + ab'c = ab + ac + bc (majority)
      final majority = t(r'(a \land b) \lor (a \land c) \lor (b \land c)');
      final sum = majority.minimalSumOfProducts()!;
      expect(logicText(sum).split('∨').length, 3);
      // it is the same function
      expect(buildTruthTable([f(r'(a \land b) \lor (a \land c) \lor (b \land c)'), sum])!.equivalent, isTrue);
    });

    test('the shortest product of sums', () {
      expect(logicText(t(r'p \land q').minimalProductOfSums()!), 'p ∧ q');
      expect(logicText(t(r'p \to q').minimalProductOfSums()!), '¬p ∨ q');
      expect(logicText(t(r'p \land \neg p').minimalProductOfSums()!), '⊥');
      expect(t(r'p \lor \neg p').minimalProductOfSums(), isNull);
    });

    test('both minimal forms are the same function, for many formulas', () {
      for (final s in [r'p \oplus q \oplus r', r'(p \to q) \to r', r'p \leftrightarrow (q \oplus r)', r'(a \lor b) \land (c \lor d) \land \neg(a \land d)', r'\neg(a \to (b \to c))']) {
        final table = t(s);
        final sum = table.minimalSumOfProducts();
        final product = table.minimalProductOfSums();
        if (sum != null) expect(buildTruthTable([f(s), sum])!.equivalent, isTrue, reason: 'sum of products of $s');
        if (product != null) expect(buildTruthTable([f(s), product])!.equivalent, isTrue, reason: 'product of sums of $s');
        final canonical = table.canonicalSumOfProducts();
        if (canonical != null) expect(buildTruthTable([f(s), canonical])!.equivalent, isTrue);
      }
    });
  });

  group('writing a formula', () {
    test('brackets only where the binding needs them', () {
      expect(logicText(f(r'(p \land q) \lor r')), 'p ∧ q ∨ r');
      expect(logicText(f(r'p \land (q \lor r)')), 'p ∧ (q ∨ r)');
      expect(logicText(f(r'(p \to q) \to r')), '(p → q) → r');
      expect(logicText(f(r'p \to (q \to r)')), 'p → q → r');
      expect(logicText(f(r'\neg(p \land q)')), '¬(p ∧ q)');
      expect(logicText(f(r'\neg\neg p')), '¬¬p');
      expect(logicTex(f(r'p \leftrightarrow q')), r'p \leftrightarrow q');
    });

    test('what is written reads back as the same formula', () {
      for (final s in [r'(p \to q) \to r', r'p \to (q \to r)', r'\neg(p \lor q) \land r', r'p \oplus (q \land r)', r'(p \oplus q) \lor r', r'(p \uparrow q) \uparrow r', r'p \leftrightarrow (q \leftrightarrow r)']) {
        final a = f(s);
        final again = parseFormulaText(logicTex(a))!.formulas.single;
        expect(buildTruthTable([a, again])!.equivalent, isTrue, reason: s);
        expect(logicTex(again), logicTex(a), reason: s);
      }
    });
  });

  group('as text', () {
    test('markdown', () {
      expect(t(r'p \to q').markdown(), '| p | q | **p → q** |\n|:-:|:-:|:-:|\n| 0 | 0 | 1 |\n| 0 | 1 | 1 |\n| 1 | 0 | 0 |\n| 1 | 1 | 1 |');
      expect(t('p & q').markdown(letters: true), contains('| T | T | T |'));
    });

    test('latex', () {
      final tex = t('p & q').latex();
      expect(tex, startsWith(r'\begin{tabular}{cc|c}'));
      expect(tex, contains(r'$p$ & $q$ & $p \land q$ \\ \hline'));
      expect(tex, endsWith(r'\end{tabular}'));
    });
  });
}
