import 'dart:math' as math;

/// A way of giving grades: from what number to what, which end is better, where passing starts, and how a score (a part of the most
/// points) becomes a grade.
///
/// ECTS letters are not among them on purpose: they rank a student among the others of a year, so no average or "what do I need"
/// can be worked out from them.
enum GradeScale {
  percent('Percent (0-100)', worst: 0, best: 100, pass: 50, step: 1),
  gpa('GPA (0.0-4.0)', worst: 0, best: 4, pass: 1, step: 0.1),
  swiss('Swiss (1-6, 6 best)', worst: 1, best: 6, pass: 4, step: 0.25),
  german('German (1.0-5.0, 1.0 best)', worst: 5, best: 1, pass: 4, step: 0.1),
  uk('UK (percent, with classes)', worst: 0, best: 100, pass: 40, step: 1);

  final String label;
  final double worst, best, pass, step;

  const GradeScale(this.label, {required this.worst, required this.best, required this.pass, required this.step});

  static GradeScale byName(String? name) => values.firstWhere((s) => s.name == name, orElse: () => percent);

  /// Whether a higher number is a better grade.
  bool get higherIsBetter => best > worst;

  double get low => math.min(worst, best);
  double get high => math.max(worst, best);

  /// Whether [a] is at least as good as [b].
  bool atLeast(double a, double b) => higherIsBetter ? a >= b - 1e-9 : a <= b + 1e-9;

  bool passes(double grade) => atLeast(grade, pass);

  double clamp(double grade) => grade.clamp(low, high).toDouble();

  /// [grade] rounded to the scale's step, as it would be written down.
  double rounded(double grade) => clamp((grade / step).round() * step);

  /// The grade of a score that is [fraction] (0 to 1) of the most points: the usual linear rule of each scale (Swiss: 1 + 5 x fraction;
  /// German: 4.0 at half the points, 1.0 at all of them, 5.0 under half).
  double fromFraction(double fraction) {
    final f = fraction.clamp(0.0, 1.0);
    return switch (this) {
      percent || uk => 100 * f,
      gpa => 4 * f,
      swiss => 1 + 5 * f,
      german => f < 0.5 ? 5.0 : 4 - 3 * (f - 0.5) / 0.5,
    };
  }

  /// A word for [grade] where the scale has one (the classes of a UK degree).
  String? className(double grade) => this != uk
      ? null
      : grade >= 70
          ? 'First'
          : grade >= 60
              ? 'Upper second (2:1)'
              : grade >= 50
                  ? 'Lower second (2:2)'
                  : grade >= 40
                      ? 'Third'
                      : 'Fail';
}

/// One part of a course that is graded: an exam, an assignment, a quiz, a lab...
class Assessment {
  final String id, name;

  /// What kind of part it is: exam, assignment, quiz, lab, other.
  final String kind;

  /// How much it counts (relative to the others: they need not add up to 100).
  final double weight;
  final DateTime? due;

  /// The grade it got, on the course's scale; or the points it got out of [maxPoints] (turned into a grade by the scale). Neither:
  /// not graded yet.
  final double? grade;
  final double? points, maxPoints;

  /// Whether it counts towards the course grade (a practice exam does not).
  final bool counts;

  const Assessment({
    required this.id,
    required this.name,
    this.kind = 'exam',
    this.weight = 1,
    this.due,
    this.grade,
    this.points,
    this.maxPoints,
    this.counts = true,
  });

  /// The grade on [scale]: the one given, or the points made into one; null when not graded yet.
  double? gradeOn(GradeScale scale) {
    if (grade != null) return scale.clamp(grade!);
    if (points != null && maxPoints != null && maxPoints! > 0) return scale.fromFraction(points! / maxPoints!);
    return null;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'w': weight,
        'due': ?due?.toIso8601String(),
        'g': ?grade,
        'p': ?points,
        'max': ?maxPoints,
        if (!counts) 'counts': false,
      };

  static Assessment? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['name'] is! String) return null;
    double? n(Object? v) => v is num ? v.toDouble() : null;
    return Assessment(
      id: j['id'] as String,
      name: j['name'] as String,
      kind: j['kind'] is String ? j['kind'] as String : 'exam',
      weight: math.max(0, n(j['w']) ?? 1),
      due: j['due'] is String ? DateTime.tryParse(j['due'] as String) : null,
      grade: n(j['g']),
      points: n(j['p']),
      maxPoints: n(j['max']),
      counts: j['counts'] != false,
    );
  }

  Assessment copyWith({String? name, String? kind, double? weight, DateTime? Function()? due, double? Function()? grade, double? Function()? points, double? Function()? maxPoints, bool? counts}) =>
      Assessment(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        weight: weight ?? this.weight,
        due: due == null ? this.due : due(),
        grade: grade == null ? this.grade : grade(),
        points: points == null ? this.points : points(),
        maxPoints: maxPoints == null ? this.maxPoints : maxPoints(),
        counts: counts ?? this.counts,
      );
}

/// What is needed on the parts not graded yet to end with a grade.
sealed class Needed {
  const Needed();
}

/// The target is reached whatever comes (even the worst grade on what is left).
class AlreadyReached extends Needed {
  const AlreadyReached();
}

/// The target cannot be reached any more (not even with the best grade on what is left).
class NotReachable extends Needed {
  /// The best the course can still end with.
  final double best;
  const NotReachable(this.best);
}

/// This grade (on average) on what is left reaches the target.
class NeedGrade extends Needed {
  final double grade;
  const NeedGrade(this.grade);
}

/// The grades of one course on [scale].
class CourseGrades {
  final GradeScale scale;
  final List<Assessment> parts;

  CourseGrades(this.scale, Iterable<Assessment> parts) : parts = [for (final p in parts) if (p.counts && p.weight > 0) p];

  Iterable<(Assessment, double)> get _graded => [
        for (final p in parts)
          if (p.gradeOn(scale) case final g?) (p, g),
      ];

  double get gradedWeight => _graded.fold(0.0, (s, e) => s + e.$1.weight);
  double get remainingWeight => parts.where((p) => p.gradeOn(scale) == null).fold(0.0, (s, p) => s + p.weight);
  double get totalWeight => gradedWeight + remainingWeight;

  /// The average of what is graded, by weight; null when nothing is.
  double? get average {
    final w = gradedWeight;
    if (w <= 0) return null;
    return _graded.fold(0.0, (s, e) => s + e.$1.weight * e.$2) / w;
  }

  /// The share of the course that is graded already (0 to 1).
  double get done => totalWeight <= 0 ? 0 : gradedWeight / totalWeight;

  /// What is needed on what is left to end with [target].
  Needed neededFor(double target) {
    final total = totalWeight, rest = remainingWeight;
    final sum = _graded.fold(0.0, (s, e) => s + e.$1.weight * e.$2);
    if (rest <= 0) {
      final avg = average;
      return avg != null && scale.atLeast(avg, target) ? const AlreadyReached() : NotReachable(avg ?? scale.worst);
    }
    final need = (target * total - sum) / rest;
    if (scale.atLeast(scale.worst, need)) return const AlreadyReached();
    if (!scale.atLeast(scale.best, need)) return NotReachable((sum + scale.best * rest) / total);
    return NeedGrade(need);
  }
}

/// The average of several courses by their credits (only those with a grade, all on [scale]); null when none has one.
double? creditAverage(GradeScale scale, Iterable<({double credits, double? grade})> courses) {
  var w = 0.0, s = 0.0;
  for (final c in courses) {
    if (c.grade == null || c.credits <= 0) continue;
    w += c.credits;
    s += c.credits * c.grade!;
  }
  return w <= 0 ? null : s / w;
}
