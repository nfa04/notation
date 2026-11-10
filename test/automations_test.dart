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
  setUpAll(AppDatabase.initFfi);

  group('the rules', () {
    test('they survive being saved; an unknown action is dropped, an unknown event is kept', () {
      final a = Automation(
        id: '1',
        event: AutomationEvent.noteClosed,
        action: AutomationAction.exportPdf,
        folderId: 'f',
        params: {'dir': '/x'},
        lastRun: DateTime.fromMillisecondsSinceEpoch(5000),
        lastResult: 'ok',
      );
      final back = Automation.decodeAll(Automation.encodeAll([a])).single;
      expect((back.event, back.action, back.folderId, back.lastRun, back.lastResult), (a.event, a.action, 'f', a.lastRun, 'ok'));
      expect(back.params, {'dir': '/x'});
      expect(Automation.decodeAll('[{"id":"2","event":"noteClosed","action":"levitate"}]'), isEmpty);
      final kept = Automation.decodeAll('[{"id":"2","event":"ext:x/moonrise","action":"addTask"}]').single;
      expect(kept.event.id, 'ext:x/moonrise');
      expect(Automation.decodeAll(Automation.encodeAll([kept])).single.event, kept.event);
      expect(Automation.decodeAll('not json'), isEmpty);
      expect(Automation.decodeAll(null), isEmpty);
    });

    test('what follows what', () {
      expect(AutomationAction.exportPdf.worksAfter(AutomationEvent.noteClosed), isTrue);
      expect(AutomationAction.exportPdf.worksAfter(AutomationEvent.noteCreated), isFalse); // not open in the editor
      expect(AutomationAction.moveToFolder.worksAfter(AutomationEvent.appStarted), isFalse); // no note
      expect(AutomationAction.addTask.worksAfter(AutomationEvent.appStarted), isTrue);
      // reading the writing ahead of time is for the note that is open, while it is open
      expect(AutomationAction.prepareInk.worksAfter(AutomationEvent.noteOpened), isTrue);
      expect(AutomationAction.prepareInk.worksAfter(AutomationEvent.noteClosed), isFalse);
      expect(AutomationAction.prepareInk.worksAfter(AutomationEvent.appStarted), isFalse);
      expect(Automation.decodeAll(Automation.encodeAll([const Automation(id: 'i', event: AutomationEvent.noteOpened, action: AutomationAction.prepareInk, params: {'what': 'formulas'})])).single.params, {'what': 'formulas'});
    });

    test('templates and file names', () {
      final now = DateTime(2026, 3, 7);
      expect(fillTemplate('Review {title} on {date}', title: 'Physics', now: now), 'Review Physics on 2026-03-07');
      expect(safeFileName('a/b:c?'), 'a_b_c_');
      expect(safeFileName('  '), 'Note');
      expect(safeFileName('..hidden'), 'hidden');
    });
  });

  group('running them', () {
    late NoteRepository notes;
    late TaskRepository tasks;
    late AutomationService service;
    final now = DateTime(2026, 3, 7, 12);

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'automations'");
      await db.delete('tasks');
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      service = AutomationService(notes, tasks, now: () => now);
      await service.load();
    });

    tearDown(() => service.dispose());

    test('reading the writing ahead of time starts every time the note is opened (also when it was not changed), and says what it reads', () async {
      await service.add(const Automation(id: 'ink', event: AutomationEvent.noteOpened, action: AutomationAction.prepareInk, params: {'what': 'text'}));
      await service.add(const Automation(id: 'ink2', event: AutomationEvent.noteOpened, action: AutomationAction.prepareInk));
      final editor = _InkEditor('Physics');
      final first = await service.run(AutomationEvent.noteOpened, noteId: 'n', title: 'Physics', editor: editor);
      expect(first, ['reading 1', 'reading 2']);
      expect(editor.asked, [(true, false), (true, true)], reason: 'text only; and both when nothing is said');
      editor.asked.clear();
      // the same note again, not changed: an automation like converting would be skipped, this one is not
      final second = await service.run(AutomationEvent.noteOpened, noteId: 'n', title: 'Physics', editor: editor);
      expect(second, hasLength(2));
      expect(editor.asked, hasLength(2));

      await service.add(const Automation(id: 'ink3', event: AutomationEvent.noteOpened, action: AutomationAction.prepareInk, params: {'what': 'formulas'}));
      editor.asked.clear();
      await service.run(AutomationEvent.noteOpened, noteId: 'n', title: 'Physics', editor: editor);
      expect(editor.asked.last, (false, true));
      expect(service.all.firstWhere((a) => a.id == 'ink3').lastResult, startsWith('reading'));
    });

    test('with an editor that cannot read ahead (or none) the automation says so and nothing breaks', () async {
      await service.add(const Automation(id: 'ink', event: AutomationEvent.noteOpened, action: AutomationAction.prepareInk));
      expect((await service.run(AutomationEvent.noteOpened, noteId: 'n', title: 'x', editor: _Editor('x'))).single, 'The note was not open');
      expect((await service.run(AutomationEvent.noteOpened, noteId: 'n', title: 'x')).single, 'The note was not open');
    });

    test('a task is added when a note is closed, with the title filled in', () async {
      await service.add(const Automation(
        id: '1',
        event: AutomationEvent.noteClosed,
        action: AutomationAction.addTask,
        params: {'title': 'Review {title}', 'due': 'tomorrow'},
      ));
      final out = await service.run(AutomationEvent.noteClosed, noteId: 'n', title: 'Physics');
      expect(out.single, contains('Review Physics'));
      final all = await tasks.listTasks();
      expect(all.single.title, 'Review Physics');
      expect(all.single.dueDate, DateTime(2026, 3, 8));
      expect(service.all.single.lastResult, contains('Review Physics'));
      expect(service.all.single.lastRun, now);
    });

    test('only the matching event, folder and enabled ones run', () async {
      await service.add(const Automation(id: 'a', event: AutomationEvent.noteOpened, action: AutomationAction.addTask, params: {'title': 'opened'}));
      await service.add(const Automation(id: 'b', event: AutomationEvent.noteClosed, action: AutomationAction.addTask, folderId: 'f1', params: {'title': 'in f1'}));
      await service.add(const Automation(id: 'c', event: AutomationEvent.noteClosed, action: AutomationAction.addTask, enabled: false, params: {'title': 'off'}));
      await service.add(const Automation(id: 'd', event: AutomationEvent.noteClosed, action: AutomationAction.addTask, params: {'title': 'any'}));

      await service.run(AutomationEvent.noteClosed, noteId: 'n', title: 'T', folderId: 'f2');
      expect([for (final t in await tasks.listTasks()) t.title], ['any']);
      await service.run(AutomationEvent.noteClosed, noteId: 'n', title: 'T', folderId: 'f1');
      expect([for (final t in await tasks.listTasks()) t.title]..sort(), ['any', 'any', 'in f1']);
    });

    test('a note is moved into a folder', () async {
      final folder = await notes.createFolder('Done');
      final id = await notes.createNote(title: 'N');
      await service.add(Automation(id: '1', event: AutomationEvent.noteClosed, action: AutomationAction.moveToFolder, params: {'folder': folder}));
      await service.run(AutomationEvent.noteClosed, noteId: id, title: 'N');
      expect((await notes.noteInfo(id))!.folderId, folder);
    });

    test('the PDF goes to the folder, named after the note', () async {
      final dir = await Directory.systemTemp.createTemp('auto_');
      addTearDown(() => dir.delete(recursive: true));
      await service.add(Automation(id: '1', event: AutomationEvent.noteClosed, action: AutomationAction.exportPdf, params: {'dir': '${dir.path}/sub'}));
      final editor = _Editor('My/Note');
      final out = await service.run(AutomationEvent.noteClosed, noteId: 'n', title: 'My/Note', editor: editor);
      expect(editor.exported, '${dir.path}/sub/My_Note.pdf');
      expect(File('${dir.path}/sub/My_Note.pdf').existsSync(), isTrue);
      expect(out.single, startsWith('Exported to'));
    });

    test('what cannot be done is said, not thrown', () async {
      await service.add(const Automation(id: '1', event: AutomationEvent.noteClosed, action: AutomationAction.exportPdf, params: {'dir': '/tmp/x'}));
      expect((await service.run(AutomationEvent.noteClosed, noteId: 'n', title: 'T')).single, 'The note was not open');
      await service.add(const Automation(id: '2', event: AutomationEvent.noteClosed, action: AutomationAction.addTask, params: {'title': ' '}));
      expect(await service.run(AutomationEvent.noteClosed, title: 'T'), contains('The task has no text'));
    });

    test('a new note starts the ones for creating a note', () async {
      final source = NoteEventSource(notes, service.bus)..start();
      addTearDown(source.dispose);
      await service.add(const Automation(id: '1', event: AutomationEvent.noteCreated, action: AutomationAction.addTask, params: {'title': 'Fill in {title}'}));
      await notes.createNote(title: 'Fresh');
      for (var i = 0; i < 40 && (await tasks.listTasks()).isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect((await tasks.listTasks()).single.title, 'Fill in Fresh');
    });

    test('an event announced by something else starts its rules, and is offered for new ones', () async {
      service.bus.register(const EventType('ext:x/ping', 'Ping'));
      expect(service.events.map((e) => e.id), contains('ext:x/ping'));
      expect(service.events.map((e) => e.id), isNot(contains('tick')));
      await service.add(Automation(id: '1', event: AutomationEvent.unknown('ext:x/ping'), action: AutomationAction.addTask, params: const {'title': 'Pinged'}));
      await service.bus.emit(const AppEvent('ext:x/ping'));
      expect((await tasks.listTasks()).single.title, 'Pinged');
    });

    test('they are kept for the next start', () async {
      await service.add(const Automation(id: '1', event: AutomationEvent.appStarted, action: AutomationAction.addTask, params: {'title': 'x'}));
      final again = AutomationService(notes, tasks);
      await again.load();
      expect(again.all.single.id, '1');
      again.dispose();
    });
  });

  testWidgets('automations are in the left bar and can be made, switched off and deleted', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository notes;
    late TaskRepository tasks;
    late AutomationService service;
    late SettingsRepository settings;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'automations'");
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      settings = SettingsRepository(db);
      service = AutomationService(notes, tasks);
      await service.load();
    });
    addTearDown(service.dispose);
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

    await tester.tap(find.text('Automations'));
    await tester.pumpAndSettle();
    expect(find.byType(AutomationsView), findsOneWidget);
    expect(find.textContaining('Nothing automated yet'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-automation')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    // the PDF export needs a folder: Save waits for it
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('automation-save'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('automation-dir')), '/tmp/pdfs');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(service.all.single.event, AutomationEvent.noteClosed);
    expect(service.all.single.action, AutomationAction.exportPdf);
    expect(service.all.single.params['dir'], '/tmp/pdfs');
    expect(find.textContaining('Into /tmp/pdfs'), findsOneWidget);

    final id = service.all.single.id;
    await tester.tap(find.byKey(ValueKey('automation-switch-$id')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(service.all.single.enabled, isFalse);

    await tester.tap(find.byKey(ValueKey('automation-delete-$id')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(service.all, isEmpty);
  });

  testWidgets('closing a note exports it as a PDF', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository notes;
    late TaskRepository tasks;
    late AutomationService service;
    late SettingsRepository settings;
    late Directory dir;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key = 'automations'");
      dir = await Directory.systemTemp.createTemp('closing_');
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      settings = SettingsRepository(db);
      await notes.createNote(title: 'Lecture 1');
      service = AutomationService(notes, tasks);
      await service.load();
      await service.add(Automation(
          id: '1', event: AutomationEvent.noteClosed, action: AutomationAction.exportPdf, params: {'dir': dir.path}));
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
    expect(File('${dir.path}/Lecture 1.pdf').existsSync(), isFalse); // nothing until it is closed

    await tester.tap(find.text('Calendar'));
    for (var i = 0; i < 80 && service.all.single.lastResult == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final pdf = File('${dir.path}/Lecture 1.pdf');
    expect(pdf.existsSync(), isTrue);
    expect(String.fromCharCodes(pdf.readAsBytesSync().sublist(0, 4)), '%PDF');
    // the automation notes what it did in the database (real work) before the screen moves on
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(service.all.single.lastResult, startsWith('Exported to'));
  });
}
