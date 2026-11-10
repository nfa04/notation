/// A date (and maybe a time of day) found in some text.
class FoundDate {
  final DateTime date;

  /// Minutes after midnight, or null when no time was written.
  final int? minutes;

  /// The line the date stands in, trimmed.
  final String line;

  /// The line without the date and time and the little words that led up to
  /// them ("Midterm exam on 7.3.2026 at 14:30, room B12" is "Midterm exam, room
  /// B12"); empty when nothing else was there.
  final String summary;

  const FoundDate(this.date, this.minutes, this.line, [this.summary = '']);

  /// `14:30`, or '' without a time.
  String get time =>
      minutes == null ? '' : '${(minutes! ~/ 60).toString().padLeft(2, '0')}:${(minutes! % 60).toString().padLeft(2, '0')}';

  /// `2026-03-07`.
  String get day =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// Tells this date from the others in a note, the same across runs.
  String get key {
    var h = 5381;
    for (final c in line.codeUnits) {
      h = ((h * 33) ^ c) & 0x7fffffff;
    }
    return '$day|$time|$h';
  }
}

const _months = <String, int>{
  // English
  'january': 1, 'february': 2, 'march': 3, 'april': 4, 'may': 5, 'june': 6, 'july': 7, 'august': 8,
  'september': 9, 'october': 10, 'november': 11, 'december': 12,
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'sept': 9, 'oct': 10,
  'nov': 11, 'dec': 12,
  // German
  'januar': 1, 'februar': 2, 'märz': 3, 'maerz': 3, 'mai': 5, 'juni': 6, 'juli': 7, 'oktober': 10,
  'dezember': 12, 'mär': 3, 'okt': 10, 'dez': 12,
  // French
  'janvier': 1, 'février': 2, 'fevrier': 2, 'mars': 3, 'avril': 4, 'juin': 6, 'juillet': 7, 'août': 8,
  'aout': 8, 'septembre': 9, 'octobre': 10, 'novembre': 11, 'décembre': 12, 'decembre': 12,
  'janv': 1, 'févr': 2, 'avr': 4, 'juil': 7, 'déc': 12,
};

final _monthNames = (_months.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).join('|');

final _iso = RegExp(r'(?<![\d.])(\d{4})-(\d{1,2})-(\d{1,2})(?![\d])');
final _numeric = RegExp(r'(?<![\d.])(\d{1,2})[./](\d{1,2})[./](\d{4}|\d{2})(?![\d])');
final _dayMonthYear = RegExp('(?<![\\d])(\\d{1,2})(?:st|nd|rd|th)?\\.?\\s*(?:of\\s+)?($_monthNames)\\.?,?\\s+(\\d{4})(?!\\d)',
    caseSensitive: false, unicode: true);
final _monthDayYear = RegExp('(?<![\\p{L}])($_monthNames)\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})(?!\\d)',
    caseSensitive: false, unicode: true);

// a time just after the date: 14:30, 14.30, 14h30, 2 pm, 14 Uhr
final _after = [
  RegExp(r'^[^\d\p{L}]{0,4}(?:(?:at|um|from|ab|à|de|vers)\s+)?([01]?\d|2[0-3])[:.h]([0-5]\d)(?![.:]?\d)',
      caseSensitive: false, unicode: true),
  RegExp(r'^[^\d\p{L}]{0,4}(?:(?:at|um|from)\s+)?(1[0-2]|0?[1-9])(?::([0-5]\d))?\s?(am|pm)\b', caseSensitive: false),
  RegExp(r'^[^\d\p{L}]{0,4}(?:(?:at|um|ab|à)\s+)?([01]?\d|2[0-3])\s?(?:uhr|h)\b(?![.:]?\d)',
      caseSensitive: false, unicode: true),
];
// ... or just before it: "14:00, on 7 March 2026"
final _before = RegExp(r'(?:^|[^\d:.])([01]?\d|2[0-3])[:h]([0-5]\d)[^\d\p{L}]{0,6}(?:(?:on|am|le|den)\s+)?$',
    caseSensitive: false, unicode: true);

/// The time written at the start of [tail] (minutes after midnight) and how much
/// of [tail] it takes up.
(int, int)? _timeAfter(String tail) {
  final a = _after[0].firstMatch(tail);
  if (a != null) return (int.parse(a.group(1)!) * 60 + int.parse(a.group(2)!), a.end);
  final b = _after[1].firstMatch(tail);
  if (b != null) {
    var h = int.parse(b.group(1)!) % 12;
    if (b.group(3)!.toLowerCase() == 'pm') h += 12;
    return (h * 60 + int.parse(b.group(2) ?? '0'), b.end);
  }
  final c = _after[2].firstMatch(tail);
  if (c != null) return (int.parse(c.group(1)!) * 60, c.end);
  return null;
}

// little words that lead up to a date or a time
const _lead = 'on|at|um|am|le|den|vers|from|ab|bis|until|by|to|à';

/// [line] without the [cuts] (start, end), and tidied up.
String summaryOf(String line, List<(int, int)> cuts) {
  final sorted = [...cuts]..sort((a, b) => a.$1.compareTo(b.$1));
  final sb = StringBuffer();
  var at = 0;
  for (final (s, e) in sorted) {
    if (s > at) sb.write(line.substring(at, s));
    sb.write(' ');
    if (e > at) at = e;
  }
  sb.write(line.substring(at.clamp(0, line.length)));
  var t = sb.toString();
  String step(String text, String pattern, String with_) => text.replaceAll(RegExp(pattern, caseSensitive: false, unicode: true), with_);
  t = step(t, r'\s+', ' ');
  t = step(t, r'\s(?:' + _lead + r')(?=\s*(?:[,;:)\]\-–—]|$))', ''); // "exam on , room" -> "exam , room"
  t = step(t, r'^(?:' + _lead + r')\s+', '');
  t = step(t, r'[(\[]\s*[)\]]', ''); // brackets with nothing left in them
  t = t.replaceAllMapped(RegExp(r'\s+([,;:.)\]])'), (m) => m.group(1)!);
  t = t.replaceAllMapped(RegExp(r'([(\[])\s+'), (m) => m.group(1)!);
  t = step(t, r'^[\s,;:.\-–—(\[]+', '');
  t = step(t, r'[\s,;:.\-–—(\[]+$', '');
  t = step(t, r'\s+', ' ').trim();
  if (t.length > 70) {
    final cut = t.lastIndexOf(' ', 70);
    t = '${t.substring(0, cut > 30 ? cut : 70).trimRight()}…';
  }
  return t.isEmpty ? '' : t[0].toUpperCase() + t.substring(1);
}

/// The dates written in [lines] that fall on or after [today] and within ten
/// years, with their times where one is given. Formats: `2026-03-07`,
/// `7.3.2026`, `07/03/2026` (day first), `7.3.26`, `7 March 2026`, `March 7,
/// 2026`, also in German and French. A date without a year is not taken.
List<FoundDate> findDates(Iterable<String> lines, DateTime today) {
  final start = DateTime(today.year, today.month, today.day);
  final found = <FoundDate>[];
  final seen = <String>{};

  for (final raw in lines) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) continue;
    final hits = <(int, int, DateTime)>[]; // start, end, date

    DateTime? valid(int y, int m, int d) {
      if (m < 1 || m > 12 || d < 1 || d > 31) return null;
      final date = DateTime(y, m, d);
      if (date.month != m || date.day != d) return null; // 31 February
      if (date.isBefore(start) || date.year > start.year + 10) return null;
      return date;
    }

    for (final m in _iso.allMatches(line)) {
      final d = valid(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
      if (d != null) hits.add((m.start, m.end, d));
    }
    for (final m in _numeric.allMatches(line)) {
      var a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
      var y = int.parse(m.group(3)!);
      if (m.group(3)!.length == 2) {
        // 7.3.26: only years that are near, or a version number like "1.2.34" would pass
        y += 2000;
        if (y < start.year || y > start.year + 2) continue;
      }
      // day first; the other way round only when it cannot be a month
      var day = a, month = b;
      if (b > 12 && a <= 12) {
        day = b;
        month = a;
      }
      final d = valid(y, month, day);
      if (d != null) hits.add((m.start, m.end, d));
    }
    for (final m in _dayMonthYear.allMatches(line)) {
      final d = valid(int.parse(m.group(3)!), _months[m.group(2)!.toLowerCase()]!, int.parse(m.group(1)!));
      if (d != null) hits.add((m.start, m.end, d));
    }
    for (final m in _monthDayYear.allMatches(line)) {
      final d = valid(int.parse(m.group(3)!), _months[m.group(1)!.toLowerCase()]!, int.parse(m.group(2)!));
      if (d != null) hits.add((m.start, m.end, d));
    }

    // the same text matched by two patterns counts once
    hits.sort((x, y) => x.$1.compareTo(y.$1));
    var lastEnd = -1;
    for (final (s, e, date) in hits) {
      if (s < lastEnd) continue;
      lastEnd = e;
      final tail = line.substring(e, (e + 30).clamp(0, line.length));
      final headStart = (s - 24).clamp(0, line.length);
      final head = line.substring(headStart, s);
      final cuts = <(int, int)>[(s, e)];
      int? minutes;
      final after = _timeAfter(tail);
      if (after != null) {
        minutes = after.$1;
        cuts.add((e, e + after.$2));
      } else {
        final b = _before.firstMatch(head);
        if (b != null) {
          minutes = int.parse(b.group(1)!) * 60 + int.parse(b.group(2)!);
          cuts.add((headStart + b.start + b.group(0)!.indexOf(b.group(1)!), s));
        }
      }
      // other dates of the line stay in the summary: they are part of what it says
      final context = line.length > 120 ? line.substring(0, 120) : line;
      final f = FoundDate(date, minutes, context, summaryOf(context, cuts.where((c) => c.$2 <= context.length).toList()));
      if (seen.add(f.key)) found.add(f);
    }
  }
  return found;
}
