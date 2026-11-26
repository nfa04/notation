import 'dart:math' as math;

/// The memory model of FSRS-6 (the Free Spaced Repetition Scheduler, which Anki uses too): how firmly a card is known
/// ([stability], the days until it is remembered with a chance of 90 %) and how hard it is ([difficulty], 1 to 10), and how both
/// change with an answer. The numbers and formulas are those of the open reference, py-fsrs 6 (MIT licence, Open Spaced
/// Repetition); test/fsrs_test.dart checks this against what it gives.
///
/// The answers are 1 (again), 2 (hard), 3 (good) and 4 (easy).
class Fsrs {
  /// The default weights of FSRS-6, fitted by its authors on many people's reviews.
  static const defaultWeights = <double>[
    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796, //
    1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
  ];

  static const minStability = 0.001;
  static const minDifficulty = 1.0, maxDifficulty = 10.0;
  static const maxInterval = 36500;

  final List<double> w;

  /// The chance of remembering a card at which it is asked again (0.9: the card comes back when it is 90 % likely to be known).
  final double retention;

  final double _decay, _factor;

  Fsrs({List<double> weights = defaultWeights, this.retention = 0.9})
      : assert(weights.length == 21),
        w = weights,
        _decay = -weights[20],
        _factor = math.pow(0.9, 1 / -weights[20]) - 1;

  /// How likely a card of [stability] is remembered [elapsedDays] after its last review.
  double retrievability(double stability, int elapsedDays) => math.pow(1 + _factor * math.max(0, elapsedDays) / stability, _decay).toDouble();

  double initialStability(int answer) => math.max(w[answer - 1], minStability);

  double initialDifficulty(int answer, {bool clamp = true}) {
    final d = w[4] - math.exp(w[5] * (answer - 1)) + 1;
    return clamp ? _clampD(d) : d;
  }

  /// The difficulty after [answer]: a good answer leaves it nearly as it is, again makes it harder, easy easier, and every answer pulls
  /// it a little towards the difficulty of a card first answered easy.
  double nextDifficulty(double d, int answer) {
    final delta = -(w[6] * (answer - 3));
    final damped = d + (10.0 - d) * delta / 9.0;
    return _clampD(w[7] * initialDifficulty(4, clamp: false) + (1 - w[7]) * damped);
  }

  /// The stability after a review on another day than the last one, the card being [retrievability] likely to be known then.
  double nextStability(double d, double s, double retrievability, int answer) {
    final double next;
    if (answer == 1) {
      final longTerm = w[11] * math.pow(d, -w[12]) * (math.pow(s + 1, w[13]) - 1) * math.exp((1 - retrievability) * w[14]);
      final shortTerm = s / math.exp(w[17] * w[18]);
      next = math.min(longTerm, shortTerm);
    } else {
      final hardPenalty = answer == 2 ? w[15] : 1.0;
      final easyBonus = answer == 4 ? w[16] : 1.0;
      next = s * (1 + math.exp(w[8]) * (11 - d) * math.pow(s, -w[9]) * (math.exp((1 - retrievability) * w[10]) - 1) * hardPenalty * easyBonus);
    }
    return math.max(next, minStability);
  }

  /// The stability after a review on the same day as the last one.
  double shortTermStability(double s, int answer) {
    var increase = math.exp(w[17] * (answer - 3 + w[18])) * math.pow(s, -w[19]);
    if (answer > 1) increase = math.max(increase, 1.0);
    return math.max(s * increase, minStability);
  }

  /// Whole days until a card of [stability] is due, at the [retention] wanted.
  int intervalDays(double stability) {
    final days = stability / _factor * (math.pow(retention, 1 / _decay) - 1);
    return days.round().clamp(1, maxInterval);
  }

  static double _clampD(double d) => d.clamp(minDifficulty, maxDifficulty);

  /// The difficulty a card scheduled before FSRS (with an ease, SM-2 style) is taken to have: the ease of a new card (2.5) is a middling
  /// difficulty of 5, the lowest ease (1.3) the hardest (10), and easier cards go down to 1 at an ease of 3.5.
  static double difficultyFromEase(double ease) => (ease <= 2.5 ? 5 + (2.5 - ease) / 1.2 * 5 : 5 - (ease - 2.5) * 4).clamp(minDifficulty, maxDifficulty);

  /// The other way round: an ease for a difficulty, for what still speaks in eases (the Anki export, older devices).
  static double easeFromDifficulty(double d) => d >= 5 ? 2.5 - (d - 5) / 5 * 1.2 : 2.5 + (5 - d) / 4;
}
