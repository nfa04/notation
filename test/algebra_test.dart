import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/equation_solver.dart';
import 'package:notes/algebra/latex_parser.dart';

void main() {
  String solve(String eq, String v) {
    final s = solveEquation(eq, v);
    return s.solutions.isEmpty ? s.note! : s.latex;
  }

  group('reading LaTeX', () {
    test('numbers, powers, fractions and roots', () {
      expect(evalLatex(r'2x^2 + 3', {'x': 2}), 11);
      expect(evalLatex(r'\frac{1}{2}x', {'x': 6}), 3);
      expect(evalLatex(r'\frac12 + \frac{3}{4}'), 1.25);
      expect(evalLatex(r'\sqrt{16} + \sqrt[3]{27}'), closeTo(7, 1e-9));
      expect(evalLatex(r'-x^{2}', {'x': 3}), -9);
      expect(evalLatex(r'2 \cdot 3 \times 4'), 24);
      expect(evalLatex(r'(a+b)(a-b)', {'a': 5, 'b': 3}), 16);
      expect(evalLatex(r'\left( 1 + 2 \right)^2'), 9);
    });

    test('implicit multiplication and subscripts', () {
      expect(evalLatex('xy', {'x': 3, 'y': 4}), 12);
      expect(evalLatex(r'x_{1} + x_2', {'x_{1}': 1, 'x_{2}': 2}), 3);
      expect(evalLatex(r'2\pi'), closeTo(6.2831853, 1e-6));
      expect(evalLatex(r'e^{1}'), closeTo(2.7182818, 1e-6));
      expect(evalLatex(r'\sin(0) + \cos 0'), 1);
    });

    test('garbage is refused with a message', () {
      expect(() => parseEquation('x ='), throwsA(isA<ParseException>()));
      expect(() => parseEquation(r'x = \unknown{3}'), throwsA(isA<ParseException>()));
      expect(() => parseEquation('x + 1'), throwsA(isA<ParseException>()));
    });
  });

  group('solving', () {
    test('linear', () {
      expect(solve('2x + 3 = 11', 'x'), 'x = 4');
      expect(solve(r'\frac{x}{3} = 2', 'x'), 'x = 6');
      expect(solve('3x = 1', 'x'), r'x = \frac{1}{3}');
      expect(solve('x + x = 5', 'x'), r'x = \frac{5}{2}');
    });

    test('letters stay letters', () {
      expect(solve('E = mc^2', 'm'), r'm = \frac{E}{c^{2}}');
      expect(solve('v = at + b', 't'), r't = \frac{v - b}{a}');
      expect(solve('y = mx + c', 'x'), r'x = \frac{y - c}{m}');
    });

    test('the variables offered', () {
      expect(equationVariables('E = mc^2'), ['E', 'm', 'c']);
      expect(equationVariables('x + 1'), isEmpty);
      expect(equationVariables(r'\pi r^2 = A'), ['r', 'A']);
    });

    test('quadratic', () {
      expect(solve('x^2 - 5x + 6 = 0', 'x'), r'x = 3 \;\text{or}\; x = 2');
      expect(solve('x^2 = 9', 'x'), r'x = 3 \;\text{or}\; x = -3');
      expect(solve('x^2 - 2x + 1 = 0', 'x'), 'x = 1');
      expect(solve('x^2 + 1 = 0', 'x'), 'There is no real solution.');
      expect(solve('x^2 + x - 1 = 0', 'x'), contains(r'\sqrt{5}'));
      expect(solve('x^2 + x - 1 = 0', 'x'), contains(r'\approx 0.618034'));
    });

    test('quadratic with letters gives the formula', () {
      expect(solve('ax^2 + bx + c = 0', 'x'), contains(r'\sqrt{b^{2} - 4ac}'));
    });

    test('no or every solution', () {
      expect(solve('x + 1 = x + 2', 'x'), 'There is no solution.');
      expect(solve('2x = x + x', 'x'), 'Every value of x solves it.');
    });

    test('numeric fallback', () {
      expect(solve(r'\sin(x) = 0.5', 'x'), contains(r'\approx 0.523599'));
      expect(solve(r'x^3 - 6x^2 + 11x - 6 = 0', 'x'), r'x = 1 \;\text{or}\; x = 2 \;\text{or}\; x = 3');
      expect(solve(r'\frac{1}{x} = 4', 'x'), 'x = \\frac{1}{4}');
      expect(solve(r'e^{x} = 5', 'x'), contains(r'\approx 1.60944'));
    });

    test('an equation with thousands of solutions shows the ones nearest zero', () {
      // (the search went from -1000 up and stopped at a thousand roots: these came out near -687 and -968)
      expect(solve(r'\sin(10x) = 0.5', 'x'), allOf(contains(r'\approx 0.0523599'), contains(r'\approx 0.261799')));
      expect(solve(r'\cos(100x) = 0', 'x'), allOf(contains(r'\approx -0.015708'), contains(r'\approx 0.015708')));
      expect(solveEquation(r'\cos(100x) = 0', 'x').note, contains('more solutions'));
    });

    test('what it cannot do says so', () {
      expect(() => solveEquation(r'\sin(x) = a', 'x'), throwsA(isA<SolveException>()));
      expect(() => solveEquation('x = 1', 'y'), throwsA(isA<SolveException>()));
    });
  });
}
