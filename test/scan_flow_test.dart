import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('opening a note with a PDF makes tasks from its dates, says so, and does not repeat',
      skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final year = DateTime.now().year + 1;

    late NoteRepository notes;
    late TaskRepository tasks;
    late SettingsRepository settings;
    late AutomationService service;
    late Directory dir;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key LIKE 'automations%'");
      await db.delete('tasks');
      dir = await Directory.systemTemp.createTemp('flow_');
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Text('Final exam on 15 June $year at 14:30, room B12')));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      settings = SettingsRepository(db);
      final id = await notes.createNote(title: 'Syllabus');
      final note = (await notes.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 1;
      await notes.saveNote(note);
      service = AutomationService(notes, tasks);
      await service.load();
      await service.add(const Automation(
          id: 'd', event: AutomationEvent.dateFound, action: AutomationAction.addTask, params: {'title': '{time} {summary}'}));
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
    Future<void> wait(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await wait(() => find.text('Syllabus').evaluate().isNotEmpty);
    await tester.tap(find.text('Syllabus').first);
    await wait(() => service.all.single.lastResult != null);
    await tester.pump();
    expect((await tester.runAsync(tasks.listTasks))!.map((t) => t.title), ['14:30 Final exam, room B12']);
    expect(find.textContaining('Added the task'), findsOneWidget); // told on screen

    // away and back: nothing new, and the automation says why
    await tester.tap(find.text('Dashboard'));
    await wait(() => find.byType(FixedPageNoteEditor).evaluate().isEmpty && find.text('Syllabus').evaluate().isNotEmpty);
    await tester.tap(find.text('Syllabus').first);
    await wait(() => (service.all.single.lastResult ?? '').contains('handled before'));
    expect(service.all.single.lastResult, contains('1 date found'));
    expect((await tester.runAsync(tasks.listTasks))!.length, 1);
  });
}
