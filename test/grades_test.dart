import 'package:flutter_test/flutter_test.dart';
import 'package:notes/review/grades.dart';

Assessment part(String id, double weight, {double? grade, double? points, double? max, bool counts = true}) =>
    Assessment(id: id, name: id, weight: weight, grade: grade, points: points, maxPoints: max, counts: counts);

void main() {
  group('scales', () {
    test('points become grades by each scale\'s rule', () {
      expect(GradeScale.swiss.fromFraction(1), 6);
      expect(GradeScale.swiss.fromFraction(0.6), 4, reason: '60 % is a pass in Switzerland');
      expect(GradeScale.german.fromFraction(1), 1);
      expect(GradeScale.german.fromFraction(0.5), 4);
      expect(GradeScale.german.fromFraction(0.49), 5);
      expect(GradeScale.percent.fromFraction(0.73), closeTo(73, 1e-9));
      expect(GradeScale.gpa.fromFraction(0.75), 3);
    });

    test('which way is better, passing, rounding, classes', () {
      expect(GradeScale.german.higherIsBetter, isFalse);
      expect(GradeScale.german.passes(3.7), isTrue);
      expect(GradeScale.german.passes(4.3), isFalse);
      expect(GradeScale.swiss.passes(3.75), isFalse);
      expect(GradeScale.swiss.rounded(4.6), 4.5);
      expect(GradeScale.swiss.rounded(7), 6);
      expect(GradeScale.uk.className(65), 'Upper second (2:1)');
      expect(GradeScale.percent.className(65), isNull);
      expect(GradeScale.byName('nonsense'), GradeScale.percent);
    });
  });

  group('a course', () {
    test('the average is by weight, of what is graded and counts', () {
      final c = CourseGrades(GradeScale.swiss, [
        part('mid', 30, grade: 5),
        part('labs', 20, points: 18, max: 20), // 1 + 5 * 0.9 = 5.5
        part('final', 50),
        part('practice', 10, grade: 2, counts: false),
      ]);
      expect(c.average, closeTo((30 * 5 + 20 * 5.5) / 50, 1e-9));
      expect(c.done, 0.5);
    });

    test('what is needed on the rest: a grade, already reached, or out of reach', () {
      final c = CourseGrades(GradeScale.swiss, [part('mid', 40, grade: 4.5), part('final', 60)]);
      expect((c.neededFor(5) as NeedGrade).grade, closeTo((5 * 100 - 40 * 4.5) / 60, 1e-9));
      expect(c.neededFor(1.5), isA<AlreadyReached>(), reason: 'even a 1 on the final gives more');
      final far = c.neededFor(6);
      expect(far, isA<NotReachable>());
      expect((far as NotReachable).best, closeTo((40 * 4.5 + 60 * 6) / 100, 1e-9));
    });

    test('on a scale where lower is better (German) the same works the other way round', () {
      final c = CourseGrades(GradeScale.german, [part('a', 50, grade: 2.0), part('b', 50)]);
      expect((c.neededFor(1.5) as NeedGrade).grade, closeTo(1.0, 1e-9));
      expect(c.neededFor(1.3), isA<NotReachable>());
      expect(c.neededFor(3.5), isA<AlreadyReached>(), reason: 'a 5.0 on b still gives 3.5');
    });

    test('weights need not add up to 100, and with nothing left the target is reached or not', () {
      final c = CourseGrades(GradeScale.percent, [part('a', 1, grade: 80), part('b', 3, grade: 60)]);
      expect(c.average, 65);
      expect(c.neededFor(60), isA<AlreadyReached>());
      expect(c.neededFor(70), isA<NotReachable>());
      expect(CourseGrades(GradeScale.percent, const []).average, isNull);
      expect(CourseGrades(GradeScale.percent, [part('x', 0, grade: 90)]).average, isNull, reason: 'a part that weighs nothing does not count');
    });

    test('parts go to JSON and back; what is broken is left out', () {
      final p = Assessment(id: 'a', name: 'Midterm', kind: 'exam', weight: 30, due: DateTime(2026, 12, 3), points: 31, maxPoints: 40, counts: false);
      final back = Assessment.fromJson(p.toJson())!;
      expect([back.name, back.kind, back.weight, back.due, back.points, back.maxPoints, back.counts, back.grade], ['Midterm', 'exam', 30, DateTime(2026, 12, 3), 31, 40, false, null]);
      expect(Assessment.fromJson({'name': 'no id'}), isNull);
      expect(Assessment.fromJson({'id': 'x', 'name': 'n', 'w': -5})!.weight, 0);
    });
  });

  test('the average of courses goes by their credits, leaving out those without a grade', () {
    expect(creditAverage(GradeScale.swiss, [(credits: 6, grade: 5), (credits: 3, grade: 4), (credits: 4, grade: null)]), closeTo(42 / 9, 1e-9));
    expect(creditAverage(GradeScale.swiss, [(credits: 6, grade: null)]), isNull);
  });
}
