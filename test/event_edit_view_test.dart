import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/event_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/calendar_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  weekTests();
  setUpAll(AppDatabase.initFfi);

  testWidgets('an event of the app\'s own calendar can be opened, edited and deleted from the day list', (tester) async {
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() async {
      await db!.delete('local_events');
      await db.delete('local_calendars');
      await db.delete('tasks');
    });
    final events = EventRepository(db!);
    final today = DateTime.now();
    final noon = DateTime(today.year, today.month, today.day, 12);
    late String id;
    await tester.runAsync(() async {
      await events.calendars();
      id = await events.createEvent(LocalEvent(
        id: '',
        calendarId: EventRepository.defaultCalendarId,
        title: 'Dentist',
        start: noon,
        end: noon.add(const Duration(hours: 1)),
        notes: 'bring the card',
      ));
    });

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
      }
    }

    await tester.pumpWidget(MaterialApp(home: CalendarView(repository: TaskRepository(db), local: events)));
    await settle();

    // (the day list shows it; "new event" is offered because there is a calendar to put one in)
    expect(find.byKey(const ValueKey('new-event')), findsOneWidget);
    await tester.tap(find.textContaining('Dentist').last);
    await settle();
    expect(find.byKey(const ValueKey('event-edit')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('event-edit')));
    await settle();
    expect(find.text('Edit event'), findsOneWidget);
    expect(find.text('bring the card'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('event-title')), 'Dentist (moved)');
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await settle();

    final changed = await tester.runAsync(() => events.event(id));
    expect(changed!.title, 'Dentist (moved)');
    expect(changed.notes, 'bring the card');
    expect(changed.start, noon);
    expect(find.textContaining('Dentist (moved)'), findsWidgets);

    await tester.tap(find.textContaining('Dentist (moved)').last);
    await settle();
    await tester.tap(find.byKey(const ValueKey('event-delete')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('event-delete-sure')));
    await settle();
    expect(await tester.runAsync(() => events.event(id)), isNull);
    expect(find.textContaining('Dentist'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

void weekTests() {
  testWidgets('in the week view a tap on an event opens it, with Edit', (tester) async {
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() async {
      await db!.delete('local_events');
      await db.delete('local_calendars');
      await db.delete('tasks');
    });
    final events = EventRepository(db!);
    final today = DateTime.now();
    final noon = DateTime(today.year, today.month, today.day, 12);
    await tester.runAsync(() async {
      await events.calendars();
      await events.createEvent(LocalEvent(
        id: '', calendarId: EventRepository.defaultCalendarId, title: 'Dentist', start: noon, end: noon.add(const Duration(hours: 1))));
    });
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
      }
    }

    await tester.pumpWidget(MaterialApp(home: CalendarView(repository: TaskRepository(db), local: events)));
    await settle();
    await tester.tap(find.text('Week'));
    await settle();
    final block = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('week-event-') && '${(w.key as ValueKey).value}'.endsWith('-Dentist'));
    await tester.ensureVisible(block);
    await tester.pump();
    await tester.tap(block);
    await settle();
    expect(find.byKey(const ValueKey('event-edit')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
