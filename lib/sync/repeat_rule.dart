/// A repeat rule as the event dialog offers it: how often, every how many, on which weekdays (weekly), and when it ends. It reads
/// and writes the RRULE of an event; a rule with more in it than this (the third Friday of the month, a list of month days) is
/// not representable here, and the dialog then leaves it exactly as it is.
enum RepeatFrequency { daily, weekly, monthly, yearly }

/// How a repeat ends.
enum RepeatEnd { never, onDay, afterCount }

class RepeatRule {
  final RepeatFrequency frequency;
  final int interval;

  /// 1 = Monday ... 7 = Sunday; only for a weekly rule (empty: the weekday of the event).
  final Set<int> weekdays;
  final RepeatEnd end;
  final DateTime? until; // a day
  final int? count;

  const RepeatRule({
    required this.frequency,
    this.interval = 1,
    this.weekdays = const {},
    this.end = RepeatEnd.never,
    this.until,
    this.count,
  });

  static const _days = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

  /// The rule written by [toRrule]; null when [rrule] is empty or has anything this does not know.
  static RepeatRule? parse(String? rrule) {
    if (rrule == null || rrule.trim().isEmpty) return null;
    final parts = <String, String>{};
    for (final p in rrule.split(';')) {
      final eq = p.indexOf('=');
      if (eq > 0) parts[p.substring(0, eq).toUpperCase()] = p.substring(eq + 1);
    }
    const known = {'FREQ', 'INTERVAL', 'BYDAY', 'UNTIL', 'COUNT', 'WKST'};
    if (parts.keys.any((k) => !known.contains(k))) return null;
    final frequency = {'DAILY': RepeatFrequency.daily, 'WEEKLY': RepeatFrequency.weekly, 'MONTHLY': RepeatFrequency.monthly, 'YEARLY': RepeatFrequency.yearly}[parts['FREQ']];
    if (frequency == null) return null;
    final interval = int.tryParse(parts['INTERVAL'] ?? '1');
    if (interval == null || interval < 1) return null;
    final weekdays = <int>{};
    if (parts.containsKey('BYDAY')) {
      // (only plain weekdays of a weekly rule: "1FR" or a day in a monthly rule is something else)
      if (frequency != RepeatFrequency.weekly) return null;
      for (final d in parts['BYDAY']!.split(',')) {
        final i = _days.indexOf(d.toUpperCase());
        if (i < 0) return null;
        weekdays.add(i + 1);
      }
    }
    if (parts.containsKey('UNTIL') && parts.containsKey('COUNT')) return null;
    DateTime? until;
    int? count;
    if (parts.containsKey('UNTIL')) {
      final m = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(parts['UNTIL']!);
      if (m == null) return null;
      until = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    }
    if (parts.containsKey('COUNT')) {
      count = int.tryParse(parts['COUNT']!);
      if (count == null || count < 1) return null;
    }
    return RepeatRule(
      frequency: frequency,
      interval: interval,
      weekdays: weekdays,
      end: until != null ? RepeatEnd.onDay : (count != null ? RepeatEnd.afterCount : RepeatEnd.never),
      until: until,
      count: count,
    );
  }

  /// The RRULE (without the `RRULE:` prefix). The end day is written as the end of that day in UTC for a timed event ([allDay] false).
  String toRrule({bool allDay = false}) {
    String two(int n) => n.toString().padLeft(2, '0');
    final b = StringBuffer('FREQ=${frequency.name.toUpperCase()}');
    if (interval > 1) b.write(';INTERVAL=$interval');
    if (frequency == RepeatFrequency.weekly && weekdays.isNotEmpty) {
      final sorted = weekdays.toList()..sort();
      b.write(';BYDAY=${sorted.map((d) => _days[d - 1]).join(',')}');
    }
    if (end == RepeatEnd.onDay && until != null) {
      final u = until!;
      final day = '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}';
      if (allDay) {
        b.write(';UNTIL=$day');
      } else {
        final endOfDay = DateTime(u.year, u.month, u.day, 23, 59, 59).toUtc();
        b.write(';UNTIL=${endOfDay.year.toString().padLeft(4, '0')}${two(endOfDay.month)}${two(endOfDay.day)}T${two(endOfDay.hour)}${two(endOfDay.minute)}${two(endOfDay.second)}Z');
      }
    } else if (end == RepeatEnd.afterCount && count != null) {
      b.write(';COUNT=$count');
    }
    return b.toString();
  }

  RepeatRule copyWith({RepeatFrequency? frequency, int? interval, Set<int>? weekdays, RepeatEnd? end, DateTime? until, int? count}) => RepeatRule(
        frequency: frequency ?? this.frequency,
        interval: interval ?? this.interval,
        weekdays: weekdays ?? this.weekdays,
        end: end ?? this.end,
        until: until ?? this.until,
        count: count ?? this.count,
      );
}
