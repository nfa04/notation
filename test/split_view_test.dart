import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/main.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('two notes can be open side by side, and the second can be closed again', (tester) async {
    tester.view.physicalSize = const Size(1900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    late String a, b;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'rail_hidden'");
      repo = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
      a = await repo.createNote(title: 'Alpha split');
      b = await repo.createNote(title: 'Beta split');
    });
    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: repo,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alpha split').first);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(find.byKey(ValueKey('close-split-$a')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('open-beside')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('pick-note-$a')), findsNothing); // (not the one that is open)
    await tester.enterText(find.byKey(const ValueKey('note-picker-search')), 'beta');
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('pick-note-$b')));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(FixedPageNoteEditor), findsNWidgets(2));
    expect(find.byKey(const ValueKey('split-divider')), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Beta split'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Alpha split'), findsOneWidget);

    // either of the two can be closed
    expect(find.byKey(ValueKey('close-split-$a')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('close-split-$a')));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(FixedPageNoteEditor), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Beta split'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Alpha split'), findsNothing);
    expect(find.byKey(const ValueKey('split-divider')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });
}
