import 'date_finder.dart';

/// A line of a note that asks for something to be done: "to do: call the landlord by Friday", "☐ buy paper", "- [ ] send the form".
class TodoItem {
  /// What is to be done, without the marker and without the words that say when.
  final String summary;

  /// The whole line, trimmed.
  final String line;

  /// When, if the line says (a date, "tomorrow", "by Friday"); null otherwise.
  final DateTime? due;

  const TodoItem(this.summary, this.line, this.due);

  /// Tells this item from the others of a note and stays the same when the date it says is worked out again on another day
  /// ("by Friday" is a different day every week, the item is the same).
  String get key {
    var h = 5381;
    for (final c in summary.toLowerCase().replaceAll(RegExp(r'\W+'), ' ').trim().codeUnits) {
      h = ((h * 33) ^ c) & 0x7fffffff;
    }
    return 'todo|$h';
  }
}

// a checkbox that is empty, or one of the words that mark a line as something to do
final _box = RegExp(r'^(?:[-*•]\s*)?(?:\[\s?\]|\(\s?\)|☐|□|⬜|❏)\s*', unicode: true);
final _done = RegExp(r'^(?:[-*•]\s*)?(?:\[[xX✓✔]\]|☑|☒|✅|✓|✔)', unicode: true);
final _word = RegExp(
    r'^(?:[-*•]\s*)?(?:to[\s-]?do|action(?:\s+items?)?|task|aufgabe|zu\s+tun|à\s+faire|a\s+faire)\b\s*[:\-–—.]?\s*',
    caseSensitive: false, unicode: true);

const _days = <String, int>{
  'monday': 1, 'tuesday': 2, 'wednesday': 3, 'thursday': 4, 'friday': 5, 'saturday': 6, 'sunday': 7,
  'montag': 1, 'dienstag': 2, 'mittwoch': 3, 'donnerstag': 4, 'freitag': 5, 'samstag': 6, 'sonntag': 7,
  'lundi': 1, 'mardi': 2, 'mercredi': 3, 'jeudi': 4, 'vendredi': 5, 'samedi': 6, 'dimanche': 7,
};
const _shortDays = <String, int>{'mon': 1, 'tue': 2, 'tues': 2, 'wed': 3, 'thu': 4, 'thur': 4, 'thurs': 4, 'fri': 5, 'sat': 6, 'sun': 7};
const _cue = r'(?:by|until|before|on|bis|am|vor|spätestens|avant|pour)';

final _dayNames = (_days.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).join('|');
final _weekday = RegExp(
    '(?:\\b($_cue)\\s+)?(?:\\b(next|nächsten?|prochain)\\s+)?\\b($_dayNames)\\b(?:\\s+(prochain))?',
    caseSensitive: false, unicode: true);
final _shortWeekday = RegExp('\\b$_cue\\s+(${_shortDays.keys.join('|')})\\b\\.?', caseSensitive: false, unicode: true);
final _relative = RegExp(r'(?:\b(?:by|until|before|on|bis|am|vor|spätestens|pour)\s+)?\b(today|tomorrow|heute|morgen|aujourd.hui|demain|next\s+week|nächste\s+woche|semaine\s+prochaine)\b',
    caseSensitive: false, unicode: true);

/// [line] without the marker that makes it a to-do line (`☐`, `- [ ]`, `to do:`), as it was written otherwise ("pay rent by Friday"); null for
/// a line that is no to-do line or a ticked one.
String? todoText(String line) {
  final l = line.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (_done.hasMatch(l)) return null;
  final marker = _box.firstMatch(l) ?? _word.firstMatch(l);
  final rest = marker == null ? '' : l.substring(marker.end).trim();
  return rest.length < 3 ? null : rest;
}

/// The first day on or after the day after [from] that is weekday [day] (1 = Monday).
DateTime _next(DateTime from, int day) {
  var d = DateTime(from.year, from.month, from.day + 1);
  while (d.weekday != day) {
    d = DateTime(d.year, d.month, d.day + 1);
  }
  return d;
}

/// The to-do lines among [lines]: a line that starts with an empty checkbox (`☐`, `[ ]`, `- [ ]`) or with a word like "to do",
/// "action" or "Aufgabe", and has something after it. A ticked box is done, and left out. When the line says when it is due, that is [TodoItem.due]:
/// a date with a year (see [findDates]), today, tomorrow, next week, or a day of the week ("by Friday" is the next Friday, never today).
/// The same item twice counts once.
List<TodoItem> findTodos(Iterable<String> lines, DateTime today) {
  final base = DateTime(today.year, today.month, today.day);
  final found = <TodoItem>[];
  final seen = <String>{};
  for (final raw in lines) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty || _done.hasMatch(line)) continue;
    final marker = _box.firstMatch(line) ?? _word.firstMatch(line);
    if (marker == null) continue;
    var rest = line.substring(marker.end).trim();
    if (rest.length < 3) continue;

    DateTime? due;
    final cuts = <(int, int)>[];
    final date = findDates([rest], base).firstOrNull;
    if (date != null) {
      due = date.date;
      rest = date.summary.isEmpty ? rest : date.summary;
    } else {
      final rel = _relative.firstMatch(rest);
      final day = _weekday.firstMatch(rest);
      final short = day == null ? _shortWeekday.firstMatch(rest) : null;
      if (rel != null) {
        final w = rel.group(1)!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        due = switch (w) {
          'today' || 'heute' => base,
          'tomorrow' || 'morgen' || 'demain' => DateTime(base.year, base.month, base.day + 1),
          _ when w.startsWith('aujourd') => base,
          _ => DateTime(base.year, base.month, base.day + 7),
        };
        cuts.add((rel.start, rel.end));
      } else if (day != null) {
        due = _next(base, _days[day.group(3)!.toLowerCase()]!);
        // "next Friday" said on a Monday means the Friday after this one
        if (day.group(2) != null && due.difference(base).inDays < 7 && base.weekday < due.weekday && due.weekday != 7) {
          due = DateTime(due.year, due.month, due.day + 7);
        }
        cuts.add((day.start, day.end));
      } else if (short != null) {
        due = _next(base, _shortDays[short.group(1)!.toLowerCase()]!);
        cuts.add((short.start, short.end));
      }
      if (cuts.isNotEmpty) rest = summaryOf(rest, cuts);
    }
    if (rest.length < 3) continue;
    if (rest.length > 120) rest = '${rest.substring(0, 119).trimRight()}…';
    rest = rest[0].toUpperCase() + rest.substring(1);
    final item = TodoItem(rest, line.length > 160 ? line.substring(0, 160) : line, due);
    if (seen.add(item.key)) found.add(item);
  }
  return found;
}
