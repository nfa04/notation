import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/fsrs.dart';
import 'package:notes/ai/spaced_repetition.dart';

/// One answer of a scenario and what py-fsrs 6.3.3 gives after it (learning and relearning steps of 10 minutes, no fuzz, 90 %
/// retention): the stability, the difficulty, and the wait until the card comes back in minutes.
typedef Step = (int grade, DateTime at, double s, double d, double minutes);

DateTime _t(String iso) => DateTime.parse(iso);

// (taken from py-fsrs: `Scheduler(learning_steps=(10 min,), relearning_steps=(10 min,), enable_fuzzing=False)`,
// reviewing at the times below)
final _scenarios = <String, List<Step>>{
  'good every time': [
    (3, _t('2026-01-05T09:00:00Z'), 2.3065, 2.118104, 2880),
    (3, _t('2026-01-05T09:10:00Z'), 2.3065, 2.111214, 2880),
    (3, _t('2026-01-07T09:10:00Z'), 10.971048, 2.104331, 15840),
    (3, _t('2026-01-18T09:10:00Z'), 46.316858, 2.097455, 66240),
    (3, _t('2026-03-05T09:10:00Z'), 162.999816, 2.090586, 234720),
    (3, _t('2026-08-15T09:10:00Z'), 497.876555, 2.083724, 717120),
  ],
  'forgotten at first and later': [
    (1, _t('2026-01-05T09:00:00Z'), 0.212, 6.4133, 10),
    (3, _t('2026-01-05T09:10:00Z'), 0.246689, 6.402115, 1440),
    (3, _t('2026-01-06T09:10:00Z'), 2.021477, 6.390941, 2880),
    (1, _t('2026-01-08T09:10:00Z'), 0.526, 8.798955, 10),
    (3, _t('2026-01-08T09:20:00Z'), 0.576543, 8.785385, 1440),
    (3, _t('2026-01-09T09:20:00Z'), 1.665782, 8.771828, 2880),
  ],
  'easy, hard, a lapse and relearning': [
    (4, _t('2026-01-05T09:00:00Z'), 8.2956, 1.0, 11520),
    (2, _t('2026-01-13T09:00:00Z'), 26.704183, 4.010609, 38880),
    (2, _t('2026-02-09T09:00:00Z'), 61.967886, 6.009191, 89280),
    (4, _t('2026-04-12T09:00:00Z'), 218.94516, 4.660878, 315360),
    (1, _t('2026-11-17T09:00:00Z'), 4.979431, 8.230295, 10),
    (2, _t('2026-11-17T09:10:00Z'), 4.979431, 8.810416, 15),
    (3, _t('2026-11-17T09:20:00Z'), 4.979431, 8.796834, 7200),
  ],
  'reviewed 20 days late': [
    (3, _t('2026-01-05T09:00:00Z'), 2.3065, 2.118104, 2880),
    (3, _t('2026-01-05T09:10:00Z'), 2.3065, 2.111214, 2880),
    (3, _t('2026-01-27T09:10:00Z'), 33.89478, 2.104331, 48960),
  ],
};

void main() {
  group('FSRS against py-fsrs', () {
    for (final MapEntry(key: name, value: steps) in _scenarios.entries) {
      test(name, () {
        var s = const CardSchedule();
        for (final (i, (g, at, stability, difficulty, minutes)) in steps.indexed) {
          s = s.review(Recall.values[g - 1], at);
          final why = 'answer ${i + 1} ($g)';
          expect(s.stability, closeTo(stability, 1e-5), reason: why);
          expect(s.difficulty, closeTo(difficulty, 1e-5), reason: why);
          if (minutes < 1440) {
            expect(s.interval, 0, reason: why);
            expect(s.due!.difference(at).inMinutes, minutes, reason: why);
          } else {
            expect(s.interval, minutes / 1440, reason: why);
          }
        }
      });
    }
  });

  group('Fsrs', () {
    test('a higher retention brings cards back sooner', () {
      expect(Fsrs(retention: 0.95).intervalDays(20), lessThan(Fsrs().intervalDays(20)));
      expect(Fsrs(retention: 0.8).intervalDays(20), greaterThan(Fsrs().intervalDays(20)));
      expect(Fsrs().intervalDays(20), 20, reason: 'at 90 % the interval is the stability');
    });

    test('ease and difficulty map onto each other', () {
      for (final e in [1.3, 1.9, 2.5, 3.0, 3.5]) {
        expect(Fsrs.easeFromDifficulty(Fsrs.difficultyFromEase(e)), closeTo(e, 1e-9));
      }
      expect(Fsrs.difficultyFromEase(2.5), 5);
      expect(Fsrs.difficultyFromEase(1.3), 10);
      expect(Fsrs.difficultyFromEase(9), 1);
    });
  });

  group('cards scheduled before FSRS', () {
    final now = DateTime(2026, 3, 1, 20, 30);

    test('keep about their interval when answered good on time', () {
      final old = CardSchedule(interval: 10, ease: 2.5, reps: 3, due: now);
      final next = old.review(Recall.good, now);
      expect(next.stability, isNotNull);
      expect(next.interval, inInclusiveRange(15, 40), reason: 'a known card grows from where it was, not from scratch');
      expect(next.reps, 4);
    });

    test('a low ease becomes a high difficulty', () {
      final hard = CardSchedule(interval: 10, ease: 1.3, reps: 3, due: now).review(Recall.good, now);
      final easy = CardSchedule(interval: 10, ease: 3.0, reps: 3, due: now).review(Recall.good, now);
      expect(hard.difficulty, greaterThan(easy.difficulty!));
      expect(hard.interval, lessThan(easy.interval));
    });

    test('forgetting one counts a lapse and brings it back in ten minutes', () {
      final next = CardSchedule(interval: 10, reps: 3, lapses: 1, due: now).review(Recall.again, now);
      expect([next.reps, next.lapses, next.interval], [0, 2, 0]);
      expect(next.due, now.add(const Duration(minutes: 10)));
    });
  });
}
