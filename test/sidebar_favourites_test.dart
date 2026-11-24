import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('the bar lists starred notes as far as there is room, and a button shows them all', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository notes;
    late TaskRepository tasks;
    late SettingsRepository settings;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      settings = SettingsRepository(db);
      for (var i = 1; i <= 7; i++) {
        await notes.createNote(title: 'Fav $i', id: 'n$i');
        await notes.setFavorite('n$i', true);
      }
      await notes.createNote(title: 'Plain', id: 'p1');
    });
    await tester.pumpWidget(MaterialApp(
      home: MainShellNavigation(services: AppServices(repository: notes, tasks: tasks, caldav: CalDavService(settings, tasks), device: DeviceCalendarService(settings), style: StyleService.inMemory(), appTheme: AppTheme.inMemory())),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('side-favourites')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('side-fav-')), findsNWidgets(5));
    await tester.tap(find.byKey(const ValueKey('side-favourites')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Fav 7'), findsWidgets);
    expect(find.text('Plain'), findsNothing);
  });
}
