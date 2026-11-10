/// How well a card was remembered, as the person says it after seeing the answer.
enum Recall {
  again('Again'),
  hard('Hard'),
  good('Good'),
  easy('Easy');

  final String label;
  const Recall(this.label);
}

/// Where a card is in its schedule: when it is due and how fast the gaps between reviews grow (after SM-2, with the
/// learning steps and the easier-than-hard-than-good split Anki uses).
class CardSchedule {
  /// A card that was never reviewed.
  static const startingEase = 2.5;
  static const minimumEase = 1.3;

  /// Days until the next review as of the last one; 0 while the card is still being learned.
  final double interval;

  /// How much the interval is multiplied by after a good answer.
  final double ease;

  /// Reviews in a row that were not "again".
  final int reps;

  /// Times the card was forgotten after it had been learned.
  final int lapses;

  /// When the card is next due; null for a card that was never seen (due now).
  final DateTime? due;

  const CardSchedule({this.interval = 0, this.ease = startingEase, this.reps = 0, this.lapses = 0, this.due});

  bool isDue(DateTime now) => due == null || !due!.isAfter(now);

  /// Not yet through the learning steps.
  bool get learning => reps == 0;

  /// The schedule after the card was answered with [recall] at [now].
  CardSchedule review(Recall recall, DateTime now) {
    if (recall == Recall.again) {
      // forgotten: back to short steps, and the card is worth less ease than before
      final lapsed = reps > 0;
      return CardSchedule(
        interval: 0,
        ease: lapsed ? (ease - 0.2).clamp(minimumEase, 5.0) : ease,
        reps: 0,
        lapses: lapses + (lapsed ? 1 : 0),
        due: now.add(const Duration(minutes: 10)),
      );
    }
    final double days;
    var nextEase = ease;
    if (reps == 0) {
      // first success after (re)learning
      days = switch (recall) {
        Recall.hard => 1,
        Recall.good => 1,
        _ => 4,
      };
    } else if (reps == 1 && interval < 2) {
      days = switch (recall) {
        Recall.hard => 3,
        Recall.good => 6,
        _ => 8,
      };
    } else {
      final base = interval < 1 ? 1.0 : interval;
      switch (recall) {
        case Recall.hard:
          days = base * 1.2;
          nextEase = ease - 0.15;
        case Recall.easy:
          days = base * ease * 1.3;
          nextEase = ease + 0.15;
        default:
          days = base * ease;
      }
    }
    final rounded = days.roundToDouble().clamp(1.0, 3650.0);
    return CardSchedule(
      interval: rounded,
      ease: nextEase.clamp(minimumEase, 5.0),
      reps: reps + 1,
      lapses: lapses,
      // days are calendar days (a card reviewed late in the evening is due on that morning's date)
      due: DateTime(now.year, now.month, now.day + rounded.round()),
    );
  }

  /// Roughly when each answer would bring the card back, for the buttons ("10 min", "1 d", "2 mo").
  String previewLabel(Recall recall, DateTime now) {
    final next = review(recall, now);
    if (next.interval == 0) return '${next.due!.difference(now).inMinutes.clamp(1, 1 << 30)} min';
    final days = next.interval.round();
    if (days < 30) return '$days d';
    if (days < 365) return '${(days / 30).round()} mo';
    return '${(days / 365).toStringAsFixed(1)} y';
  }
}
