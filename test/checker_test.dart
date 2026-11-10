import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/checker.dart';
import 'package:notes/algebra/latex_parser.dart';

Verdict? one(String line) => checkLines([line]).single.verdict;
List<Verdict?> steps(List<String> lines) => [for (final c in checkLines(lines)) c.verdict];

void main() {
  group('the parser, further', () {
    test('sums, products, factorials, binomials', () {
      expect(evalLatex(r'\sum_{k=1}^{4} k^2'), 30);
      expect(evalLatex(r'\prod_{k=1}^{5} k'), 120);
      expect(evalLatex(r'5!'), 120);
      expect(evalLatex(r'\binom{5}{2}'), 10);
      expect(evalLatex(r'\sum_{i=0}^{3} 2i + 1'), 12 + 1);
    });

    test('bars, powers of functions, other bases and degrees', () {
      expect(evalLatex(r'|x - 5|', {'x': 2}), 3);
      expect(evalLatex(r'\left|-3\right|'), 3);
      expect(evalLatex(r'\sin^2 x + \cos^{2} x', {'x': 0.7}), closeTo(1, 1e-12));
      expect(evalLatex(r'\sin^{-1} 1'), closeTo(1.5707963, 1e-6));
      expect(evalLatex(r'\log_2 8'), closeTo(3, 1e-12));
      expect(evalLatex(r'\sin 30^\circ'), closeTo(0.5, 1e-12));
      expect(evalLatex(r'\cosh 0'), 1);
      expect(evalLatex(r'\sec 0'), 1);
      expect(evalLatex(r'\cot x', {'x': 1}), closeTo(0.642092616, 1e-8));
    });

    test('what cannot be read is refused', () {
      expect(() => parseExpression(r'\sum_{k=1}^{\infty} k'), throwsA(isA<ParseException>()));
      expect(() => parseExpression(r'\sum_{k=1.5}^{4} k'), throwsA(isA<ParseException>()));
      expect(() => parseExpression(r'2.5!'), throwsA(isA<ParseException>()));
    });
  });

  group('a line against itself', () {
    test('arithmetic', () {
      expect(one(r'17 \cdot 24 = 408'), Verdict.right);
      final bad = checkLines([r'17 \cdot 24 = 418']).single;
      expect(bad.verdict, Verdict.wrong);
      expect(bad.reason, Reason.arithmetic);
      expect(bad.expected, '408');
      expect(one(r'\frac{1}{3} + \frac{1}{6} = \frac{1}{2}'), Verdict.right);
      expect(one(r'\sqrt{49} = 8'), Verdict.wrong);
      expect(one(r'2^{10} = 1024'), Verdict.right);
      expect(one(r'5! = 120'), Verdict.right);
      expect(one(r'\sum_{k=1}^{10} k = 55'), Verdict.right);
      expect(one(r'\sum_{k=1}^{10} k = 56'), Verdict.wrong);
    });

    test('rounding', () {
      expect(one(r'\frac{1}{3} = 0.333'), Verdict.rounded);
      expect(one(r'\frac{1}{3} = 0.34'), Verdict.wrong);
      expect(one(r'\pi \approx 3.14'), Verdict.rounded);
      expect(one(r'\sqrt{2} \approx 1.41'), Verdict.rounded);
      expect(one(r'\sqrt{2} \approx 3'), Verdict.wrong);
    });

    test('chains', () {
      expect(one(r'3 \cdot 4 + 2 = 12 + 2 = 14'), Verdict.right);
      expect(one(r'3 \cdot 4 + 2 = 12 + 2 = 15'), Verdict.wrong);
    });

    test('algebra identities', () {
      expect(one(r'(x+2)^2 = x^2 + 4x + 4'), Verdict.right);
      expect(one(r'(a+b)(a-b) = a^2 - b^2'), Verdict.right);
      expect(one(r'\sin^2 x + \cos^2 x = 1'), Verdict.right);
      expect(one(r'\frac{x^2 - 1}{x - 1} = x + 1'), Verdict.right);
      expect(one(r'\ln(x^2) = 2 \ln x'), Verdict.right);
      expect(one(r'e^{x+1} = e \cdot e^{x}'), Verdict.right);
      final bad = checkLines([r'(x+2)^2 = x^2 + 4x + 5']).single;
      expect(bad.verdict, Verdict.wrong);
      expect(bad.reason, Reason.identity);
      expect(bad.counter, contains(r'\neq'));
      expect(one(r'(a+b)^2 = a^2 + b^2'), isNull); // (an equation as far as one can tell)
      expect(one(r'(a+b)^2 = a^2 + b^2 = c'), Verdict.wrong);
    });

    test('equations and formulas are not claims', () {
      expect(one(r'2x + 3 = 11'), isNull);
      expect(one(r'y = 2x + 1'), isNull);
      expect(one(r'E = mc^2'), isNull);
      expect(one(r'F = m a = 2 \cdot 3 = 6'), Verdict.right); // (what can be checked is right)
      expect(one(r'x^2 = 4'), isNull);
    });

    test('derivatives', () {
      expect(one(r'\frac{d}{dx} x^3 = 3x^2'), Verdict.right);
      final bad = checkLines([r'\frac{d}{dx} x^3 = 2x^2']).single;
      expect(bad.verdict, Verdict.wrong);
      expect(bad.reason, Reason.derivative);
      expect(bad.expected, contains('3'));
      expect(one(r'\frac{d}{dx} \sin(2x) = 2\cos(2x)'), Verdict.right);
      expect(one(r'\frac{d}{dx} x e^{x} = e^{x} + x e^{x}'), Verdict.right);
      expect(one(r'\frac{d^2}{dx^2} x^4 = 12x^2'), Verdict.right);
      expect(one(r'\frac{d}{dx} \ln x = \frac{1}{x}'), Verdict.right);
      expect(one(r'\frac{d}{dx} \tanh x = \frac{1}{\cosh^2 x}'), Verdict.right);
    });

    test('integrals', () {
      expect(one(r'\int x^2 \, dx = \frac{x^3}{3} + C'), Verdict.right);
      expect(one(r'\int x^2 \, dx = x^3 + C'), Verdict.wrong);
      expect(one(r'\int \cos x \, dx = \sin x + C'), Verdict.right);
      expect(one(r'\int_0^1 x^2 \, dx = \frac{1}{3}'), Verdict.right);
      expect(one(r'\int_0^1 x^2 \, dx = \frac{1}{2}'), Verdict.wrong);
      expect(one(r'\int_0^{\pi} \sin x \, dx = 2'), Verdict.right);
      // not integrable by the engine, still checked in numbers
      expect(one(r'\int_0^1 e^{x^2} \, dx = 1.4627'), Verdict.rounded);
    });

    test('limits', () {
      expect(one(r'\lim_{x \to 0} \frac{\sin x}{x} = 1'), Verdict.right);
      expect(one(r'\lim_{x \to \infty} \frac{1}{x} = 0'), Verdict.right);
      expect(one(r'\lim_{x \to 2} (x^2 + 1) = 5'), Verdict.right);
      expect(one(r'\lim_{x \to 2} (x^2 + 1) = 4'), Verdict.wrong);
      expect(one(r'\lim_{x \to \infty} \frac{2x+1}{x} = 2'), Verdict.right);
    });

    test('a line waiting for its result gets one', () {
      expect(checkLines([r'17 \cdot 24 =']).single.answer, '408');
      expect(checkLines([r'\frac{d}{dx} x^3 =']).single.answer, contains('3x^{2}'));
    });

    test('what cannot be read says nothing', () {
      expect(checkLines([r'\text{Hello}']).single.isNothing, isTrue);
      expect(checkLines([r'x < 5']).single.isNothing, isTrue);
      expect(checkLines([r'\begin{pmatrix} 1 \end{pmatrix} = 3']).single.isNothing, isTrue);
      expect(checkLines([null]).single.isNothing, isTrue);
    });
  });

  group('a step against the line above', () {
    test('solving a linear equation', () {
      expect(steps([r'2x + 3 = 11', r'2x = 8', r'x = 4']), [null, Verdict.right, Verdict.right]);
      expect(steps([r'2x + 3 = 11', r'2x = 8', r'x = 5']), [null, Verdict.right, Verdict.wrong]);
      final c = checkLines([r'2x + 3 = 11', r'x = 5'])[1];
      expect(c.verdict, Verdict.wrong);
      expect(c.expected, contains('4'));
    });

    test('a quadratic and its solutions', () {
      expect(steps([r'x^2 - 5x + 6 = 0', r'(x-2)(x-3) = 0', r'x = 2 \text{ or } x = 3']), [null, Verdict.right, Verdict.right]);
      expect(steps([r'x^2 = 4', r'x = \pm 2']), [null, Verdict.right]);
      expect(steps([r'x^2 - 5x + 6 = 0', r'x = 2, x = 4'])[1], Verdict.wrong);
    });

    test('a lost solution', () {
      final c = checkLines([r'x^2 = 3x', r'x = 3'])[1];
      expect(c.verdict, Verdict.lost);
      expect(c.expected, contains('0'));
      expect(steps([r'x^2 = 4', r'x = 2'])[1], Verdict.lost);
    });

    test('an added solution', () {
      expect(steps([r'x = 2', r'x^2 = 4'])[1], Verdict.widened);
      expect(steps([r'\sqrt{x} = 2', r'x = 4'])[1], Verdict.right);
    });

    test('a double root', () {
      expect(steps([r'x^2 - 4x + 4 = 0', r'(x-2)^2 = 0', r'x = 2']), [null, Verdict.right, Verdict.right]);
    });

    test('an equation with a fraction does not count a pole as a solution', () {
      expect(steps([r'\frac{1}{x} = 2', r'x = \frac{1}{2}']), [null, Verdict.right]);
    });

    test('several letters: solving for one', () {
      expect(steps([r'y = 2x + 1', r'x = \frac{y - 1}{2}'])[1], Verdict.right);
      expect(steps([r'y = 2x + 1', r'x = \frac{y + 1}{2}'])[1], Verdict.wrong);
    });

    test('a line that goes on with =', () {
      expect(steps([r'(x+2)^2', r'= x^2 + 4x + 4']), [null, Verdict.right]);
      expect(steps([r'(x+2)^2', r'= x^2 + 2x + 4'])[1], Verdict.wrong);
      expect(steps([r'3 \cdot 4', r'= 12', r'= 13']), [null, Verdict.right, Verdict.wrong]);
    });

    test('arrows in a line', () {
      expect(steps([r'2x + 3 = 11 \Rightarrow 2x = 8 \Rightarrow x = 4']), [Verdict.right]);
      expect(steps([r'2x + 3 = 11 \Rightarrow x = 3']), [Verdict.wrong]);
    });

    test('an arrow is a deduction: the new line has to follow, it need not be the same', () {
      for (final arrow in [r'\Rightarrow', r'\rightarrow', r'\to', r'\implies', r'\longrightarrow', '⇒', '→']) {
        expect(steps(['x = 2', 'x^2 = 4'.replaceFirst('x^2', 'x^2')])[1], Verdict.widened, reason: 'as plain lines: not the same');
        expect(steps(['x = 2 $arrow x^2 = 4']), [Verdict.right], reason: '$arrow: squaring is a fine deduction');
        expect(steps(['x^2 = 4 $arrow x = 2']), [Verdict.wrong], reason: '$arrow: x = -2 does not give x = 2');
        expect(steps(['2x + 3 = 11 $arrow x = 4']), [Verdict.right]);
        expect(steps(['2x + 3 = 11 $arrow x = 5']), [Verdict.wrong]);
      }
    });

    test('the arrow tells what went wrong', () {
      final c = checkLines([r'x^2 = 4 \Rightarrow x = 2']).single;
      expect(c.reason, Reason.notImplied);
      expect(c.expected, contains('-2'));
    });

    test('an arrow on a line of its own goes on from the line above', () {
      expect(steps([r'x = 2', r'\Rightarrow x^2 = 4']), [null, Verdict.right]);
      expect(steps([r'x^2 = 4', r'\rightarrow x = 2'])[1], Verdict.wrong);
      expect(steps([r'x^2 = 4', r'\Rightarrow x = \pm 2']), [null, Verdict.right]);
    });

    test('both ways is the same as being the same', () {
      expect(steps([r'x = 2 \iff x^2 = 4']), [Verdict.widened]);
      expect(steps([r'2x = 8 \Leftrightarrow x = 4']), [Verdict.right]);
      expect(steps([r'x = 2 \Leftrightarrow x^2 = 4']), [Verdict.widened]);
    });

    test('a limit keeps its arrow', () {
      expect(one(r'\lim_{x \to 0} \frac{\sin x}{x} = 1'), Verdict.right);
    });

    test('aligned blocks', () {
      expect(steps([r'\begin{aligned} 2x + 3 &= 11 \\ 2x &= 8 \end{aligned}']), [Verdict.right]);
    });

    test('an unreadable line starts afresh', () {
      expect(steps([r'2x + 3 = 11', r'\text{so}', r'x = 9'])[2], isNull);
    });

    test('unrelated equations are not compared', () {
      expect(steps([r'2x + 3 = 11', r'a + b = c']), [null, null]);
    });
  });

  group('answers', () {
    test('values, equations, derivatives', () {
      expect(answerFor(r'17 \cdot 24'), '408');
      expect(answerFor(r'2x + 3 = 11'), contains('4'));
      expect(answerFor(r'\frac{d}{dx} x^3'), contains('3'));
      expect(answerFor(r'\text{x}'), isNull);
    });
  });

  group('what the reader writes in its own way', () {
    test('spaces around braces and signs', () {
      expect(one(r'\frac { 1 } { 2 } + \frac { 1 } { 3 } = \frac { 5 } { 6 }'), Verdict.right);
      expect(one(r'\frac { d } { d x } x ^ { 2 } = 2 x'), Verdict.right);
      expect(one(r'\frac { d } { d x } x ^ { 2 } = 3 x'), Verdict.wrong);
      expect(one(r'\lim _ { x \to 0 } \frac { \sin x } { x } = 1'), Verdict.right);
      expect(one(r'a _ 1 + a _ 2 = 3 + 4 = 7'), Verdict.right);
      expect(one(r'\frac{\mathrm{d}}{\mathrm{d}x} x^2 = 2x'), Verdict.right);
      expect(one(r'\int \sin x \, \mathrm{d}x = -\cos x + C'), Verdict.right);
    });

    test('signs that are not LaTeX', () {
      expect(one('2 × 3 = 6'), Verdict.right);
      expect(one('6 ÷ 2 = 4'), Verdict.wrong);
      expect(one('5 − 3 = 2'), Verdict.right);
      expect(one('2 · 3 = 7'), Verdict.wrong);
      expect(one('√16 = 4'), Verdict.right);
      expect(one(r'2 \cdot -3 = -6'), Verdict.right);
    });

    test('decimal commas', () {
      expect(one('1,5 + 1 = 2,5'), Verdict.right);
      expect(one(r'0,5 \cdot 4 = 3'), Verdict.wrong);
      expect(one(r'1{,}5 \cdot 2 = 3'), Verdict.right);
      expect(steps([r'x^2 = 4', r'x = 2, x = -2'])[1], Verdict.right, reason: 'a list, not a number');
    });

    test('a function takes the number and the letters that follow it', () {
      expect(one(r'\sin 2x = 2 \sin x \cos x = \sin 2x'), Verdict.right);
      expect(one(r'\cos 2x = \cos^2 x - \sin^2 x = 1 - 2\sin^2 x'), Verdict.right);
      expect(one(r'\sin 2\pi = 0'), Verdict.right);
      expect(one(r'\sin 45 ^ { \circ } = \frac { \sqrt { 2 } } { 2 }'), Verdict.right);
      expect(one(r'\sin x \cos x = \frac12 \sin 2x = \frac12 \sin 2x'), Verdict.right);
      expect(one(r'\sec^2 x - \tan^2 x = 1'), Verdict.right);
      expect(one(r'\sec^2 x - \tan^2 x = 2'), Verdict.wrong);
      expect(one(r'\frac{d}{dx} \sin x \cos x = \cos 2x'), Verdict.right);
      expect(one(r'\int \cos^2 x dx = \frac{x}{2} + \frac{\sin 2x}{4} + C'), Verdict.right);
    });
  });

  group('what belongs together in a line', () {
    test('a note about the step is not maths', () {
      expect(steps([r'2x + 3 = 11 \quad |-3', r'2x = 8 \quad | :2', r'x = 4']), [null, Verdict.right, Verdict.right]);
      expect(steps([r'2x + 3 = 11 \quad |-3', r'2x = 8 \quad | :2', r'x = 5'])[2], Verdict.wrong);
      expect(steps([r'2x + 3 = 11 \; | -3', r'2x = 8'])[1], Verdict.right);
      expect(steps([r'2x + 3 = 11 \quad | \cdot 2', r'2x = 8'])[1], Verdict.right);
      expect(steps([r'|x| = 3 \quad |x| = 3', r'x = \pm 3'])[1], Verdict.right, reason: 'bars that close are an absolute value');
      expect(steps([r'|x - 1| = 2', r'x = 3 \;|\; x = -1']), isNotNull);
    });

    test('statements side by side are checked on their own', () {
      expect(one(r'1 + 1 = 2 \quad 2 + 2 = 5'), Verdict.wrong);
      expect(one(r'5 \cdot 3 = 15 \quad 4 \cdot 2 = 8'), Verdict.right);
      expect(one(r'2 \cdot 3 = 6 \qquad 3 \cdot 3 = 9'), Verdict.right);
    });

    test('"or" with a quad around it is one list of solutions', () {
      expect(steps([r'x^2 = 4', r'x = 2 \quad \text{or} \quad x = -2'])[1], Verdict.right);
      expect(steps([r'x^2 = 4', r'x = 2, \quad x = -2'])[1], Verdict.right);
      expect(steps([r'|x - 1| = 2', r'x = 3 \quad \text{or} \quad x = -1'])[1], Verdict.right);
    });

    test('x_1 and x_2 are the solutions of x', () {
      expect(steps([r'x^2 - 4x + 3 = 0', r'x_1 = 1, x_2 = 3'])[1], Verdict.right);
      expect(steps([r'x^2 - 4x + 3 = 0', r'x_1 = 1, x_2 = 4'])[1], Verdict.wrong);
    });

    test('a line that goes on from a derivative, an integral or a limit', () {
      expect(steps([r'\frac{d}{dx}(x^2 + x)', r'= 2x + 1']), [null, Verdict.right]);
      expect(steps([r'\frac{d}{dx}(x^2 + x)', r'= 2x + 2'])[1], Verdict.wrong);
      expect(steps([r'\int_0^1 2x \, dx', r'= 1'])[1], Verdict.right);
      expect(steps([r'\int_0^1 2x \, dx', r'= 2'])[1], Verdict.wrong);
      expect(steps([r'\lim_{x \to 2} (x+1)', r'= 3'])[1], Verdict.right);
      expect(one(r'\frac{d}{dx} x^2 = 2x = 3x'), Verdict.wrong);
    });

    test('a value put in is not a mistake', () {
      expect(steps([r'y = 2x + 1', r'x = 3'])[1], isNull);
      expect(steps([r'y = 2x + 1', r'= 2 \cdot 3 + 1', r'= 7'])[2], Verdict.right);
      expect(steps([r'y = 2x + 1', r'y = 2 \cdot 3 + 1'])[1], isNull);
      expect(steps([r'y = 2x + 1', r'x = \frac{y - 1}{2}'])[1], Verdict.right);
    });

    test('limits and constants', () {
      expect(one(r'\lim_{x \rightarrow 0} \frac{\sin x}{x} = 1'), Verdict.right);
      expect(one(r'\lim_{x \to \infty} \left(1 + \frac1x\right)^x = e'), Verdict.right);
      expect(one(r'\lim_{x \to 0^+} \frac{1}{x+1} = 1'), Verdict.right);
      expect(one(r'\int_1^e \frac{1}{x} dx = 1'), Verdict.right);
      expect(one(r'\int \frac{1}{x} dx = \ln|x| + C'), Verdict.right);
      expect(one(r'\ln e = 1'), Verdict.right);
    });

    test('rounding to the decimals of either side', () {
      expect(one(r'0.333 = \frac{1}{3}'), Verdict.rounded);
      expect(one(r'0.34 = \frac{1}{3}'), Verdict.wrong);
    });

    test('expressions whose domain is far from zero', () {
      expect(one(r'\sqrt{x-5}^2 = x - 5'), Verdict.right);
    });
  });

  group('what a real handwriting model writes', () {
    test('a low times dot, a full stop, mixed numbers', () {
      expect(one(r'b=12=2^{2}.3'), Verdict.right);
      expect(one(r'b=12=2^{2}.5'), Verdict.wrong);
      expect(one(r'2 \cdot 3 = 6.'), Verdict.right);
      expect(one(r'12\frac{3}{11}\div13\frac{1}{2}=\frac{10}{11}'), Verdict.right);
      expect(one(r'12\frac{3}{11}\div13\frac{1}{2}=\frac{2}{3}'), Verdict.wrong);
      expect(one(r'1\frac{1}{2} + 1\frac{1}{2} = 3'), Verdict.right);
      expect(one(r'2\frac{1}{2} = 5 \cdot \frac12'), Verdict.right);
    });

    test('unknown functions, differentials and approximations are not claims', () {
      expect(one(r'E=f(a)=f(-a)'), isNull);
      expect(one(r'\int f(x)dx=F(x)'), isNull);
      expect(one(r'\frac{d}{dx}y=t(x)y'), isNull);
      expect(one(r'\frac{dy}{dx} = \frac{y}{x}'), isNull);
      expect(one(r'1/x\approx1-x'), isNull);
      expect(one(r'-\frac{3}{38}r\approx-0.0789r'), Verdict.rounded);
      expect(one(r'\pi r^2 \approx 3.14 r^2'), Verdict.rounded);
      expect(one(r'\pi r^2 \approx 4 r^2'), Verdict.wrong);
      expect(one(r'f(3) = 2 \cdot 3 + 1 = 8'), Verdict.wrong, reason: 'the numbers can still be checked');
    });

    test('rounding: a cut-off figure with ≈, a whole number after a measured value, degrees', () {
      expect(one(r'\frac{480}{0.9}=533.3\approx534'), Verdict.rounded);
      expect(one(r'\sqrt{10}\approx3.1'), Verdict.rounded);
      expect(one(r'150\sqrt{1.4}=177'), Verdict.rounded);
      expect(one(r'\frac{7}{2}=4'), Verdict.wrong, reason: 'not a measured value');
      expect(one(r'\arctan\sqrt{2}=54.7^{\circ}'), Verdict.rounded);
    });

    test('names without a backslash, and the model\'s \\mathrm', () {
      expect(one(r'\int cosxdx=sinx+C'), Verdict.right);
      expect(one(r'\frac{d}{dx}(ln|x|)=\frac{1}{x}'), Verdict.right);
      expect(one(r'\frac{d}{dt}log_{e}t=\frac{1}{t}'), Verdict.right);
      expect(one(r'\frac{d}{d\mathrm{ x }}\mathrm{ x }^{2}=2\mathrm{ x }'), Verdict.right);
    });

    test('a times dot written low and read as a decimal point is not reported when it is right as a product', () {
      expect(one('31.18 = 558'), isNull);
      expect(one('13.27 = 351'), isNull);
      expect(one('3.5 + 1.5 = 5'), Verdict.right); // (a real decimal that is right stays right)
      expect(one('3.5 + 1.5 = 6'), Verdict.wrong); // (and one that is wrong stays wrong, as a product too)
      expect(one('2.5 \\cdot 2 = 7'), Verdict.wrong);
    });
  });
}
