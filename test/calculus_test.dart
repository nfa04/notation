import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/calculator.dart';
import 'package:notes/algebra/equation_solver.dart';

void main() {
  String d(String f, [String v = 'x']) => calculate(f, CalcKind.derive, v).solutions.single;
  String i(String f, [String v = 'x']) => calculate(f, CalcKind.integrate, v).solutions.single;
  String after(String s) => s.substring(s.indexOf('= ') + 2);

  group('deriving', () {
    test('powers, sums and constants', () {
      expect(after(d('x^3')), r'3x^{2}');
      expect(after(d('x^2 + 3x + 5')), '2x + 3');
      expect(after(d('5')), '0');
      expect(after(d('ax^2', 'x')), '2ax');
      expect(after(d('ax^2', 'a')), 'x^{2}');
    });

    test('the product, chain and quotient rules', () {
      expect(after(d('x e^{x}')), contains('e^{x}'));
      expect(after(d(r'\sin(x^2)')), r'2x\cos\left(x^{2}\right)');
      expect(after(d(r'\frac{1}{x}')), r'-\frac{1}{x^{2}}');
      expect(after(d(r'\sqrt{x}')), r'\frac{1}{2\sqrt{x}}');
      expect(after(d(r'\ln(x)')), r'\frac{1}{x}');
      expect(after(d(r'e^{2x}')), r'2e^{2x}');
    });

    test('the notation is read and the order too', () {
      final r = calculate(r'\frac{d}{dx} x^3', CalcKind.derive, 'x').solutions.single;
      expect(r, r'\frac{d}{dx}\left(x^{3}\right) = 3x^{2}');
      final r2 = calculate(r'\frac{d^{2}}{dx^{2}} x^3', CalcKind.derive, 'x').solutions.single;
      expect(after(r2), '6x');
      expect(planCalculation(r'\frac{d}{dt} t^2 = ').kind, CalcKind.derive);
      expect(planCalculation(r'\frac{d}{dt} t^2').variables, ['t']);
    });
  });

  group('integrating', () {
    test('powers and sums', () {
      expect(after(i('x^2')), r'\frac{x^{3}}{3} + C');
      expect(after(i('3x^2 + 2x + 1')), 'x^{3} + x^{2} + x + C');
      expect(after(i('a')), 'ax + C');
      expect(after(i(r'\frac{1}{x}')), r'\ln\left|x\right| + C');
      expect(after(i(r'\frac{1}{2x+1}')), r'\frac{\ln\left|2x + 1\right|}{2} + C');
      expect(after(i('(2x+1)^3')), r'\frac{\left(2x + 1\right)^{4}}{8} + C');
    });

    test('functions', () {
      expect(after(i(r'\sin(x)')), r'-\cos\left(x\right) + C');
      expect(after(i(r'\cos(2x)')), r'\frac{\sin\left(2x\right)}{2} + C');
      expect(after(i('e^{x}')), 'e^{x} + C');
      expect(after(i('e^{3x}')), r'\frac{e^{3x}}{3} + C');
      expect(after(i(r'\ln(x)')), r'x\ln\left(x\right) - x + C');
    });

    test('by parts', () {
      expect(after(i('x e^{x}')), 'xe^{x} - e^{x} + C');
      expect(after(i(r'x\cos(x)')), contains(r'\sin'));
      expect(after(i(r'x\ln(x)')), contains(r'\ln'));
    });

    test('by substitution', () {
      expect(after(i('x e^{x^2}')), r'\frac{e^{x^{2}}}{2} + C');
      expect(after(i(r'\sin(x)\cos(x)')), contains(r'\sin'));
      expect(after(i(r'\frac{x}{x^2+1}')), r'\frac{\ln\left|x^{2} + 1\right|}{2} + C');
      expect(after(i(r'\frac{1}{x^2+4}')), contains(r'\arctan'));
    });

    test('definite integrals have a value', () {
      expect(calculate(r'\int_{0}^{2} x^2 \, dx', CalcKind.integrate, 'x').solutions.single, r'\int_{0}^{2} x^{2} \, dx = \frac{8}{3}');
      expect(calculate(r'\int_0^1 2x dx', CalcKind.integrate, 'x').solutions.single, endsWith('= 1'));
      final s = calculate(r'\int_{0}^{\pi} \sin(x) dx', CalcKind.integrate, 'x').solutions.single;
      expect(s, contains('2'));
    });

    test('the notation chooses the letter', () {
      final plan = planCalculation(r'\int t^2 \, dt');
      expect(plan.kind, CalcKind.integrate);
      expect(plan.variables, ['t']);
    });

    test('what it cannot do says so', () {
      expect(() => i(r'\sin(x^2)'), throwsA(isA<SolveException>()));
      expect(() => calculate(r'\int x', CalcKind.integrate, 'x'), throwsA(isA<SolveException>()));
    });
  });

  group('planning', () {
    test('equations are solved, expressions ask', () {
      expect(planCalculation('2x+3=11').kind, CalcKind.solve);
      expect(planCalculation('x^2 + y').kind, CalcKind.ask);
      expect(planCalculation('x^2 + y').variables, ['x', 'y']);
      expect(planCalculation('3+4').kind, CalcKind.none);
      expect(planCalculation('').kind, CalcKind.none);
      expect(canCalculate(r'\int x^2 dx'), isTrue);
    });
  });
}
