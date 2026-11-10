import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/checker.dart';
import 'package:notes/algebra/latex_parser.dart';

Verdict? one(String line) => checkLines([line]).single.verdict;
List<Verdict?> steps(List<String> lines) => [for (final c in checkLines(lines)) c.verdict];

void main() {
  group('values x_i and their mean', () {
    test('a sum of the values is looked up, not a letter', () {
      expect(one(r'\sum_{i=1}^{n} x_i = \sum_{j=1}^{n} x_j'), Verdict.right);
      expect(one(r'\sum_{i=1}^{n} (x_i + 1) = \sum_{i=1}^{n} x_i + n'), Verdict.right);
      expect(one(r'\sum_{i=1}^{n} (x_i + 1) = \sum_{i=1}^{n} x_i + 1'), Verdict.wrong);
      expect(one(r'\sum_{i=1}^{n} 2 x_i = 2\sum_{i=1}^{n} x_i'), Verdict.right);
      expect(one(r'\sum_{i=1}^{3} x_i = x_1 + x_2 + x_3'), Verdict.right);
      // (with other letters on one side it is an equation in x_1, x_2 ..., not a claim)
      expect(one(r'\sum_{i=1}^{3} x_i = x_1 + x_2'), isNull);
    });

    test('the mean as a bar', () {
      expect(one(r'\sum_{i=1}^{n} (x_i - \bar{x}) = 0'), Verdict.right);
      expect(one(r'\sum_{i=1}^{n} (x_i - \bar{x}) = 1'), Verdict.wrong);
      expect(one(r'\bar{x} = \frac{1}{n}\sum_{i=1}^{n} x_i'), Verdict.right);
      expect(one(r'n\bar{x} = \sum_{i=1}^{n} x_i'), Verdict.right);
      expect(one(r'\overline{x} = \frac{1}{n}\sum_{i=1}^{n} x_i'), Verdict.right);
    });

    test('the sum of squares and the variance', () {
      expect(one(r'\sum_{i=1}^{n} (x_i - \bar{x})^2 = \sum_{i=1}^{n} x_i^2 - n\bar{x}^2'), Verdict.right);
      expect(one(r'\sum_{i=1}^{n} (x_i - \bar{x})^2 = \sum_{i=1}^{n} x_i^2 - \bar{x}^2'), Verdict.wrong);
      expect(one(r'\sum_{i=1}^{n} (x_i - \bar{x})^2 = \sum_{i=1}^{n} x_i^2 - \frac{1}{n}\left(\sum_{i=1}^{n} x_i\right)^2'), Verdict.right);
      expect(
        steps([
          r'\sum_{i=1}^{n} (x_i - \bar{x})^2',
          r'= \sum_{i=1}^{n} (x_i^2 - 2 x_i \bar{x} + \bar{x}^2)',
          r'= \sum_{i=1}^{n} x_i^2 - 2\bar{x}\sum_{i=1}^{n} x_i + n\bar{x}^2',
          r'= \sum_{i=1}^{n} x_i^2 - n\bar{x}^2',
        ]),
        [null, Verdict.right, Verdict.right, Verdict.right],
      );
      expect(
        steps([
          r'\sum_{i=1}^{n} (x_i - \bar{x})^2',
          r'= \sum_{i=1}^{n} (x_i^2 - 2 x_i \bar{x} + \bar{x}^2)',
          r'= \sum_{i=1}^{n} x_i^2 - 2\bar{x}\sum_{i=1}^{n} x_i - n\bar{x}^2',
        ]).last,
        Verdict.wrong,
      );
    });

    test('formulas that define a letter are not claims', () {
      expect(one(r'\sigma^2 = \frac{1}{n}\sum_{i=1}^{n}(x_i-\mu)^2'), isNull);
      expect(one(r's^2 = \frac{1}{n-1}\sum_{i=1}^{n}(x_i-\bar{x})^2'), isNull);
    });

    test('a bar without values is a letter', () {
      expect(one(r'\bar{x} = 5'), isNull);
      expect(one(r'\bar{x} + \bar{x} = 2\bar{x}'), Verdict.right);
      expect(one(r'z = \frac{\bar{x} - \mu}{\sigma / \sqrt{n}}'), isNull);
      expect(
        steps([r'z = \frac{\bar{x} - \mu}{\sigma / \sqrt{n}}', r'= \frac{\sqrt{n}(\bar{x} - \mu)}{\sigma}']).last,
        Verdict.right,
      );
      expect(
        steps([r'z = \frac{\bar{x} - \mu}{\sigma / \sqrt{n}}', r'= \frac{\sqrt{n}(\bar{x} - \mu)}{\sigma^2}']).last,
        Verdict.wrong,
      );
      expect(one(r'\hat{p} + (1 - \hat{p}) = 1'), Verdict.right);
    });

    test('the mean is the same value wherever it is written', () {
      expect(evalLatex(r'\sum_{i=1}^{n} x_i', {'n': 1}), isNot(0));
      expect(withSampleMeans([r'\bar{x} + x_1'], () => evalLatex(r'\bar{x}', {'n': 1})), closeTo(evalLatex(r'x_1', {'x_{1}': evalLatex(r'\sum_{i=1}^{n} x_i', {'n': 1})}), 1e-9));
    });
  });

  group('integrals to infinity', () {
    test('the ones that settle on a value', () {
      expect(one(r'\int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi}'), Verdict.right);
      expect(one(r'\int_{0}^{\infty} e^{-x} \, dx = 1'), Verdict.right);
      expect(one(r'\int_0^\infty x e^{-x} dx = 1'), Verdict.right);
      expect(one(r'\int_1^\infty \frac{1}{x^2} dx = 1'), Verdict.right);
      expect(one(r'\int_{-\infty}^{0} e^{x} dx = 1'), Verdict.right);
      expect(one(r'\int_{-\infty}^{\infty} \frac{1}{\sqrt{2\pi}} e^{-\frac{x^2}{2}} dx = 1'), Verdict.right);
      expect(one(r'\int_{-\infty}^{\infty} \frac{1}{\pi(1+x^2)} dx = 1'), Verdict.right);
    });

    test('a wrong value is flagged, a divergent integral is left alone', () {
      expect(one(r'\int_{-\infty}^{\infty} e^{-x^2} \, dx = \pi'), Verdict.wrong);
      expect(one(r'\int_0^\infty e^{-x} dx = 2'), Verdict.wrong);
      expect(one(r'\int_1^\infty \frac{1}{x} dx = 5'), isNull);
      expect(one(r'\int_0^\infty e^{-\lambda x} dx = 1'), isNull);
    });
  });

  group('numbers from a statistics course', () {
    test('probabilities worked out', () {
      expect(one(r'P(X=3) = \binom{10}{3} 0.5^{10} \approx 0.1172'), Verdict.rounded);
      expect(one(r'P(X=3) = \binom{10}{3} 0.5^{10} = 0.2'), Verdict.wrong);
      expect(one(r'P(X=2) = e^{-3}\frac{3^2}{2!} \approx 0.224'), Verdict.rounded);
      expect(one(r'P(X=2) = e^{-3}\frac{3^2}{2!} \approx 0.3'), Verdict.wrong);
      expect(one(r'P(Y=1) = 1 - 0.95^{3} = 0.1426'), Verdict.rounded);
      expect(one(r'z = \frac{52 - 50}{10/\sqrt{25}} = 1'), Verdict.right);
      expect(one(r'z = \frac{52 - 50}{10/\sqrt{25}} = 2'), Verdict.wrong);
    });

    test('the table of the normal distribution', () {
      expect(one(r'\Phi(1.96) \approx 0.975'), Verdict.rounded);
      expect(one(r'\Phi(0) = 0.5'), Verdict.right);
      expect(one(r'\Phi(1) \approx 0.8413'), Verdict.rounded);
      expect(one(r'\Phi(1) \approx 0.9413'), Verdict.wrong);
      expect(one(r'\Phi(-1.5) = 1 - \Phi(1.5)'), Verdict.right);
      expect(one(r'\Phi(x) = 1 - \Phi(-x)'), isNull);
      expect(evalLatex(r'\Phi(1.96)'), closeTo(0.9750021, 1e-6));
      expect(evalLatex(r'\Phi(4)'), closeTo(0.99996833, 1e-8));
      expect(evalLatex(r'\Phi(-4)'), closeTo(3.167e-5, 1e-8));
    });

    test('percent', () {
      expect(one(r'\frac{3}{8} = 37.5\%'), Verdict.right);
      expect(one(r'\frac{3}{8} = 38\%'), Verdict.rounded);
      expect(one(r'\frac{3}{8} = 50\%'), Verdict.wrong);
      expect(one(r'0.4 \cdot 0.5 = 0.2 = 20\%'), Verdict.right);
      expect(one(r'0.4 \cdot 0.5 = 0.2 = 30\%'), Verdict.wrong);
    });

    test('a figure after ≈ is rounded or cut off, not just near', () {
      expect(one(r'\sqrt{10} \approx 3.16'), Verdict.rounded);
      expect(one(r'\sqrt{10} \approx 3.17'), Verdict.wrong);
      expect(one(r'\frac{2}{3} \approx 0.67'), Verdict.rounded);
      expect(one(r'\frac{2}{3} \approx 0.66'), Verdict.rounded);
      expect(one(r'\frac{2}{3} \approx 0.65'), Verdict.wrong);
    });
  });

  group('expectation, variance and covariance', () {
    test('what holds for every random variable', () {
      expect(one(r'E[aX + b] = aE[X] + b'), Verdict.right);
      expect(one(r'E[X + Y] = E[X] + E[Y]'), Verdict.right);
      expect(one(r'\mathbb{E}[X + Y] = \mathbb{E}[X] + \mathbb{E}[Y]'), Verdict.right);
      expect(one(r'\mathrm{Var}(X) = E[X^2] - E[X]^2'), Verdict.right);
      expect(one(r'\operatorname{Var}(X) = E[X^2] - (E[X])^2'), Verdict.right);
      expect(one(r'\mathrm{Var}(aX + b) = a^2 \mathrm{Var}(X)'), Verdict.right);
      expect(one(r'\mathrm{Cov}(X, Y) = E[XY] - E[X]E[Y]'), Verdict.right);
      expect(one(r'\mathrm{Var}(X + Y) = \mathrm{Var}(X) + \mathrm{Var}(Y) + 2\mathrm{Cov}(X, Y)'), Verdict.right);
      expect(one(r'\mathrm{Var}(X - Y) = \mathrm{Var}(X) + \mathrm{Var}(Y) - 2\mathrm{Cov}(X, Y)'), Verdict.right);
    });

    test('what fails for random variables is flagged', () {
      final bad = checkLines([r'\mathrm{Var}(X) = E[X^2] + E[X]^2']).single;
      expect(bad.verdict, Verdict.wrong);
      // (with other letters on one side it is an equation, not a claim)
      expect(one(r'E[aX + b] = aE[X]'), isNull);
      expect(one(r'E[aX + b] = aE[X] + 2b'), Verdict.wrong);
      expect(one(r'\mathrm{Var}(aX) = a \mathrm{Var}(X)'), Verdict.wrong);
      expect(one(r'\mathrm{Var}(aX + b) = a^2 \mathrm{Var}(X) + b'), Verdict.wrong);
      expect(one(r'\mathrm{Var}(X - Y) = \mathrm{Var}(X) - \mathrm{Var}(Y)'), Verdict.wrong);
      expect(one(r'E[X^2] = E[X]^2'), Verdict.wrong);
    });

    test('what needs independence is not called wrong', () {
      expect(one(r'E[XY] = E[X]E[Y]'), isNull);
      expect(one(r'\mathrm{Var}(X + Y) = \mathrm{Var}(X) + \mathrm{Var}(Y)'), isNull);
    });

    test('a derivation', () {
      expect(
        steps([
          r'\mathrm{Var}(X) = E[(X - E[X])^2]',
          r'= E[X^2 - 2X E[X] + E[X]^2]',
          r'= E[X^2] - 2E[X]E[X] + E[X]^2',
          r'= E[X^2] - E[X]^2',
        ]).skip(1),
        [Verdict.right, Verdict.right, Verdict.right],
      );
      expect(
        steps([
          r'\mathrm{Var}(X) = E[(X - E[X])^2]',
          r'= E[X^2 - 2X E[X] + E[X]^2]',
          r'= E[X^2] - 2E[X]E[X] + E[X]^2',
          r'= E[X^2] + E[X]^2',
        ]).last,
        Verdict.wrong,
      );
    });

    test('a definition or a number is not a claim', () {
      expect(one(r'\mu = E[X]'), isNull);
      expect(one(r'E[X] = 5'), isNull);
      expect(one(r'\sigma^2 = \mathrm{Var}(X)'), isNull);
      expect(one(r'P(x) = x^2 + 1'), isNull);
    });
  });

  group('probability', () {
    test('what holds for every event', () {
      expect(one(r'P(A \cup B) = P(A) + P(B) - P(A \cap B)'), Verdict.right);
      expect(one(r'P(A^c) = 1 - P(A)'), Verdict.right);
      expect(one(r"P(A') = 1 - P(A)"), Verdict.right);
      expect(one(r'P(\bar{A}) = 1 - P(A)'), Verdict.right);
      expect(one(r'P(A) + P(A^c) = 1'), Verdict.right);
      expect(one(r'P(A \setminus B) = P(A) - P(A \cap B)'), Verdict.right);
      expect(one(r'P(A \cap B) = P(A \mid B) P(B)'), Verdict.right);
      expect(one(r'P(A \mid B) = \frac{P(A \cap B)}{P(B)}'), Verdict.right);
      expect(one(r'P(A|B) = \frac{P(B|A)P(A)}{P(B)}'), Verdict.right);
      expect(one(r'P(A \cup B \cup C) = P(A) + P(B) + P(C) - P(A \cap B) - P(A \cap C) - P(B \cap C) + P(A \cap B \cap C)'), Verdict.right);
      expect(one(r'P(B) = P(B \mid A)P(A) + P(B \mid A^c)P(A^c)'), Verdict.right);
      expect(one(r'P((A \cup B)^c) = P(A^c \cap B^c)'), Verdict.right);
    });

    test('what fails is flagged', () {
      expect(one(r'P(A^c) = P(A) - 1'), Verdict.wrong);
      expect(one(r'P(A \cup B) = P(A) + P(B) - P(A)P(B) + 0.1'), Verdict.wrong);
      expect(one(r'P(A|B) = \frac{P(A|B)P(A)}{P(B)}'), Verdict.wrong);
      expect(one(r'P(A \mid B) = \frac{P(B \mid A)}{P(B)}'), Verdict.wrong);
      expect(one(r'P(A \cap B) = P(A) + P(B)'), Verdict.wrong);
    });

    test('what needs independent or exclusive events is not called wrong', () {
      expect(one(r'P(A \cap B) = P(A)P(B)'), isNull);
      expect(one(r'P(A \cup B) = P(A) + P(B)'), isNull);
      expect(one(r'P(A \mid B) = P(A)'), isNull);
    });

    test('comparisons of random variables are events', () {
      expect(one(r'P(X > 2) = 1 - P(X \leq 2)'), Verdict.right);
      expect(one(r'P(X \le 3) = P(X < 3) + P(X = 3)'), Verdict.right);
      expect(one(r'P(X \ge 2) = P(X > 2) + P(X = 2)'), Verdict.right);
      expect(one(r'P(X > 2) = 1 - P(X < 2)'), Verdict.wrong);
      expect(one(r'P(X \leq 3) = P(X < 3)'), Verdict.wrong);
    });

    test('a probability that is worked out and a function called P', () {
      expect(one(r'P(X = 3) = \binom{10}{3} 0.5^{10} \approx 0.1172'), Verdict.rounded);
      expect(one(r'P(x) = x^2 + 1'), isNull);
      expect(one(r'P(A) = 0.3'), isNull);
    });
  });
}
