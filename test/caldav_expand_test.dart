import 'package:caldav/caldav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/caldav_remote.dart';

const _weekly = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:weekly
SUMMARY:Standup
DTSTART:20261102T080000Z
DTEND:20261102T083000Z
RRULE:FREQ=WEEKLY;BYDAY=MO
EXDATE:20261116T080000Z
END:VEVENT
BEGIN:VEVENT
UID:weekly
RECURRENCE-ID:20261109T080000Z
SUMMARY:Standup (moved)
DTSTART:20261110T130000Z
DTEND:20261110T133000Z
END:VEVENT
END:VCALENDAR''';

const _single = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:one
SUMMARY:Dentist
DTSTART;VALUE=DATE:20261120
DTEND;VALUE=DATE:20261121
END:VEVENT
END:VCALENDAR''';

void main() {
  final calendar = Calendar(
    uid: 'c',
    displayName: 'Work',
    href: Uri.parse('/remote.php/dav/calendars/me/work/'),
  );

  test('a repeating event shows on every occurrence, with changes and cancellations applied', () {
    final out = expandServerEvents([_weekly, _single], DateTime(2026, 11, 1), DateTime(2026, 12, 1), calendar);
    final standups = out.where((e) => e.title.startsWith('Standup')).toList();
    // 2, 9 (moved to the 10th), [16 cancelled], 23, 30
    expect(standups.length, 4);
    expect(standups.where((e) => e.title == 'Standup (moved)').length, 1);
    expect(out.where((e) => e.title == 'Dentist').length, 1);
    expect(out.every((e) => e.calendarKey == '/remote.php/dav/calendars/me/work/'), isTrue);
  });

  test('the calendar data is picked out of a multistatus answer', () {
    const answer = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response><d:href>/a.ics</d:href><d:propstat><d:prop><c:calendar-data>BEGIN:VCALENDAR
END:VCALENDAR</c:calendar-data></d:prop></d:propstat></d:response>
  <d:response><d:href>/b.ics</d:href><d:propstat><d:prop><d:getetag>"1"</d:getetag></d:prop></d:propstat></d:response>
</d:multistatus>''';
    expect(calendarDataOf(answer).length, 1);
  });
}
