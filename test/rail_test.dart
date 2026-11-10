import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/main.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  Future<Widget> app(WidgetTester tester, NoteRepository Function() repoOf) async {
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      _db = db;
      await db.delete('settings', where: "key = 'rail_hidden'"); // (the in-memory database outlives a test)
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
    });
    return NotationApp(services: AppServices(
      repository: repoOf(),
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
    ));
  }

  testWidgets('the left bar can be hidden and brought back, and stays so', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    await tester.pumpWidget(await app(tester, () => repo = NoteRepository(_db!)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-show')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('rail-hide')));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const ValueKey('rail-show')), findsOneWidget);

    // remembered for the next start
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(await tester.runAsync(() => repo.settings.get('rail_hidden')), '1');

    await tester.tap(find.byKey(const ValueKey('rail-show')));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(await tester.runAsync(() => repo.settings.get('rail_hidden')), '0');
  });

  testWidgets('the bar slides in and out instead of jumping', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(await app(tester, () => NoteRepository(_db!)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    final full = tester.getSize(find.byType(NavigationRail)).width;

    await tester.tap(find.byKey(const ValueKey('rail-hide')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    // half way: still there, but not all of it is in view
    final rail = find.byType(NavigationRail);
    expect(rail, findsOneWidget);
    expect(tester.getTopRight(rail).dx, lessThan(full));
    expect(tester.getTopRight(rail).dx, greaterThan(0));
    await tester.pumpAndSettle();
    expect(rail, findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));

    await tester.tap(find.byKey(const ValueKey('rail-show')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(rail, findsOneWidget);
    expect(tester.getTopRight(rail).dx, lessThan(full));
    await tester.pumpAndSettle();
    expect(tester.getTopRight(rail).dx, full);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  });

  testWidgets('a hidden bar is still hidden at the next start', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    final widget = await app(tester, () => repo = NoteRepository(_db!));
    await tester.runAsync(() => repo.settings.set('rail_hidden', '1'));
    await tester.pumpWidget(widget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const ValueKey('rail-show')), findsOneWidget);
  });

  testWidgets('it can be hidden on a narrow screen too', (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(await app(tester, () => NoteRepository(_db!)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-hide')));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
  });
}

Database? _db;
