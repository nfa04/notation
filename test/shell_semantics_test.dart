import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('opening a note with semantics on does not break the tab screens', (tester) async {
    final handle = tester.ensureSemantics();
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
      await notes.createNote(title: 'Lecture 1', id: 'n1');
    });
    await tester.pumpWidget(MaterialApp(
      home: MainShellNavigation(services: AppServices(repository: notes, tasks: tasks, caldav: CalDavService(settings, tasks), device: DeviceCalendarService(settings), style: StyleService.inMemory(), appTheme: AppTheme.inMemory())),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lecture 1').first);
    for (var i = 0; i < 60 && find.byType(FixedPageNoteEditor).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    handle.dispose();
  });
}
