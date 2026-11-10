import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:notes/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('app starts on the dashboard and offers every section', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository notes;
    late TaskRepository tasks;
    late CalDavService caldav;
    late DeviceCalendarService device;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      caldav = CalDavService(SettingsRepository(db), tasks);
      device = DeviceCalendarService.forPlatform(SettingsRepository(db));
    });

    await tester.pumpWidget(NotationApp(services: AppServices(
      repository: notes,
      tasks: tasks,
      caldav: caldav,
      device: device,
      style: StyleService.inMemory(),
      appTheme: AppTheme.inMemory(),
    )));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsWidgets);
    for (final section in ['Folders', 'Calendar', 'Active Canvas', 'Settings']) {
      expect(find.text(section), findsOneWidget);
    }
    expect(find.text('New Note'), findsOneWidget);
  });
}
