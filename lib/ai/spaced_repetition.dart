import 'fsrs.dart';

/// How well a card was remembered, as the person says it after seeing the answer.
enum Recall {
  again('Again'),
  hard('Hard'),
  good('Good'),
  easy('Easy');

  final String label;
  const Recall(this.label);

  /// The answer as FSRS counts it: 1 (again) to 4 (easy).
  int get grade => index + 1;
}

/// Where a card is in its schedule: when it is due, and how firmly and how hard it is known (FSRS, see [Fsrs]). A card that is
/// being learned (or learned again after it was forgotten) comes back after ten minutes until it is answered good or easy; after
/// that it comes back on the day it is 90 % likely to be remembered (the retention the person chose).
///
/// Cards scheduled before FSRS have an ease and an interval but no [stability]: at their next review these are taken over (the
/// interval as the stability, the ease as the difficulty). [ease] and [interval] are still kept up to date, for what speaks in them
/// (the Anki export).
class CardSchedule {
  /// A card that was never reviewed.
  static const startingEase = 2.5;
  static const minimumEase = 1.3;

  /// The wait after a forgotten answer, and after a hard one while learning.
  static const step = Duration(minutes: 10);
  static const hardStep = Duration(minutes: 15);

  /// Days until the next review as of the last one; 0 while the card is still being learned.
  final double interval;

  /// The SM-2 ease that goes with the difficulty.
  final double ease;

  /// Reviews in a row that were not "again".
  final int reps;

  /// Times the card was forgotten after it had been learned.
  final int lapses;

  /// When the card is next due; null for a card that was never seen (due now).
  final DateTime? due;

  /// FSRS: the days until the card is 90 % likely to be remembered; null before its first review under FSRS.
  final double? stability;

  /// FSRS: how hard the card is, 1 to 10; null before its first review under FSRS.
  final double? difficulty;

  /// When it was last answered; null for a card never answered here.
  final DateTime? lastReview;

  const CardSchedule({
    this.interval = 0,
    this.ease = startingEase,
    this.reps = 0,
    this.lapses = 0,
    this.due,
    this.stability,
    this.difficulty,
    this.lastReview,
  });

  bool isDue(DateTime now) => due == null || !due!.isAfter(now);

  /// Not yet through the learning steps.
  bool get learning => reps == 0;

  /// Hard to remember: forgotten more than once, or of a high difficulty (or, before FSRS, a low ease).
  bool get weak => lapses >= 2 || (difficulty != null ? difficulty! >= 7 : ease <= 1.9);

  static final _standard = Fsrs();

  /// The schedule after the card was answered with [recall] at [now]. [fsrs] holds the retention wanted (default 90 %).
  CardSchedule review(Recall recall, DateTime now, {Fsrs? fsrs}) {
    final f = fsrs ?? _standard;
    final g = recall.grade;
    var s = stability, d = difficulty;
    var last = lastReview;
    if (s == null && (reps > 0 || lapses > 0 || interval > 0)) {
      // scheduled before FSRS: the interval it had is about how long it is known, the ease says how hard it is
      s = interval > 0 ? interval : 1.0;
      d = Fsrs.difficultyFromEase(ease);
      last ??= due == null ? now : due!.subtract(Duration(days: interval.round()));
    }
    final double nextS, nextD;
    if (s == null || d == null) {
      nextS = f.initialStability(g);
      nextD = f.initialDifficulty(g);
    } else {
      final elapsed = last == null ? null : now.difference(last).inDays;
      nextS = elapsed != null && elapsed < 1 ? f.shortTermStability(s, g) : f.nextStability(d, s, elapsed == null ? 0 : f.retrievability(s, elapsed), g);
      nextD = f.nextDifficulty(d, g);
    }
    CardSchedule after({required int reps, required int lapses, required DateTime due, double interval = 0}) => CardSchedule(
          interval: interval,
          ease: Fsrs.easeFromDifficulty(nextD),
          reps: reps,
          lapses: lapses,
          due: due,
          stability: nextS,
          difficulty: nextD,
          lastReview: now,
        );
    if (recall == Recall.again) {
      // forgotten (or not yet known): back in ten minutes; a card that had been learned counts a lapse
      return after(reps: 0, lapses: lapses + (reps > 0 ? 1 : 0), due: now.add(step));
    }
    if (learning && recall == Recall.hard) return after(reps: 0, lapses: lapses, due: now.add(hardStep));
    final days = f.intervalDays(nextS);
    // days are calendar days (a card reviewed late in the evening is due on that morning's date)
    return after(reps: reps + 1, lapses: lapses, interval: days.toDouble(), due: DateTime(now.year, now.month, now.day + days));
  }

  /// Roughly when each answer would bring the card back, for the buttons ("10 min", "1 d", "2 mo").
  String previewLabel(Recall recall, DateTime now, {Fsrs? fsrs}) {
    final next = review(recall, now, fsrs: fsrs);
    if (next.interval == 0) return '${next.due!.difference(now).inMinutes.clamp(1, 1 << 30)} min';
    final days = next.interval.round();
    if (days < 30) return '$days d';
    if (days < 365) return '${(days / 30).round()} mo';
    return '${(days / 365).toStringAsFixed(1)} y';
  }
}
