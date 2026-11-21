import 'dart:math' as math;

import '../l10n/language.dart';
import 'study_material.dart';

/// The hours of a day that may be studied in, as minutes after midnight ([end] after [start]).
class StudyWindow {
  final int start, end;
  const StudyWindow(this.start, this.end);

  int get length => end - start;

  @override
  bool operator ==(Object other) => other is StudyWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// When and how long to study: the hours of each weekday (1 = Monday; a day that has none is a day off), at most how many minutes a day,
/// how long a session is and the break between two of them.
class StudyTime {
  final Map<int, StudyWindow> windows;
  final int maxPerDay;
  final int sessionLength;
  final int breakMinutes;

  /// Kept free before and after another event (getting there, getting into it).
  final int bufferMinutes;

  const StudyTime({required this.windows, this.maxPerDay = 120, this.sessionLength = 45, this.breakMinutes = 15, this.bufferMinutes = 10});

  /// The same hours every day but [daysOff].
  factory StudyTime.daily(StudyWindow window, {Set<int> daysOff = const {}, int maxPerDay = 120, int sessionLength = 45}) => StudyTime(
        windows: {for (var d = 1; d <= 7; d++) if (!daysOff.contains(d)) d: window},
        maxPerDay: maxPerDay,
        sessionLength: sessionLength,
      );
}

/// A time that is taken (an event of a calendar, a session of another plan, a time the person said no to).
typedef Busy = ({DateTime start, DateTime end});

/// What part of the work a piece of a session is.
enum WorkKind {
  /// The first going-through of a part of the material.
  learn,

  /// The later going-over of it.
  review,

  /// The flashcards that are due (spaced repetition decides which).
  cards,

  /// The day of the exam: a short last look.
  lastLook,
}

/// One thing to do in a session: a share ([from] to [to], 0..1) of the learning or the going-over of a unit, or the cards.
class SessionItem {
  final WorkKind kind;

  /// The unit (null for the cards and the last look).
  final String? unitId;
  final double from, to;
  final int minutes;

  const SessionItem(this.kind, {this.unitId, this.from = 0, this.to = 1, required this.minutes});

  Map<String, Object?> toJson() => {'k': kind.name, if (unitId != null) 'u': unitId, 'f': from, 't': to, 'm': minutes};

  static SessionItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = WorkKind.values.where((k) => k.name == j['k']).firstOrNull;
    if (kind == null) return null;
    return SessionItem(kind,
        unitId: j['u'] as String?, from: (j['f'] as num?)?.toDouble() ?? 0, to: (j['t'] as num?)?.toDouble() ?? 1, minutes: (j['m'] as num?)?.toInt() ?? 0);
  }

  @override
  bool operator ==(Object other) =>
      other is SessionItem && other.kind == kind && other.unitId == unitId && (other.from - from).abs() < 1e-6 && (other.to - to).abs() < 1e-6 && other.minutes == minutes;

  @override
  int get hashCode => Object.hash(kind, unitId, (from * 1000).round(), (to * 1000).round(), minutes);
}

/// A session of the plan: when, how long, and what to do in it.
class PlannedSession {
  final DateTime start;
  final int minutes;
  final List<SessionItem> items;

  const PlannedSession(this.start, this.minutes, this.items);

  DateTime get end => start.add(Duration(minutes: minutes));

  /// Which session of its plan this is: its day and the time it starts (two sessions of a plan never start at the same time).
  String get key => sessionKey(start);
}

String sessionKey(DateTime start) =>
    '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}T'
    '${start.hour.toString().padLeft(2, '0')}${start.minute.toString().padLeft(2, '0')}';

/// The sessions that were found, and what did not fit.
class StudySchedule {
  final List<PlannedSession> sessions;

  /// Minutes of learning that found no time, and the units they belong to (in the order of the material).
  final int learnLeftOver;
  final List<String> unitsLeftOver;

  /// Minutes of going over that found no time (they are the first thing given up when time is short).
  final int reviewLeftOver;

  /// Minutes the work needs, and minutes there are in the hours given (both without the cards).
  final int needed, available;

  const StudySchedule(this.sessions, {this.learnLeftOver = 0, this.unitsLeftOver = const [], this.reviewLeftOver = 0, this.needed = 0, this.available = 0});

  bool get fits => learnLeftOver == 0 && reviewLeftOver == 0;
}

/// How much of a unit's learning and going-over is done (0..1 each).
typedef UnitProgress = ({double learned, double reviewed});

/// A session is never shorter than this (but for the last piece of work, and the cards alone).
const _shortest = 15;

DateTime _at(DateTime day, int minutes) => DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60);

/// The free stretches of [day] in [window], after [notBefore] (if that is on the day), without the [busy] times and a buffer around them.
List<(int, int)> freeStretches(DateTime day, StudyWindow window, List<Busy> busy, {DateTime? notBefore, int buffer = 10}) {
  var start = window.start;
  if (notBefore != null && notBefore.year == day.year && notBefore.month == day.month && notBefore.day == day.day) {
    // from the next quarter of an hour
    final now = notBefore.hour * 60 + notBefore.minute;
    start = math.max(start, ((now + 14) ~/ 15) * 15);
  }
  var free = <(int, int)>[if (window.end > start) (start, window.end)];
  final dayStart = DateTime(day.year, day.month, day.day);
  for (final b in busy) {
    final from = b.start.difference(dayStart).inMinutes - buffer, to = b.end.difference(dayStart).inMinutes + buffer;
    if (to <= 0 || from >= 24 * 60) continue;
    free = [
      for (final (a, z) in free) ...[
        if (from > a) (a, math.min(z, from)),
        if (to < z) (math.max(a, to), z),
      ],
    ].where((s) => s.$2 > s.$1).toList();
  }
  return free;
}

/// The places for sessions on [day]: as many [StudyTime.sessionLength] blocks as the free stretches hold, a break between two, a shorter
/// one where a stretch has room for at least a quarter of an hour, and no more than [StudyTime.maxPerDay] minutes in all.
List<(DateTime, int)> sessionSlots(DateTime day, StudyTime time, List<Busy> busy, {DateTime? notBefore}) {
  final window = time.windows[day.weekday];
  if (window == null) return const [];
  final out = <(DateTime, int)>[];
  var left = time.maxPerDay;
  for (final (a, z) in freeStretches(day, window, busy, notBefore: notBefore, buffer: time.bufferMinutes)) {
    var at = a;
    while (left >= _shortest && z - at >= _shortest) {
      final length = math.min(math.min(time.sessionLength, z - at), left);
      out.add((_at(day, at), length));
      left -= length;
      at += length + time.breakMinutes;
    }
  }
  return out;
}

class _Piece {
  final WorkKind kind;
  final StudyUnit unit;

  /// The share it began at, the share done so far and the share it ends at; [minutes] is for the whole of [start]..[to].
  final double start, to;
  double from;
  final int minutes;

  _Piece(this.kind, this.unit, double from, this.to, this.minutes)
      : start = from,
        from = from;

  int get left => to - start < 1e-9 ? 0 : (minutes * (to - from) / (to - start)).round();
}

/// The sessions from [now] to the exam on [exam]: the units are learnt in their order and gone over after that, spread evenly over the
/// time there is rather than crammed into the first days. Each day that has a session also has [cardMinutes] for that day's cards (as
/// the card plan gives it); on the day of the exam there is one short last look before [examTime] (minutes after midnight; null: any time
/// in the window). [progress] is what is done of each unit already. A unit that does not fit is said, with the minutes that are missing.
StudySchedule scheduleStudy({
  required DateTime now,
  required DateTime exam,
  int? examTime,
  required List<StudyUnit> units,
  Map<String, UnitProgress> progress = const {},
  required StudyTime time,
  List<Busy> busy = const [],
  Map<DateTime, int> cardMinutes = const {},
  bool lastLook = true,
}) {
  final today = DateTime(now.year, now.month, now.day), examDay = DateTime(exam.year, exam.month, exam.day);
  if (examDay.isBefore(today)) return const StudySchedule([]);

  // the places there are, day by day
  final days = <DateTime, List<(DateTime, int)>>{};
  for (var d = today; d.isBefore(examDay); d = DateTime(d.year, d.month, d.day + 1)) {
    final slots = sessionSlots(d, time, busy, notBefore: now);
    if (slots.isNotEmpty) days[d] = slots;
  }

  // the cards of a day come first, in its first place
  final cardsOf = <DateTime, int>{};
  for (final e in days.entries) {
    final c = cardMinutes[DateTime(e.key.year, e.key.month, e.key.day)] ?? 0;
    if (c > 0) cardsOf[e.key] = math.min(c, e.value.first.$2);
  }
  int capacityOf(DateTime d) => days[d]!.fold<int>(0, (n, s) => n + s.$2) - (cardsOf[d] ?? 0);
  final available = days.keys.fold<int>(0, (n, d) => n + capacityOf(d));

  // the work, in order: all the learning, then all the going over
  final learn = <_Piece>[], review = <_Piece>[];
  for (final u in units.where((u) => u.included)) {
    final p = progress[u.id] ?? (learned: 0.0, reviewed: 0.0);
    if (p.learned < 0.999) learn.add(_Piece(WorkKind.learn, u, p.learned.clamp(0, 1), 1, (u.learnMinutes * (1 - p.learned.clamp(0, 1))).round()));
    if (p.reviewed < 0.999) review.add(_Piece(WorkKind.review, u, p.reviewed.clamp(0, 1), 1, (u.reviewMinutes * (1 - p.reviewed.clamp(0, 1))).round()));
  }
  final learnNeed = learn.fold<int>(0, (n, p) => n + p.minutes), reviewNeed = review.fold<int>(0, (n, p) => n + p.minutes);
  final needed = learnNeed + reviewNeed;
  // when time is short, the going over is cut back first
  final reviewKept = needed <= available ? reviewNeed : math.max(0, available - learnNeed);
  final reviewScale = reviewNeed == 0 ? 0.0 : reviewKept / reviewNeed;
  final queue = <_Piece>[
    ...learn,
    for (final p in review)
      if (reviewScale > 0) _Piece(p.kind, p.unit, p.from, p.to, math.max(1, (p.minutes * reviewScale).round())),
  ];
  final work = queue.fold<int>(0, (n, p) => n + p.minutes);
  // the share of each day's time that is used, so that the work is spread over all of it
  final pace = available == 0 ? 1.0 : math.min(1.0, work / available);

  final sessions = <PlannedSession>[];
  var allowed = 0.0, used = 0;
  for (final d in days.keys) {
    allowed += pace * capacityOf(d);
    var cards = cardsOf[d] ?? 0;
    var resting = false; // the day is far enough ahead: its later places are not used either (sessions are early, not scattered)
    for (final (start, length) in days[d]!) {
      if (resting && cards == 0) break;
      final items = <SessionItem>[];
      var room = length;
      if (cards > 0) {
        items.add(SessionItem(WorkKind.cards, minutes: cards));
        room -= cards;
        cards = 0;
      }
      // a place is used while the day is behind the pace by at least half a session (or by all that is left)
      final behind = allowed - used;
      final rest = queue.fold<int>(0, (n, p) => n + p.left);
      final use = queue.isNotEmpty && room >= 5 && behind >= math.min(math.min(room, time.sessionLength) / 2, rest) - 1;
      if (!use) resting = true;
      if (use) {
        while (queue.isNotEmpty && room > 0) {
          final p = queue.first;
          final left = p.left;
          if (left <= room) {
            items.add(SessionItem(p.kind, unitId: p.unit.id, from: p.from, to: p.to, minutes: left));
            room -= left;
            used += left;
            queue.removeAt(0);
            continue;
          }
          if (room < 10) break; // not worth starting
          // a share of it: by whole pages where it has pages
          var share = room / left * (p.to - p.from);
          if (p.unit.hasPages) {
            final pages = p.unit.pageCount;
            final whole = ((p.from + share) * pages).floor();
            if (whole <= (p.from * pages).ceil()) {
              share = math.min(p.to - p.from, 1 / pages); // at least one page
            } else {
              share = whole / pages - p.from;
            }
          }
          final minutes = math.max(1, (p.minutes * share / (p.to - p.start)).round());
          if (minutes > room && items.isNotEmpty) break; // one page more than there is room for: the next session
          items.add(SessionItem(p.kind, unitId: p.unit.id, from: p.from, to: p.from + share, minutes: minutes));
          used += minutes;
          room -= minutes;
          p.from += share;
          if (p.to - p.from < 1e-6) queue.removeAt(0);
          break;
        }
      }
      if (items.isEmpty) continue;
      final total = items.fold<int>(0, (n, i) => n + i.minutes);
      final onlyCards = items.every((i) => i.kind == WorkKind.cards);
      sessions.add(PlannedSession(start, onlyCards ? total : math.min(length, math.max(total, _shortest)), items));
    }
  }

  // the day of the exam: a short last look, early enough
  if (lastLook && (units.any((u) => u.included) || cardMinutes.isNotEmpty)) {
    final window = time.windows[examDay.weekday] ?? time.windows.values.firstOrNull;
    if (window != null) {
      final before = examTime == null ? window : StudyWindow(window.start, math.min(window.end, examTime - 60));
      if (before.length >= _shortest) {
        final free = freeStretches(examDay, before, busy, notBefore: now, buffer: time.bufferMinutes);
        final first = free.where((s) => s.$2 - s.$1 >= _shortest).firstOrNull;
        if (first != null) {
          final minutes = math.min(20, first.$2 - first.$1);
          sessions.add(PlannedSession(_at(examDay, first.$1), minutes, [SessionItem(WorkKind.lastLook, minutes: minutes)]));
        }
      }
    }
  }

  final learnLeft = queue.where((p) => p.kind == WorkKind.learn).fold<int>(0, (n, p) => n + p.left);
  final reviewLeft = reviewNeed - reviewKept + queue.where((p) => p.kind == WorkKind.review).fold<int>(0, (n, p) => n + p.left);
  return StudySchedule(
    sessions,
    learnLeftOver: learnLeft,
    unitsLeftOver: [for (final p in queue) if (p.kind == WorkKind.learn) p.unit.id],
    reviewLeftOver: reviewLeft,
    needed: needed,
    available: available,
  );
}

/// The words of an item of a session: which part, which pages.
String itemText(SessionItem item, StudyUnit? unit) {
  switch (item.kind) {
    case WorkKind.cards:
      return tr('Flashcards that are due (about {n} min)', {'n': item.minutes});
    case WorkKind.lastLook:
      return tr('A last look at what is weak');
    case WorkKind.learn:
    case WorkKind.review:
      final title = unit?.title ?? tr('A part that was taken out of the plan');
      final whole = item.from <= 1e-6 && item.to >= 1 - 1e-6;
      var where = '';
      if (!whole && unit != null) {
        if (unit.hasPages) {
          final first = unit.fromPage! + (item.from * unit.pageCount).round(), last = unit.fromPage! + (item.to * unit.pageCount).round() - 1;
          where = ' (${pagesTitle(first, math.max(first, last))})';
        } else {
          where = ' (${(item.from * 100).round()}-${(item.to * 100).round()} %)';
        }
      }
      return item.kind == WorkKind.learn ? tr('Learn: {part}', {'part': '$title$where'}) : tr('Go over: {part}', {'part': '$title$where'});
  }
}

/// What a session is called on the calendar: the plan and the first thing to do in it.
String sessionTitleOf(String plan, PlannedSession s, StudyUnit? Function(String id) unitOf) {
  final main = s.items.where((i) => i.kind == WorkKind.learn || i.kind == WorkKind.review).toList();
  if (s.items.any((i) => i.kind == WorkKind.lastLook)) return tr('{plan}: a last look', {'plan': plan});
  if (main.isEmpty) return tr('{plan}: flashcards', {'plan': plan});
  final first = unitOf(main.first.unitId!)?.title ?? '';
  final others = main.map((i) => i.unitId).toSet().length - 1;
  return others > 0 ? tr('{plan}: {part} and {n} more', {'plan': plan, 'part': first, 'n': others}) : tr('{plan}: {part}', {'plan': plan, 'part': first});
}
