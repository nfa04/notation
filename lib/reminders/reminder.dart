/// What a reminder is about.
enum ReminderKind {
  /// Only a text ("call the dentist").
  custom,

  /// A note to come back to; tapping the notification opens it.
  note,

  /// A task of the calendar.
  task,

  /// The weekly review: tapping the notification offers to make it.
  review,
}

/// How often a reminder comes again.
enum Repeat {
  none('Once'),
  daily('Every day'),
  weekly('Every week'),
  monthly('Every month'),
  yearly('Every year');

  final String label;
  const Repeat(this.label);

  static Repeat byName(String? name) => values.where((r) => r.name == name).firstOrNull ?? Repeat.none;
}

/// A time at which the person wants to be told something.
class Reminder {
  final String id;
  final ReminderKind kind;

  /// The note or task it is about; null for a custom one.
  final String? refId;

  /// What the notification says (the title of the note, the task, or what the person wrote).
  final String title;

  /// When it first goes off; a repeating reminder keeps this as the start and the time of day.
  final DateTime at;
  final Repeat repeat;

  /// Made by the app for a task with a due date (the person did not set it up).
  final bool auto;

  /// The occurrence that was last announced; null while none was. A reminder is not announced twice for one occurrence.
  final DateTime? firedTo;

  const Reminder({
    required this.id,
    required this.kind,
    this.refId,
    required this.title,
    required this.at,
    this.repeat = Repeat.none,
    this.auto = false,
    this.firedTo,
  });

  Reminder copyWith({String? title, DateTime? at, Repeat? repeat, DateTime? firedTo, bool clearFired = false}) => Reminder(
        id: id,
        kind: kind,
        refId: refId,
        title: title ?? this.title,
        at: at ?? this.at,
        repeat: repeat ?? this.repeat,
        auto: auto,
        firedTo: clearFired ? null : (firedTo ?? this.firedTo),
      );

  /// The occurrence that has not been announced yet and comes first; null when there is none (a reminder that went off once).
  DateTime? get pending => firedTo == null ? at : (repeat == Repeat.none ? null : occurrenceAfter(at, repeat, firedTo!));

  /// The occurrences from [from] on, at most [count] of them and none after [until].
  List<DateTime> occurrencesFrom(DateTime from, {int count = 6, DateTime? until}) {
    final out = <DateTime>[];
    var next = occurrenceAtOrAfter(at, repeat, from);
    while (next != null && out.length < count && (until == null || !next.isAfter(until))) {
      out.add(next);
      next = repeat == Repeat.none ? null : occurrenceAfter(at, repeat, next);
    }
    return out;
  }
}

/// The [n]-th occurrence of a reminder that starts at [start] (0 is [start] itself). A day that a month does not have (the 31st in
/// April, the 29th of February in a year without it) is the last day of that month. It is counted from [start], so one short month
/// does not move the later ones.
DateTime occurrence(DateTime start, Repeat repeat, int n) {
  switch (repeat) {
    case Repeat.none:
      return start;
    case Repeat.daily:
      return DateTime(start.year, start.month, start.day + n, start.hour, start.minute);
    case Repeat.weekly:
      return DateTime(start.year, start.month, start.day + 7 * n, start.hour, start.minute);
    case Repeat.monthly:
      final months = start.year * 12 + (start.month - 1) + n;
      return _inMonth(months ~/ 12, months % 12 + 1, start);
    case Repeat.yearly:
      return _inMonth(start.year + n, start.month, start);
  }
}

DateTime _inMonth(int year, int month, DateTime start) {
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, start.day > last ? last : start.day, start.hour, start.minute);
}

/// The first occurrence at or after [t]; null for a one-time reminder that is over.
DateTime? occurrenceAtOrAfter(DateTime start, Repeat repeat, DateTime t) {
  if (repeat == Repeat.none) return start.isBefore(t) ? null : start;
  if (!start.isBefore(t)) return start;
  // a guess from the distance, then a step or two to be exact
  var n = _guess(start, repeat, t);
  while (n > 0 && !occurrence(start, repeat, n - 1).isBefore(t)) {
    n--;
  }
  while (occurrence(start, repeat, n).isBefore(t)) {
    n++;
  }
  return occurrence(start, repeat, n);
}

/// The first occurrence strictly after [t]; null for a one-time reminder that is over.
DateTime? occurrenceAfter(DateTime start, Repeat repeat, DateTime t) {
  var o = occurrenceAtOrAfter(start, repeat, t);
  while (o != null && !o.isAfter(t)) {
    o = occurrenceAtOrAfter(start, repeat, o.add(const Duration(minutes: 1)));
  }
  return o;
}

/// The last occurrence at or before [t]; null when none has come yet.
DateTime? occurrenceAtOrBefore(DateTime start, Repeat repeat, DateTime t) {
  if (start.isAfter(t)) return null;
  if (repeat == Repeat.none) return start;
  var n = _guess(start, repeat, t);
  while (occurrence(start, repeat, n).isAfter(t)) {
    n--;
  }
  while (!occurrence(start, repeat, n + 1).isAfter(t)) {
    n++;
  }
  return occurrence(start, repeat, n);
}

/// About how many steps from [start] to [t] (never below 0).
int _guess(DateTime start, Repeat repeat, DateTime t) {
  final n = switch (repeat) {
    Repeat.daily => t.difference(start).inDays,
    Repeat.weekly => t.difference(start).inDays ~/ 7,
    Repeat.monthly => (t.year - start.year) * 12 + t.month - start.month,
    _ => t.year - start.year,
  };
  return n < 0 ? 0 : n;
}
