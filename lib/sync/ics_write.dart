import 'dart:convert';

import 'caldav_remote.dart' show DayEvent, NewEvent;

/// Writing events as iCalendar (RFC 5545): a new event file, or an existing one changed in the few fields the person edited.
/// Everything else in a changed file (organizer, other properties, alarms that were not touched, time zone definitions, the
/// changed single occurrences of a series) stays as the server gave it.

String _two(int n) => n.toString().padLeft(2, '0');
String _date(DateTime d) => '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}';
String _wall(DateTime d) => '${_date(d)}T${_two(d.hour)}${_two(d.minute)}${_two(d.second)}';
String _utc(DateTime d) => '${_wall(d.toUtc())}Z';

/// Text values: backslash, semicolon, comma and line breaks are written escaped.
String escapeIcsText(String s) => s.replaceAll(r'\', r'\\').replaceAll(';', r'\;').replaceAll(',', r'\,').replaceAll('\r\n', r'\n').replaceAll('\n', r'\n').replaceAll('\r', r'\n');

/// A line cut into pieces of at most 75 bytes, each continuation starting with a space.
String foldIcsLine(String line) {
  if (utf8.encode(line).length <= 75) return line;
  final out = StringBuffer();
  var bytes = 0;
  var limit = 75;
  for (final rune in line.runes) {
    final char = String.fromCharCode(rune);
    final n = utf8.encode(char).length;
    if (bytes + n > limit) {
      out.write('\r\n ');
      bytes = 1;
      limit = 75;
    }
    out.write(char);
    bytes += n;
  }
  return out.toString();
}

/// The trigger of an alarm [minutes] before the start.
String alarmTrigger(int minutes) {
  if (minutes <= 0) return 'PT0S';
  if (minutes % 10080 == 0) return '-P${minutes ~/ 10080}W';
  if (minutes % 1440 == 0) return '-P${minutes ~/ 1440}D';
  if (minutes % 60 == 0) return '-PT${minutes ~/ 60}H';
  return '-PT${minutes}M';
}

List<String> _alarmLines(List<int> minutes, String title) => [
      for (final m in minutes.toSet())
        ...['BEGIN:VALARM', 'ACTION:DISPLAY', 'DESCRIPTION:${escapeIcsText(title.isEmpty ? 'Event' : title)}', 'TRIGGER:${alarmTrigger(m)}', 'END:VALARM'],
    ];

String _attendeeLine(String email) => 'ATTENDEE;CN=${email.contains(',') || email.contains(';') || email.contains(':') ? '"$email"' : email};ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:$email';

/// The exclusive end day of an all-day event given as first day and last day (inclusive).
DateTime _exclusiveEnd(NewEvent e) {
  final first = DateTime(e.start.year, e.start.month, e.start.day);
  final last = e.end == null ? first : DateTime(e.end!.year, e.end!.month, e.end!.day);
  final lastDay = last.isBefore(first) ? first : last;
  return DateTime(lastDay.year, lastDay.month, lastDay.day + 1);
}

DateTime _timedEnd(NewEvent e) => e.end ?? e.start.add(const Duration(hours: 1));

/// A new event file for [e] with the UID [uid].
String buildEventIcs(NewEvent e, {required String uid}) {
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Notation//Calendar//EN',
    'BEGIN:VEVENT',
    'UID:$uid',
    'DTSTAMP:${_utc(DateTime.now())}',
    if (e.allDay) ...[
      'DTSTART;VALUE=DATE:${_date(e.start)}',
      'DTEND;VALUE=DATE:${_date(_exclusiveEnd(e))}',
    ] else ...[
      'DTSTART:${_utc(e.start)}',
      'DTEND:${_utc(_timedEnd(e))}',
    ],
    'SUMMARY:${escapeIcsText(e.title)}',
    if (e.description.isNotEmpty) 'DESCRIPTION:${escapeIcsText(e.description)}',
    if (e.location != null && e.location!.isNotEmpty) 'LOCATION:${escapeIcsText(e.location!)}',
    if (e.url != null && e.url!.isNotEmpty) 'URL:${e.url}',
    if (e.rrule != null && e.rrule!.isNotEmpty) 'RRULE:${e.rrule}',
    for (final a in e.attendees ?? const <String>[]) _attendeeLine(a),
    ..._alarmLines(e.alarms ?? const [], e.title),
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return '${lines.map(foldIcsLine).join('\r\n')}\r\n';
}

class _Line {
  final String text;
  _Line(this.text);
  String get name => text.split(RegExp('[;:]')).first.toUpperCase();
  Map<String, String> get params {
    final head = text.substring(0, _colon());
    final out = <String, String>{};
    for (final part in head.split(';').skip(1)) {
      final eq = part.indexOf('=');
      if (eq > 0) out[part.substring(0, eq).toUpperCase()] = part.substring(eq + 1).replaceAll('"', '');
    }
    return out;
  }

  int _colon() {
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '"') quoted = !quoted;
      if (text[i] == ':' && !quoted) return i;
    }
    return text.length - 1;
  }

  String get value => text.substring(_colon() + 1);
}

DateTime? _parseWall(String v) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?)?Z?$').firstMatch(v.trim());
  if (m == null) return null;
  return DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.tryParse(m[4] ?? '') ?? 0, int.tryParse(m[5] ?? '') ?? 0, int.tryParse(m[6] ?? '') ?? 0);
}

/// [raw], an event file as the server has it, with what [e] says changed in its (first, not changed-occurrence) event.
///
/// [old] is the event as it was shown, to tell how far its times moved: the master event of a series is moved by as much as the
/// shown occurrence was, and the time zone the file wrote the time in is kept. A field that [e] leaves null stays as it is.
String patchEventIcs(String raw, NewEvent e, {required DayEvent old}) {
  final lines = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll(RegExp(r'\n[ \t]'), '').split('\n').where((l) => l.isNotEmpty).toList();

  // the master event: from its BEGIN to its END, the first one that is no changed occurrence
  var begin = -1, end = -1;
  for (var i = 0; i < lines.length && end < 0; i++) {
    if (lines[i].toUpperCase() != 'BEGIN:VEVENT') continue;
    var j = i + 1;
    var depth = 0;
    var isOccurrence = false;
    while (j < lines.length && !(depth == 0 && lines[j].toUpperCase() == 'END:VEVENT')) {
      final u = lines[j].toUpperCase();
      if (u.startsWith('BEGIN:')) depth++;
      if (u.startsWith('END:')) depth--;
      if (depth == 0 && u.startsWith('RECURRENCE-ID')) isOccurrence = true;
      j++;
    }
    if (!isOccurrence) {
      begin = i;
      end = j;
    }
    i = j;
  }
  if (begin < 0 || end < 0 || end >= lines.length) throw const FormatException('no event in the file');

  final head = lines.sublist(0, begin + 1);
  final tail = lines.sublist(end);
  final body = lines.sublist(begin + 1, end);

  // properties of the event itself and the blocks (alarms) inside it
  final props = <_Line>[];
  final blocks = <List<String>>[];
  List<String>? open;
  var depth = 0;
  for (final l in body) {
    final u = l.toUpperCase();
    if (u.startsWith('BEGIN:')) {
      depth++;
      open ??= [];
    }
    if (depth > 0) {
      open!.add(l);
    } else {
      props.add(_Line(l));
    }
    if (u.startsWith('END:')) {
      depth--;
      if (depth == 0) {
        blocks.add(open!);
        open = null;
      }
    }
  }

  _Line? find(String name) => props.where((p) => p.name == name).firstOrNull;
  void drop(String name) => props.removeWhere((p) => p.name == name);

  final oldStart = find('DTSTART');
  final startValue = oldStart == null ? null : _parseWall(oldStart.value);
  final zone = oldStart?.params['TZID'];
  final wasUtc = oldStart != null && oldStart.value.trim().endsWith('Z');
  final wasDate = oldStart != null && (oldStart.params['VALUE'] == 'DATE' || !oldStart.value.contains('T'));

  final delta = e.start.difference(old.start);
  final length = e.allDay ? _exclusiveEnd(e).difference(DateTime(e.start.year, e.start.month, e.start.day)) : _timedEnd(e).difference(e.start);
  final oldLength = old.allDay
      ? (old.end == null ? const Duration(days: 1) : DateTime(old.end!.year, old.end!.month, old.end!.day + 1).difference(DateTime(old.start.year, old.start.month, old.start.day)))
      : (old.end ?? old.start.add(const Duration(hours: 1))).difference(old.start);
  final timesChanged = delta != Duration.zero || length != oldLength || e.allDay != old.allDay;

  final extra = <String>[];
  if (timesChanged && startValue != null) {
    if (e.allDay) {
      final first = wasDate ? DateTime.utc(startValue.year, startValue.month, startValue.day + delta.inDays) : DateTime(e.start.year, e.start.month, e.start.day);
      final last = DateTime(first.year, first.month, first.day + length.inDays);
      drop('DTSTART');
      drop('DTEND');
      drop('DURATION');
      extra.add('DTSTART;VALUE=DATE:${_date(first)}');
      extra.add('DTEND;VALUE=DATE:${_date(last)}');
    } else {
      // (the master moves as far as the shown occurrence did; from a date, the shown time is written)
      final first = wasDate ? e.start : startValue.add(delta);
      final last = first.add(length);
      drop('DTSTART');
      drop('DTEND');
      drop('DURATION');
      if (wasDate) {
        extra.add('DTSTART:${_utc(e.start)}');
        extra.add('DTEND:${_utc(e.start.add(length))}');
      } else if (zone != null) {
        extra.add('DTSTART;TZID=$zone:${_wall(first)}');
        extra.add('DTEND;TZID=$zone:${_wall(last)}');
      } else if (wasUtc) {
        extra.add('DTSTART:${_wall(first)}Z');
        extra.add('DTEND:${_wall(last)}Z');
      } else {
        extra.add('DTSTART:${_wall(first)}');
        extra.add('DTEND:${_wall(last)}');
      }
    }
  }

  drop('SUMMARY');
  extra.add('SUMMARY:${escapeIcsText(e.title)}');
  if (!e.keepNotes) {
    drop('DESCRIPTION');
    if (e.description.isNotEmpty) extra.add('DESCRIPTION:${escapeIcsText(e.description)}');
  }
  if (e.location != null) {
    drop('LOCATION');
    if (e.location!.isNotEmpty) extra.add('LOCATION:${escapeIcsText(e.location!)}');
  }
  if (e.url != null) {
    drop('URL');
    if (e.url!.isNotEmpty) extra.add('URL:${e.url}');
  }
  if (e.rrule != null) {
    drop('RRULE');
    if (e.rrule!.isEmpty) {
      drop('EXDATE');
    } else {
      extra.add('RRULE:${e.rrule}');
    }
  }
  if (e.attendees != null) {
    // (the ones that stay keep what they answered)
    final wanted = {for (final a in e.attendees!) a.toLowerCase(): a};
    final kept = <String>{};
    props.removeWhere((p) {
      if (p.name != 'ATTENDEE') return false;
      final mail = p.value.toLowerCase().startsWith('mailto:') ? p.value.substring(7).trim().toLowerCase() : '';
      if (wanted.containsKey(mail)) {
        kept.add(mail);
        return false;
      }
      return true;
    });
    for (final entry in wanted.entries) {
      if (!kept.contains(entry.key)) extra.add(_attendeeLine(entry.value));
    }
  }
  final sequence = int.tryParse(find('SEQUENCE')?.value ?? '') ?? 0;
  drop('SEQUENCE');
  drop('DTSTAMP');
  drop('LAST-MODIFIED');
  extra.add('SEQUENCE:${sequence + 1}');
  extra.add('DTSTAMP:${_utc(DateTime.now())}');

  // (alarms are only replaced when the dialog said what they are; other nested blocks stay)
  final alarms = [
    for (final b in blocks)
      if (e.alarms == null || b.first.toUpperCase() != 'BEGIN:VALARM') ...b,
    if (e.alarms != null) ..._alarmLines(e.alarms!, e.title),
  ];

  final all = [...head, ...props.map((p) => p.text), ...extra, ...alarms, ...tail];
  return '${all.map(foldIcsLine).join('\r\n')}\r\n';
}
