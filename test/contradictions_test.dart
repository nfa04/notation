import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/graph/contradictions.dart';

StoredFact fact(int id, String note, String title, String sentence, {Float32List? vector}) =>
    StoredFact(id: id, noteId: note, title: title, sentence: sentence, vector: vector);

void main() {
  group('numbers', () {
    test('as they are written, without grouping, trailing zeros or leading zeros', () {
      expect(numbersIn('It costs 1,000 francs, 3,5 percent, 2.50 and 007 and 12:30'), {'1000', '3.5', '2.5', '7', '12', '30'});
      expect(numbersIn('1.000.000 people'), {'1000000'});
      expect(numbersIn('no numbers here, and abc123 is not one'), isEmpty);
    });
  });

  group('contradictions', () {
    test('the same thing with different numbers, in different notes', () {
      final found = findContradictions([
        fact(1, 'physics', 'Speed of sound', 'The speed of sound in air at 20 degrees is 343 m/s.'),
        fact(2, 'lecture', 'Speed of sound', 'The speed of sound in air at 20 degrees is 330 m/s.'),
        fact(3, 'cooking', 'Bread', 'Bake bread for 40 minutes at 220 degrees.'),
      ]);
      expect(found, hasLength(1));
      expect((found.single.a.id, found.single.b.id), (1, 2));
      expect(found.single.onlyA, ['343']);
      expect(found.single.onlyB, ['330']);
    });

    test('a date that differs', () {
      final found = findContradictions([
        fact(1, 'a', 'Final exam', 'The final exam is on 20 June 2026 in room B12.'),
        fact(2, 'b', 'Final exam', 'The final exam is on 21 June 2026 in room B12.'),
      ]);
      expect(found.single.onlyA, ['20']);
      expect(found.single.onlyB, ['21']);
    });

    test('the same numbers, or a number only added, or one note saying both, are no contradiction', () {
      expect(findContradictions([fact(1, 'a', 'Exam', 'The exam is on 20 June.'), fact(2, 'b', 'Exam', 'The exam is on 20 June.')]), isEmpty);
      expect(findContradictions([fact(1, 'a', 'Exam', 'The exam is on 20 June.'), fact(2, 'b', 'Exam', 'The exam is on 20 June at 9.')]), isEmpty);
      expect(findContradictions([fact(1, 'a', 'Exam', 'The exam is on 20 June.'), fact(2, 'a', 'Exam', 'The exam is on 21 June.')]), isEmpty);
    });

    test('things that are not about the same, with numbers that differ, are left alone', () {
      expect(findContradictions([
        fact(1, 'a', 'Heaps', 'A binary heap with 7 nodes has height 2.'),
        fact(2, 'b', 'Rent', 'The rent is due on the 5th of every month for 12 months.'),
      ]), isEmpty);
    });

    test('facts that mean the same by their vectors, with enough words in common, count even when the words differ', () {
      final v = Float32List.fromList([1, 0, 0]);
      final w = Float32List.fromList([0.95, 0.31, 0]);
      final far = Float32List.fromList([0, 1, 0]);
      final near = findContradictions([
        fact(1, 'a', 'Boiling point', 'Water boils at 100 degrees at sea level.', vector: v),
        fact(2, 'b', 'Vaporisation', 'The boiling temperature of water is 90 degrees at altitude.', vector: w),
      ]);
      expect(near, hasLength(1));
      final unrelated = findContradictions([
        fact(1, 'a', 'Boiling point', 'Water boils at 100 degrees at sea level.', vector: v),
        fact(2, 'b', 'Vaporisation', 'The boiling temperature of water is 90 degrees at altitude.', vector: far),
      ]);
      expect(unrelated, isEmpty);
    });

    test('there is a limit to how many are reported', () {
      final facts = [for (var i = 0; i < 30; i++) fact(i, 'n$i', 'Speed of sound', 'The speed of sound in air is ${300 + i} m/s.')];
      expect(findContradictions(facts, max: 10), hasLength(10));
    });
  });
}
