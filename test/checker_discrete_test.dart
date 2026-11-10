import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/checker.dart';
import 'package:notes/algebra/latex_parser.dart';

Verdict? one(String line) => checkLines([line]).single.verdict;
List<Verdict?> steps(List<String> lines) => [for (final c in checkLines(lines)) c.verdict];

void main() {
  group('sums and products with a letter as the limit', () {
    test('they are worked out for whole numbers', () {
      expect(evalLatex(r'\sum_{k=1}^{n} k', {'n': 10}), 55);
      expect(evalLatex(r'\sum_{k=0}^{n} 2^k', {'n': 5}), 63);
      expect(evalLatex(r'\prod_{k=1}^{n} k', {'n': 5}), 120);
      expect(evalLatex(r'\sum_{i=1}^{n}\sum_{j=1}^{i} 1', {'n': 4}), 10);
      expect(evalLatex(r'\sum_{k=1}^{n} k', {'n': 2.5}).isNaN, isTrue);
      expect(evalLatex(r'n!', {'n': 5}), 120);
      expect(evalLatex(r'(n+1)!', {'n': 4}), 120);
      expect(evalLatex(r'\binom{n}{2}', {'n': 6}), 15);
    });

    test('the closed forms people prove', () {
      expect(one(r'\sum_{k=1}^{n} k = \frac{n(n+1)}{2}'), Verdict.right);
      expect(one(r'\sum_{k=1}^{n} k^2 = \frac{n(n+1)(2n+1)}{6}'), Verdict.right);
      expect(one(r'\sum_{k=0}^{n} 2^k = 2^{n+1} - 1'), Verdict.right);
      expect(one(r'\sum_{i=1}^{n} (2i-1) = n^2'), Verdict.right);
      expect(one(r'\prod_{k=1}^{n} k = n!'), Verdict.right);
      expect(one(r'\sum_{k=1}^{n} \binom{n}{k} = 2^n - 1'), Verdict.right);
    });

    test('a wrong closed form is flagged, with an example', () {
      final bad = checkLines([r'\sum_{k=1}^{n} k = \frac{n^2}{2}']).single;
      expect(bad.verdict, Verdict.wrong);
      expect(bad.reason, Reason.identity);
      expect(bad.counter, contains('n ='));
      expect(one(r'\sum_{k=1}^{n} k^2 = \frac{n(n+1)(2n+2)}{6}'), Verdict.wrong);
      expect(one(r'\sum_{k=0}^{n} 2^k = 2^{n+1}'), Verdict.wrong);
      expect(one(r'\prod_{k=1}^{n} k = (n+1)!'), Verdict.wrong);
      expect(one(r'(n+1)! = (n+1) + n!'), Verdict.wrong);
    });

    test('the induction step', () {
      expect(
        steps([
          r'\sum_{k=1}^{n+1} k = \sum_{k=1}^{n} k + (n+1)',
          r'= \frac{n(n+1)}{2} + (n+1)',
          r'= \frac{(n+1)(n+2)}{2}',
        ]),
        [Verdict.right, Verdict.right, Verdict.right],
      );
      expect(
        steps([
          r'\sum_{k=1}^{n+1} k = \sum_{k=1}^{n} k + (n+1)',
          r'= \frac{n(n+1)}{2} + (n+1)',
          r'= \frac{(n+1)(n+3)}{2}',
        ]).last,
        Verdict.wrong,
      );
      expect(one(r'(n+1)! = (n+1) \cdot n!'), Verdict.right);
    });

    test('solving for the limit is no claim', () {
      expect(one(r'\sum_{k=1}^{n} k = 55'), isNull);
    });
  });

  group('inequalities', () {
    test('numbers', () {
      expect(one(r'3 < 5'), Verdict.right);
      expect(one(r'2^{10} > 1000'), Verdict.right);
      expect(one(r'1 < 2 \le 2 < 3'), Verdict.right);
      expect(one(r'\sqrt{2} < 1.5'), Verdict.right);
      final bad = checkLines([r'5 < 3']).single;
      expect(bad.verdict, Verdict.wrong);
      expect(bad.reason, Reason.order);
      expect(bad.expected, '5 > 3');
      expect(one(r'4 \ge 4'), Verdict.right);
      expect(one(r'4 > 4'), Verdict.wrong);
      expect(one(r'2 \neq 3'), Verdict.right);
    });

    test('solving one step at a time', () {
      expect(steps([r'2x + 3 < 11', r'2x < 8', r'x < 4']), [null, Verdict.right, Verdict.right]);
      expect(steps([r'3x \le 12', r'x \le 4']).last, Verdict.right);
      expect(steps([r'x - 2 \ge 5', r'x \ge 7']).last, Verdict.right);
    });

    test('dividing by a negative number turns the sign over', () {
      final bad = checkLines([r'-2x < 6', r'x < -3']).last;
      expect(bad.verdict, Verdict.wrong);
      expect(bad.reason, Reason.setDiffers);
      expect(bad.expected, 'x > -3');
      expect(steps([r'-2x < 6', r'x > -3']).last, Verdict.right);
    });

    test('a strict sign against a loose one', () {
      expect(steps([r'2x < 8', r'x \le 4']).last, Verdict.widened);
      expect(steps([r'2x \le 8', r'x < 4']).last, Verdict.lost);
    });

    test('squares: a branch is lost, an arrow allows more', () {
      final lost = checkLines([r'x^2 \ge 4', r'x \ge 2']).last;
      expect(lost.verdict, Verdict.lost);
      expect(lost.expected, r'x \le -2');
      expect(steps([r'x^2 \ge 4', r'x \le -2 \text{ or } x \ge 2']).last, Verdict.right);
      expect(steps([r'x < 2', r'\Rightarrow x^2 < 4']).last, Verdict.wrong);
      expect(steps([r'x^2 < 4', r'\Rightarrow -2 < x < 2']).last, Verdict.right);
      expect(steps([r'x < 2', r'\Rightarrow x < 5']).last, Verdict.right);
      expect(steps([r'x < 5', r'\Rightarrow x < 2']).last, Verdict.wrong);
    });

    test('fractions and other letters', () {
      expect(steps([r'3x > 8', r'x > \frac{8}{3}']).last, Verdict.right);
      expect(steps([r'x + y < 3', r'x < 3 - y']).last, Verdict.right);
      expect(steps([r'x + y < 3', r'x > 3 - y']).last, Verdict.wrong);
    });

    test('what cannot be said stays quiet', () {
      expect(one(r'x \in (1, 3)'), isNull);
      expect(one(r'x < y'), isNull);
      expect(steps([r'x^2 = 4', r'x < 3']).last, isNull);
    });
  });

  group('matrices', () {
    const a = r'\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}';
    const b = r'\begin{pmatrix} 0 & 1 \\ 1 & 0 \end{pmatrix}';

    test('products, sums and numbers', () {
      expect(one('$a \\cdot $b = \\begin{pmatrix} 2 & 1 \\\\ 4 & 3 \\end{pmatrix}'), Verdict.right);
      final bad = checkLines(['$a $b = \\begin{pmatrix} 2 & 1 \\\\ 3 & 4 \\end{pmatrix}']).single;
      expect(bad.verdict, Verdict.wrong);
      expect(bad.reason, Reason.matrix);
      expect(bad.expected, contains('2 & 1'));
      expect(one('$a + $b = \\begin{pmatrix} 1 & 3 \\\\ 4 & 4 \\end{pmatrix}'), Verdict.right);
      expect(one('2 $a = \\begin{pmatrix} 2 & 4 \\\\ 6 & 8 \\end{pmatrix}'), Verdict.right);
      expect(one('\\frac{1}{2} $a = \\begin{pmatrix} 0.5 & 1 \\\\ 1.5 & 2 \\end{pmatrix}'), Verdict.right);
    });

    test('transpose, inverse, determinant, power', () {
      expect(one('$a^T = \\begin{pmatrix} 1 & 3 \\\\ 2 & 4 \\end{pmatrix}'), Verdict.right);
      expect(one('$a^{\\top} = \\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}'), Verdict.wrong);
      expect(one('\\det $a = -2'), Verdict.right);
      expect(one('\\det $a = 2'), Verdict.wrong);
      expect(one('\\begin{vmatrix} 1 & 2 \\\\ 3 & 4 \\end{vmatrix} = -2'), Verdict.right);
      expect(one('$a^{-1} = \\begin{pmatrix} -2 & 1 \\\\ 1.5 & -0.5 \\end{pmatrix}'), Verdict.right);
      expect(one('$a^2 = \\begin{pmatrix} 7 & 10 \\\\ 15 & 22 \\end{pmatrix}'), Verdict.right);
      expect(one('$a^2 = \\begin{pmatrix} 7 & 10 \\\\ 15 & 23 \\end{pmatrix}'), Verdict.wrong);
    });

    test('sizes that do not fit and a matrix with no inverse', () {
      const c = r'\begin{pmatrix} 1 & 2 & 3 \\ 4 & 5 & 6 \end{pmatrix}';
      final shape = checkLines(['$c $c = $a']).single;
      expect(shape.verdict, Verdict.wrong);
      expect(shape.reason, Reason.shape);
      expect(shape.counter, contains(r'2 \times 3'));
      expect(checkLines(['$a + $c = $a']).single.reason, Reason.shape);
      final singular = checkLines([r'\begin{pmatrix} 1 & 2 \\ 2 & 4 \end{pmatrix}^{-1} = ' + a]).single;
      expect(singular.reason, Reason.singular);
      expect(one('$c $c^T = \\begin{pmatrix} 14 & 32 \\\\ 32 & 77 \\end{pmatrix}'), Verdict.right);
    });

    test('letters in a matrix', () {
      expect(one(r'\begin{pmatrix} x & 1 \\ 0 & x \end{pmatrix}^2 = \begin{pmatrix} x^2 & 2x \\ 0 & x^2 \end{pmatrix}'), Verdict.right);
      expect(one(r'\begin{pmatrix} x & 1 \\ 0 & x \end{pmatrix}^2 = \begin{pmatrix} x^2 & x \\ 0 & x^2 \end{pmatrix}'), Verdict.wrong);
      expect(one(r'\det \begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad - bc'), Verdict.right);
      expect(one(r'\det \begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad + bc'), Verdict.wrong);
    });

    test('a letter that names a matrix', () {
      expect(steps(['A = $a', 'B = $b', 'A B = \\begin{pmatrix} 2 & 1 \\\\ 4 & 3 \\end{pmatrix}', '\\det A = -2']), [null, null, Verdict.right, Verdict.right]);
      expect(steps(['A = $a', 'A^T = \\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}']).last, Verdict.wrong);
      expect(steps(['A = $a', r'A A^{-1} = I']).last, Verdict.right);
      expect(steps(['A = $a', r'A + I = \begin{pmatrix} 2 & 2 \\ 3 & 5 \end{pmatrix}']).last, Verdict.right);
      expect(steps(['A = $a, B = $b', 'A B = \\begin{pmatrix} 2 & 1 \\\\ 4 & 3 \\end{pmatrix}']).last, Verdict.right);
      expect(steps(['A = $a', r'\mathbf{A}^2 = \begin{pmatrix} 7 & 10 \\ 15 & 22 \end{pmatrix}']).last, Verdict.right);
    });

    test('a line that goes on and a result that is asked for', () {
      expect(steps(['$a $b', '= \\begin{pmatrix} 2 & 1 \\\\ 4 & 3 \\end{pmatrix}']).last, Verdict.right);
      expect(
        steps(['$a $b = \\begin{pmatrix} 2 & 1 \\\\ 4 & 3 \\end{pmatrix}', '= \\begin{pmatrix} 2 & 1 \\\\ 4 & 4 \\end{pmatrix}']).last,
        Verdict.wrong,
      );
      expect(checkLines(['$a $b =']).single.answer, contains('2 & 1'));
    });

    test('the lines of a matrix are not cut up as the lines of the solution', () {
      expect(steps([r'x = 2', '$a $b = \\begin{pmatrix} 2 & 1 \\\\ 4 & 3 \\end{pmatrix}']).last, Verdict.right);
    });
  });

  group('rounding, remainders and divisors', () {
    test('they are worked out', () {
      expect(evalLatex(r'\lfloor 7/2 \rfloor'), 3);
      expect(evalLatex(r'\lceil 7/2 \rceil'), 4);
      expect(evalLatex(r'\left\lfloor -2.5 \right\rfloor'), -3);
      expect(evalLatex(r'⌊3.7⌋'), 3);
      expect(evalLatex(r'17 \bmod 5'), 2);
      expect(evalLatex(r'-3 \bmod 5'), 2);
      expect(evalLatex(r'17 \mod 5'), 2);
      expect(evalLatex(r'\gcd(12, 18)'), 6);
      expect(evalLatex(r'\gcd(12, 18, 8)'), 2);
      expect(evalLatex(r'\operatorname{lcm}(4, 6)'), 12);
      expect(evalLatex(r'\max(3, 7, 5)'), 7);
      expect(evalLatex(r'min(3, 7)'), 3);
      expect(evalLatex(r'a + b \bmod m', {'a': 4, 'b': 5, 'm': 6}), 3);
    });

    test('arithmetic lines', () {
      expect(one(r'17 \bmod 5 = 2'), Verdict.right);
      expect(one(r'17 \bmod 5 = 3'), Verdict.wrong);
      expect(one(r'\lfloor 7/2 \rfloor = 3'), Verdict.right);
      expect(one(r'\lceil 7/2 \rceil = 3'), Verdict.wrong);
      expect(one(r'\gcd(48, 18) = 6'), Verdict.right);
      expect(one(r'\gcd(48, 18) = 3'), Verdict.wrong);
      expect(one(r'\lcm(4, 6) = 12'), Verdict.right);
      expect(steps([r'\gcd(48, 18)', r'= \gcd(18, 48 \bmod 18)', r'= \gcd(18, 12)', r'= 6']).skip(1), [Verdict.right, Verdict.right, Verdict.right]);
      expect(steps([r'\gcd(48, 18)', r'= \gcd(18, 12)', r'= 4']).last, Verdict.wrong);
    });

    test('identities for whole numbers', () {
      expect(one(r'\lfloor n/2 \rfloor + \lceil n/2 \rceil = n'), Verdict.right);
      expect(one(r'\lfloor n/2 \rfloor + \lfloor n/2 \rfloor = n'), Verdict.wrong);
      expect(one(r'\gcd(a, b) = \gcd(b, a \bmod b)'), Verdict.right);
      expect(one(r'\gcd(a, b) = \gcd(b, a + b)'), Verdict.right);
      expect(one(r'\gcd(a, b) = \gcd(a, b + 1)'), Verdict.wrong);
      expect(one(r'(a + b) \bmod m = ((a \bmod m) + (b \bmod m)) \bmod m'), Verdict.right);
      expect(one(r'(a \cdot b) \bmod m = (a \bmod m) \cdot (b \bmod m)'), Verdict.wrong);
      expect(one(r'\gcd(a, b) \cdot \lcm(a, b) = a \cdot b'), Verdict.right);
      expect(one(r'\lfloor x \rfloor \le x'), isNull);
      expect(one(r'\lfloor x \rfloor = x'), isNull);
    });

    test('congruences', () {
      expect(one(r'17 \equiv 2 \pmod{5}'), Verdict.right);
      expect(one(r'17 \equiv 3 \pmod{5}'), Verdict.wrong);
      final bad = checkLines([r'17 \equiv 3 \pmod 5']).single;
      expect(bad.reason, Reason.congruence);
      expect(bad.expected, r'17 \equiv 2 \pmod{5}');
      expect(one(r'-1 \equiv 4 \pmod 5'), Verdict.right);
      expect(one(r'17 \equiv 2 \equiv -3 \pmod{5}'), Verdict.right);
      expect(one(r'7 \equiv 2 \equiv -3 \pmod{5}'), Verdict.right);
      expect(one(r'17 \equiv 12 \equiv 3 \pmod{5}'), Verdict.wrong);
      expect(one(r'17 \equiv 2 \ (\mathrm{mod}\ 5)'), Verdict.right);
      expect(one(r'a + m \equiv a \pmod{m}'), Verdict.right);
      expect(one(r'a + 1 \equiv a \pmod{m}'), Verdict.wrong);
      expect(one(r'n^2 \equiv n \pmod{n}'), Verdict.right);
      expect(one(r'a^2 \equiv a \pmod{2}'), Verdict.right);
      expect(one(r'a^2 \equiv a \pmod{3}'), Verdict.wrong);
    });
  });

  group('propositional logic', () {
    test('equivalences are checked by the truth table', () {
      expect(one(r'\neg (p \land q) \equiv \neg p \lor \neg q'), Verdict.right);
      expect(one(r'\neg (p \land q) \equiv \neg p \land \neg q'), Verdict.wrong);
      expect(one(r'p \to q \equiv \neg p \lor q'), Verdict.right);
      expect(one(r'p \to q \equiv q \to p'), Verdict.wrong);
      expect(one(r'p \land (p \lor q) \equiv p'), Verdict.right);
      expect(one(r'p \leftrightarrow q \equiv (p \to q) \land (q \to p)'), Verdict.right);
      expect(one(r'p \oplus q \equiv (p \lor q) \land \neg (p \land q)'), Verdict.right);
      expect(one(r'p \land \neg p \equiv \bot'), Verdict.right);
      expect(one(r'p \lor \neg p \equiv \top'), Verdict.right);
      expect(one(r'\overline{p \land q} \equiv \overline{p} \lor \overline{q}'), Verdict.right);
      expect(one(r'\neg p \lor q \Leftrightarrow p \to q'), Verdict.right);
      expect(one(r'\neg (p \lor q) = \neg p \land \neg q'), Verdict.right);
      expect(one(r'(p \land q) \lor r \equiv p \land (q \lor r)'), Verdict.wrong);
      expect(one(r'¬(p ∧ q) ≡ ¬p ∨ ¬q'), Verdict.right);
      expect(one(r'(p \land q)\prime \equiv p\prime \lor q\prime'), isNull);
    });

    test('the wrong one shows the row that tells them apart', () {
      final bad = checkLines([r'\neg (p \land q) \equiv \neg p \land \neg q']).single;
      expect(bad.verdict, Verdict.wrong);
      expect(bad.reason, Reason.notEquivalent);
      expect(bad.counter, r'p = 0,\; q = 1:\; 1 \neq 0');
    });

    test('implications', () {
      expect(one(r'p \land q \Rightarrow p'), Verdict.right);
      expect(one(r'p \Rightarrow p \land q'), Verdict.wrong);
      final bad = checkLines([r'p \Rightarrow p \land q']).single;
      expect(bad.reason, Reason.notImplied);
      expect(bad.counter, contains(r'\nRightarrow'));
      expect(one(r'(p \to q) \land p \Rightarrow q'), Verdict.right);
      expect(one(r'(p \to q) \land q \Rightarrow p'), Verdict.wrong);
      expect(one(r'p \Rightarrow p \lor q \Rightarrow q \lor p'), Verdict.right);
    });

    test('a derivation line by line', () {
      expect(
        steps([r'\neg (p \to q)', r'\equiv \neg (\neg p \lor q)', r'\equiv \neg \neg p \land \neg q', r'\equiv p \land \neg q']),
        [null, Verdict.right, Verdict.right, Verdict.right],
      );
      expect(steps([r'\neg (p \to q)', r'\equiv \neg p \lor \neg q']).last, Verdict.wrong);
      expect(steps([r'p \land (q \lor r)', r'\equiv (p \land q) \lor (p \land r)']).last, Verdict.right);
      expect(steps([r'p \land (q \lor r)', r'\Rightarrow p \land q']).last, Verdict.wrong);
    });

    test('what is no logic is read as it was', () {
      // a list of solutions with "or" is not a truth table
      expect(one(r'x = 2 \lor x = 3'), isNull);
      expect(steps([r'x^2 - 5x + 6 = 0', r'x = 2 \lor x = 3']).last, Verdict.right);
      expect(steps([r'x^2 - 5x + 6 = 0', r'x = 2 \lor x = 4']).last, isNot(Verdict.right));
      expect(one(r'x = a \lor x = b'), isNull);
      // the transpose is no truth
      expect(
        one(r'\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}^\top = \begin{pmatrix} 1 & 3 \\ 2 & 4 \end{pmatrix}'),
        Verdict.right,
      );
      // too many letters for a table
      expect(one(r'a \land b \land c \land d \land e \land f \land g \land h \land i \land j \land k \equiv \neg a'), isNull);
    });
  });

  group('notation that only looks like a claim (found in real labels)', () {
    test('a letter defined by a formula in logic', () {
      expect(one(r'g = g_{-1} \oplus g_{0} \oplus g_{1}'), isNull);
      expect(one(r'g \equiv a \oplus b'), isNull);
      expect(one(r'p \equiv p \land (p \lor q)'), Verdict.right);
      expect(one(r'p \lor (p \land q) \equiv p'), Verdict.right);
    });

    test('a number against a matrix is not judged', () {
      expect(
        one(r'\hat{q} = q_i i + q_j j + q_k k + q_r = \begin{bmatrix} q_i \\ q_j \\ q_k \\ q_r \end{bmatrix}'),
        isNull,
      );
      // (a reading that lost the hat)
      expect(one(r'q = q_i i + q_j j + q_k k + q_r = \begin{bmatrix} q_i \\ q_j \\ q_k \\ q_r \end{bmatrix}'), isNull);
    });
  });
}
