import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/event_dialogs.dart';
import 'package:notes/sync/caldav_remote.dart';

void main() {
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
