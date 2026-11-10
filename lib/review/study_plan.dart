import 'dart:math' as math;

/// How the cards of a plan stand now.
class CardStats {
  /// Cards never answered.
  final int unseen;

  /// Cards that were answered at least once.
  final int seen;

  /// Cards that are due now.
  final int due;

  /// Cards that were forgotten more than once or are hard to remember (a low ease): the weak spots.
  final int weak;

  const CardStats({this.unseen = 0, this.seen = 0, this.due = 0, this.weak = 0});

  int get total => unseen + seen;
}

/// What to do on one day before the exam.
class StudySession {
  final DateTime day;

  /// Cards to see for the first time.
  final int newCards;

  /// Cards to go over again (those due, and those that are about to be).
  final int reviews;

  /// Of the review, the weak spots, which get more time near the exam.
  final int weak;

  /// About how long it takes.
  final int minutes;

  /// The day of the exam: only a short go over what is weak.
  final bool examDay;

  const StudySession(this.day, {this.newCards = 0, this.reviews = 0, this.weak = 0, this.minutes = 5, this.examDay = false});

  int get cards => newCards + reviews + weak;
}

/// The sessions from today to the exam, and what could not be fitted in.
class StudyPlan {
  final List<StudySession> sessions;

  /// New cards that do not fit in the time (at this many minutes a day they would not all be seen before the exam).
  final int unplanned;

  /// How many cards a day the minutes allow.
  final int capacity;

  const StudyPlan(this.sessions, this.unplanned, this.capacity);
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// The plan that works backwards from the exam: new cards are spread over the first part of the time (so that the last days are for
/// going over them), the cards that are due or soon will be are reviewed every day, the weak spots get more of the last days, and the
/// day of the exam is a short look at what is weak. [minutesPerDay] and [secondsPerCard] give how many cards a day fit; [daysOff] are
/// weekdays (1 = Monday) without a session. The plan is made again every day from where the cards stand then, which is how it adjusts to
/// what was got right: cards that stuck leave less to do, forgotten ones come back as weak spots.
StudyPlan planStudy({
  required DateTime today,
  required DateTime exam,
  required CardStats stats,
  int minutesPerDay = 20,
  Set<int> daysOff = const {},
  int secondsPerCard = 20,
}) {
  final from = _day(today), to = _day(exam);
  final capacity = math.max(5, minutesPerDay * 60 ~/ secondsPerCard);
  if (to.isBefore(from) || stats.total == 0) return StudyPlan(const [], 0, capacity);
  int minutesFor(int cards) => math.max(5, (cards * secondsPerCard / 60).ceil());

  final study = <DateTime>[];
  for (var d = from; d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1)) {
    if (!daysOff.contains(d.weekday)) study.add(d);
  }
  final sessions = <StudySession>[];

  var unseen = stats.unseen, seen = stats.seen;
  final learnDays = study.isEmpty ? 0 : math.max(1, (study.length * 0.7).floor());
  final perDay = learnDays == 0 ? 0 : math.min((capacity * 0.6).floor(), (stats.unseen / learnDays).ceil());
  for (var i = 0; i < study.length; i++) {
    final left = study.length - i;
    final focusWeak = left <= 3;
    final fresh = i < learnDays ? math.min(unseen, perDay) : 0;
    var reviews = math.min(capacity - fresh, math.max(i == 0 ? stats.due : 0, (seen / 4).ceil()));
    var weak = 0;
    if (focusWeak) {
      weak = math.min(stats.weak, capacity ~/ 2);
      reviews = math.max(0, math.min(reviews, capacity - fresh - weak));
    }
    reviews = math.min(reviews, seen);
    weak = math.min(weak, seen);
    unseen -= fresh;
    seen += fresh;
    if (fresh + reviews + weak == 0) continue;
    sessions.add(StudySession(study[i], newCards: fresh, reviews: reviews, weak: weak, minutes: minutesFor(fresh + reviews + weak)));
  }
  // the exam day: a short look at what is weak
  final light = math.min(stats.weak > 0 ? stats.weak : stats.total, math.max(5, capacity ~/ 3));
  sessions.add(StudySession(to, weak: math.min(light, stats.weak), reviews: stats.weak > 0 ? 0 : light, minutes: math.max(5, minutesFor(light) ~/ 2 + 1), examDay: true));
  return StudyPlan(sessions, unseen, capacity);
}

/// The words of a session, for the task it becomes on the calendar.
String sessionTitle(String name, StudySession s) {
  if (s.examDay) return 'Exam day: $name, a last look at what is weak (about ${s.minutes} min)';
  final parts = [
    if (s.newCards > 0) '${s.newCards} new',
    if (s.reviews + s.weak > 0) '${s.reviews + s.weak} to go over${s.weak > 0 ? ' (${s.weak} weak)' : ''}',
  ];
  return 'Study $name: ${parts.join(', ')} (about ${s.minutes} min)';
}
