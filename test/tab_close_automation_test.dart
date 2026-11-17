import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/events/event_bus.dart';
import 'package:notes/events/event_sources.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/automations_view.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Editor implements NoteEditorHandle {
  final String title;
  String? exported;
  _Editor(this.title);
  @override
  Future<void> get ready async {}
  @override
  Future<void> saveNow() async {}
  @override
  String get noteTitle => title;
  List<String> lines = const [];
  @override
  Future<List<String>> pdfTextLines() async => lines;
  @override
  Future<String?> exportPdfTo(String path) async {
    exported = path;
    File(path).writeAsStringSync('%PDF');
    return null;
  }
}

class _InkEditor extends _Editor implements InkPreparer {
  _InkEditor(super.title);
  final asked = <(bool, bool)>[];
  @override
  Future<String> prepareInk({required bool text, required bool math}) async {
    asked.add((text, math));
    return 'reading ${asked.length}';
  }
}

void main() {
  testWidgets('closing the tab of a note exports it as a PDF', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository notes;
    late TaskRepository tasks;
    late AutomationService service;
    late SettingsRepository settings;
    late Directory dir;
    late String folder;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'automations'");
      dir = await Directory.systemTemp.createTemp('closing_');
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      settings = SettingsRepository(db);
      folder = await notes.createFolder('Geschichte');
      final pdf = File('${dir.path}/src.pdf')..writeAsBytesSync(File('test/fixtures/tex_sans_title.pdf').readAsBytesSync());
      await notes.createNote(title: 'Lecture 1', id: 'n1', folderId: folder);
      await db.update('notes', {'pdf_path': pdf.path, 'pdf_name': 'src.pdf', 'pdf_page_count': 1}, where: "id = 'n1'");
      service = AutomationService(notes, tasks);
      await service.load();
      await service.add(Automation(
          id: '1', event: AutomationEvent.noteClosed, action: AutomationAction.exportPdf, folderId: folder, params: {'dir': '${dir.path}/out'}));
    });
    addTearDown(() async {
      service.dispose();
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(MaterialApp(
      home: MainShellNavigation(services: AppServices(
        repository: notes,
        tasks: tasks,
        caldav: CalDavService(settings, tasks),
        device: DeviceCalendarService(settings),
        style: StyleService.inMemory(),
        appTheme: AppTheme.inMemory(),
        automations: service,
      )),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // open the note from the dashboard
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lecture 1').first);
    for (var i = 0; i < 60 && (find.byType(FixedPageNoteEditor).evaluate().isEmpty || find.byType(CircularProgressIndicator).evaluate().isNotEmpty); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(File('${dir.path}/out/Lecture 1.pdf').existsSync(), isFalse); // nothing until it is closed

    await tester.tap(find.byKey(const ValueKey('tab-page:0')));
    for (var i = 0; i < 80 && service.all.single.lastResult == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final pdf = File('${dir.path}/out/Lecture 1.pdf');
    expect(pdf.existsSync(), isTrue);
    expect(String.fromCharCodes(pdf.readAsBytesSync().sublist(0, 4)), '%PDF');
    // the automation notes what it did in the database (real work) before the screen moves on
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(service.all.single.lastResult, startsWith('Exported to'));
  });
}
