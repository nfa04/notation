import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/checker.dart';
import 'package:notes/ink/math_marks.dart';

ReadLine line(double top, String? latex, {double left = 20, double width = 160, double height = 24, int page = 0}) =>
    (page: page, key: 'k$top$left$page', rect: Rect.fromLTWH(left, top, width, height), latex: latex);

void main() {
  test('lines under each other are one solution', () {
    final marks = MathMarker().mark([
      line(100, r'2x + 3 = 11'),
      line(140, r'2x = 8'),
      line(180, r'x = 5'),
    ]);
    expect(marks.length, 2);
    expect(marks[0].check.verdict, Verdict.right);
    expect(marks[0].rect.top, 140);
    expect(marks[1].check.verdict, Verdict.wrong);
  });

  test('the order does not matter', () {
    final marks = MathMarker().mark([line(140, r'x = 5'), line(100, r'2x + 3 = 11')]);
    expect(marks.single.check.verdict, Verdict.wrong);
  });

  test('a line that is not maths, a gap or a line beside it ends the solution', () {
    expect(MathMarker().mark([line(100, r'2x + 3 = 11'), line(140, null), line(180, r'x = 5')]), isEmpty);
    expect(MathMarker().mark([line(100, r'2x + 3 = 11'), line(400, r'x = 5')]), isEmpty);
    expect(MathMarker().mark([line(100, r'2x + 3 = 11'), line(104, r'x = 5', left: 300)]), isEmpty);
    expect(MathMarker().mark([line(100, r'2x + 3 = 11'), line(140, r'x = 5', left: 700, width: 100)]), isEmpty);
  });

  test('solutions on different pages do not mix', () {
    expect(MathMarker().mark([line(100, r'2x + 3 = 11'), line(140, r'x = 5', page: 1)]), isEmpty);
  });

  test('a single line with its own mistake', () {
    final marks = MathMarker().mark([line(100, r'17 \cdot 24 = 418')]);
    expect(marks.single.check.reason, Reason.arithmetic);
    expect(marks.single.latex, r'17 \cdot 24 = 418');
  });

  test('a line waiting for its result gets a mark with the answer', () {
    expect(MathMarker().mark([line(100, r'17 \cdot 24 =')]).single.check.answer, '408');
  });

  test('two columns of working are two solutions, not one interleaved', () {
    final marks = MathMarker().mark([
      line(100, r'2x + 3 = 11'),
      line(100, r'3y - 1 = 8', left: 400),
      line(140, r'2x = 8'),
      line(140, r'3y = 9', left: 400),
      line(180, r'x = 5'),
      line(180, r'y = 3', left: 400),
    ]);
    expect(marks.map((m) => (m.rect.left, m.rect.top, m.check.verdict)), [
      (20.0, 140.0, Verdict.right),
      (20.0, 180.0, Verdict.wrong),
      (400.0, 140.0, Verdict.right),
      (400.0, 180.0, Verdict.right),
    ]);
  });

  test('a note beside a line (| -3) does not cut the solution', () {
    final marks = MathMarker().mark([
      line(100, r'2x + 3 = 11'),
      line(100, r'\mid -3', left: 330, width: 60),
      line(140, r'2x = 8'),
      line(140, r'\mid : 2', left: 330, width: 60),
      line(180, r'x = 5'),
    ]);
    expect(marks.map((m) => (m.rect.top, m.check.verdict)), [(140.0, Verdict.right), (180.0, Verdict.wrong)]);
  });

  test('a line that was not read ends the steps there, but not the solutions around it', () {
    final marks = MathMarker().mark([
      line(100, r'2x + 3 = 11'),
      line(140, null),
      line(180, r'x = 5'),
      line(220, r'x = 6'),
    ]);
    // (x = 6 is not a step of x = 5 in a way that can be told: both only say what x is)
    expect(marks.where((m) => m.rect.top == 180), isEmpty);
  });
}
