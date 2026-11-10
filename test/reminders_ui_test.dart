import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/reminder_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/reminders/reminder.dart';
import 'package:notes/reminders/reminder_service.dart';
import 'package:notes/screens/reminders_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'reminder_service_test.dart' show FakeSink;

void main() {
  setUpAll(AppDatabase.initFfi);

  test('the quick choices: this evening only while it is before six', () {
    final morning = reminderPresets(DateTime(2026, 3, 4, 10)); // a Wednesday
    expect(morning.map((p) => p.$1), ['In an hour', 'This evening', 'Tomorrow morning', 'Next week']);
    expect(morning[0].$2, DateTime(2026, 3, 4, 11));
    expect(morning[1].$2, DateTime(2026, 3, 4, 18));
    expect(morning[2].$2, DateTime(2026, 3, 5, 9));
    expect(morning[3].$2, DateTime(2026, 3, 9, 9)); // the next Monday
    final night = reminderPresets(DateTime(2026, 3, 4, 20));
    expect(night.map((p) => p.$1), ['In an hour', 'Tomorrow morning', 'Next week']);
    expect(reminderPresets(DateTime(2026, 3, 8, 20)).last.$2, DateTime(2026, 3, 9, 9)); // a Sunday: the next day
  });

  testWidgets('make a reminder from the screen, see it listed, delete it', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Database db;
    late ReminderRepository repo;
    late ReminderService service;
    final sink = FakeSink();
    await tester.runAsync(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = ReminderRepository(db);
      service = ReminderService(reminders: repo, tasks: TaskRepository(db), sink: sink, read: (_) async => null, write: (_, _) async {});
      await service.start();
    });
    addTearDown(() async {
      service.dispose();
      await tester.runAsync(db.close);
    });
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(home: RemindersScreen(service: service)));
    await settle();
    expect(find.textContaining('No reminders'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-reminder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('remind-title')), 'Call the dentist');
    await tester.tap(find.byKey(const ValueKey('remind-preset-Tomorrow morning')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remind-ok')));
    await settle();
    await settle(); // (the service looks at the change, then the screen at the service)

    final stored = (await tester.runAsync(() => repo.all()))!;
    expect(stored.single.title, 'Call the dentist');
    expect(stored.single.kind, ReminderKind.custom);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect(stored.single.at, DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9));
    expect(find.text('Call the dentist'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('delete-reminder-${stored.single.id}')));
    await settle();
    expect(await tester.runAsync(() => repo.all()), isEmpty);
    expect(find.textContaining('No reminders'), findsOneWidget);
  });

  testWidgets('without permission the screen says so, and Allow asks', (tester) async {
    late Database db;
    late ReminderService service;
    final sink = FakeSink(permission: true)..granted = false;
    await tester.runAsync(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      service = ReminderService(reminders: ReminderRepository(db), tasks: TaskRepository(db), sink: sink, read: (_) async => null, write: (_, _) async {});
      await service.start();
    });
    addTearDown(() async {
      service.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(MaterialApp(home: RemindersScreen(service: service)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reminders-denied')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('allow-notifications')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(sink.asked, 1);
    expect(find.byKey(const ValueKey('reminders-denied')), findsNothing);
  });

  testWidgets('a system without notifications says so', (tester) async {
    late Database db;
    late ReminderService service;
    await tester.runAsync(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      service = ReminderService(reminders: ReminderRepository(db), sink: FakeSink(works: false), read: (_) async => null, write: (_, _) async {});
      await service.start();
    });
    addTearDown(() async {
      service.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(MaterialApp(home: RemindersScreen(service: service)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reminders-unavailable')), findsOneWidget);
  });
}
