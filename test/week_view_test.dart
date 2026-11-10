import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/calendar_view.dart';
import 'package:notes/screens/week_view.dart';
import 'package:notes/style/calendar_style.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_remote.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  final monday = DateTime(2026, 11, 2);
  final events = [
    DayEvent(title: 'Lecture', start: DateTime(2026, 11, 3, 9), end: DateTime(2026, 11, 3, 11), allDay: false, calendarName: 'Uni', color: '#336699'),
    DayEvent(title: 'Seminar', start: DateTime(2026, 11, 3, 10), end: DateTime(2026, 11, 3, 12), allDay: false, calendarName: 'Uni'),
    DayEvent(title: 'Trip', start: DateTime(2026, 11, 5), allDay: true, calendarName: 'Private'),
  ];
  const tasks = [Task(id: 't', title: 'Hand in essay', dueDate: null)];

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: SizedBox(width: 900, height: 600, child: child)));

  testWidgets('shows events, all-day items and tasks of the week', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final toggled = <(String, bool)>[];
    DateTime? selected;
    await tester.pumpWidget(host(WeekView(
      weekStart: monday,
      selected: monday,
      today: DateTime(2026, 11, 4),
      events: events,
      tasks: [const Task(id: 't', title: 'Hand in essay', dueDate: null), Task(id: 'd', title: 'Essay due', dueDate: DateTime(2026, 11, 4))],
      onSelectDay: (d) => selected = d,
      onToggleTask: (t, done) => toggled.add((t.id, done)),
      onEditTask: (_) {},
      style: StyleService.inMemory(),
      onStyleEvent: (_) {},
      onStyleTask: (_) {},
      onStyleDay: (_) {},
    )));

    for (final day in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) {
      expect(find.text(day), findsOneWidget);
    }
    expect(find.text('Lecture'), findsOneWidget);
    expect(find.text('Seminar'), findsOneWidget); // overlapping, side by side
    expect(tester.getTopLeft(find.text('Lecture')).dx, lessThan(tester.getTopLeft(find.text('Seminar')).dx));
    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('Essay due'), findsOneWidget);
    expect(find.text('Hand in essay'), findsNothing); // undated tasks are not on a day

    await tester.tap(find.byType(Checkbox));
    expect(toggled, [('d', true)]);

    await tester.tap(find.text('Thu'));
    expect(selected, DateTime(2026, 11, 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow week view does not overflow', (tester) async {
    tester.view.physicalSize = const Size(500, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WeekView(
          weekStart: monday,
          selected: monday,
          today: monday,
          events: events,
          tasks: tasks,
          onSelectDay: (_) {},
          onToggleTask: (_, _) {},
          onEditTask: (_) {},
          style: StyleService.inMemory(),
          onStyleEvent: (_) {},
          onStyleTask: (_) {},
          onStyleDay: (_) {},
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  test('calendar colours', () {
    expect(parseCalendarColor('#336699'), const Color(0xFF336699));
    expect(parseCalendarColor('336699'), const Color(0xFF336699));
    expect(parseCalendarColor('#33669980'), const Color(0xFF336699)); // alpha dropped
    expect(parseCalendarColor('nonsense'), isNull);
    expect(parseCalendarColor(null), isNull);
  });

  testWidgets('switching the calendar to week view and back', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late TaskRepository repo;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('tasks');
      repo = TaskRepository(db);
      await repo.createTask('Read chapter', dueDate: dayOf(DateTime.now()));
    });
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(home: CalendarView(repository: repo)));
    await settle();
    expect(find.byType(WeekView), findsNothing);

    await tester.tap(find.text('Week'));
    await settle();
    expect(find.byType(WeekView), findsOneWidget);
    // the task shows in the grid and in the side panel
    expect(find.text('Read chapter'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Next week'));
    await settle();
    expect(find.text('Read chapter'), findsNothing); // due this week, not next
    await tester.tap(find.text('Month'));
    await settle();
    expect(find.byType(WeekView), findsNothing);
  });
}
