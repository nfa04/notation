import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/event_dialogs.dart';
import 'package:notes/sync/caldav_remote.dart';

void main() {
  optionTests();
  editingTests();
  testWidgets('an event is asked for, written to the chosen calendar, and a failure is shown without closing', (tester) async {
    final saved = <(CalendarInfo, NewEvent)>[];
    var fail = true;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => newEventDialog(
            context,
            day: DateTime(2026, 11, 5),
            targets: const [CalendarInfo('/cal/uni/', 'Uni', null), CalendarInfo('phone:7', 'Phone', null)],
            save: (target, event) async {
              if (fail) throw StateError('The server said no.');
              saved.add((target, event));
            },
          ),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('event-title')), 'Exam');
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-problem')), findsOneWidget);
    expect(find.text('The server said no.'), findsOneWidget);

    fail = false;
    await tester.tap(find.byKey(const ValueKey('event-allday')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-title')), findsNothing);
    expect(saved.single.$1.name, 'Uni');
    expect(saved.single.$2.title, 'Exam');
    expect(saved.single.$2.allDay, isTrue);
    expect(saved.single.$2.start, DateTime(2026, 11, 5));
    expect(saved.single.$2.end, isNull);
  });
}

void editingTests() {
  testWidgets('editing starts with the event, keeps its calendar, and saves the changed event', (tester) async {
    final saved = <(CalendarInfo, NewEvent)>[];
    final existing = DayEvent(
      title: 'Lecture',
      start: DateTime(2026, 11, 26, 10, 15),
      end: DateTime(2026, 11, 26, 11, 45),
      allDay: false,
      calendarName: 'Uni',
      calendarKey: '/cal/uni/',
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => newEventDialog(
            context,
            day: existing.start,
            existing: existing,
            targets: const [CalendarInfo('/cal/other/', 'Other', null), CalendarInfo('/cal/uni/', 'Uni', null)],
            save: (target, event) async => saved.add((target, event)),
          ),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('Edit event'), findsOneWidget);
    expect(find.text('Lecture'), findsOneWidget);
    expect(find.text('10:15'), findsOneWidget);
    expect(find.text('11:45'), findsOneWidget);
    // the calendar is the one it is in; an event whose notes are not known gets no notes field that would blank them
    expect(find.byKey(const ValueKey('event-calendar')), findsOneWidget);
    expect(find.byKey(const ValueKey('event-notes')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('event-title')), 'Lecture (moved)');
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await tester.pumpAndSettle();
    expect(saved.single.$1.name, 'Uni');
    expect(saved.single.$2.title, 'Lecture (moved)');
    expect(saved.single.$2.start, DateTime(2026, 11, 26, 10, 15));
    expect(saved.single.$2.end, DateTime(2026, 11, 26, 11, 45));
  });
}

void optionTests() {
  Future<List<(CalendarInfo, NewEvent)>> open(WidgetTester tester, {DayEvent? existing, List<CalendarInfo>? targets}) async {
    final saved = <(CalendarInfo, NewEvent)>[];
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => newEventDialog(
            context,
            day: DateTime(2026, 11, 26),
            existing: existing,
            targets: targets ?? const [CalendarInfo('/cal/uni/', 'Uni', null), CalendarInfo('phone:7', 'Phone', null)],
            save: (target, event) async => saved.add((target, event)),
          ),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('place, link, reminders, people and a weekly repeat end up in the event', (tester) async {
    final saved = await open(tester);
    await tester.enterText(find.byKey(const ValueKey('event-title')), 'Study group');
    await tester.enterText(find.byKey(const ValueKey('event-location')), 'Library');
    await tester.enterText(find.byKey(const ValueKey('event-link')), 'https://meet.example.org/x');

    await tester.tap(find.byKey(const ValueKey('event-add-alarm')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 min before'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-alarm-10')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('event-invitee')), 'not an address');
    await tester.tap(find.byKey(const ValueKey('event-add-invitee')));
    await tester.pump();
    expect(find.text('Not a valid email address.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('event-invitee')), 'ann@example.org');
    await tester.tap(find.byKey(const ValueKey('event-add-invitee')));
    await tester.pump();
    expect(find.byKey(const ValueKey('event-attendee-ann@example.org')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('event-repeat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every week').last);
    await tester.pumpAndSettle();
    // (26 Nov 2026 is a Thursday: that weekday is on to begin with)
    expect(tester.widget<FilterChip>(find.byKey(const ValueKey('event-repeat-day-4'))).selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('event-repeat-day-1')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('event-save')));
    await tester.pumpAndSettle();
    final event = saved.single.$2;
    expect(event.location, 'Library');
    expect(event.url, 'https://meet.example.org/x');
    expect(event.alarms, [10]);
    expect(event.attendees, ['ann@example.org']);
    expect(event.rrule, 'FREQ=WEEKLY;BYDAY=MO,TH');
  });

  testWidgets('a phone calendar has no repeat and no invitations', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('event-repeat')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('event-calendar')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('event-repeat')), findsNothing);
    expect(find.byKey(const ValueKey('event-invitee')), findsNothing);
    expect(find.byKey(const ValueKey('event-location')), findsOneWidget);
  });

  testWidgets('a repeat the dialog does not know is left as it is, and can be ended', (tester) async {
    final existing = DayEvent(
      title: 'Rent',
      start: DateTime(2026, 11, 27, 9),
      end: DateTime(2026, 11, 27, 10),
      allDay: false,
      calendarName: 'Uni',
      calendarKey: '/cal/uni/',
      repeats: true,
      rrule: 'FREQ=MONTHLY;BYDAY=-1FR',
    );
    final saved = await open(tester, existing: existing);
    expect(find.text('Custom (as set in your calendar app)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await tester.pumpAndSettle();
    expect(saved.single.$2.rrule, isNull, reason: 'not touched: stays what the server has');

    final again = await open(tester, existing: existing);
    await tester.tap(find.byKey(const ValueKey('event-repeat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Does not repeat').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await tester.pumpAndSettle();
    expect(again.single.$2.rrule, '');
  });

  testWidgets('choosing another calendar while editing hands that calendar to save', (tester) async {
    final existing = DayEvent(title: 'Lecture', start: DateTime(2026, 11, 26, 10), end: DateTime(2026, 11, 26, 11), allDay: false, calendarName: 'Uni', calendarKey: '/cal/uni/');
    final saved = await open(tester, existing: existing);
    await tester.tap(find.byKey(const ValueKey('event-calendar')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await tester.pumpAndSettle();
    expect(saved.single.$1.key, 'phone:7');
  });
}
