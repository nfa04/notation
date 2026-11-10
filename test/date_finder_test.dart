import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/automations/date_finder.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Editor implements NoteEditorHandle {
  final List<String> lines;
  _Editor(this.lines);
  @override
  Future<void> get ready async {}
  @override
  Future<void> saveNow() async {}
  @override
  String get noteTitle => 'Course';
  @override
  Future<List<String>> pdfTextLines() async => lines;
  @override
  Future<String?> exportPdfTo(String path) async => null;
}

class _Broken extends _Editor {
  _Broken() : super(const []);
  @override
  Future<List<String>> pdfTextLines() async => throw StateError('no text layer');
}

void main() {
  setUpAll(AppDatabase.initFfi);

  final today = DateTime(2026, 3, 1);
  List<String> days(List<String> lines) => [for (final f in findDates(lines, today)) '${f.day} ${f.time}'.trim()];

  group('finding dates', () {
    test('the usual ways of writing one', () {
      expect(days(['2026-03-07']), ['2026-03-07']);
      expect(days(['Due 7.3.2026']), ['2026-03-07']);
      expect(days(['Due 07/03/2026']), ['2026-03-07']); // day first
      expect(days(['7.3.26']), ['2026-03-07']);
      expect(days(['7 March 2026']), ['2026-03-07']);
      expect(days(['March 7, 2026']), ['2026-03-07']);
      expect(days(['March 7th, 2026']), ['2026-03-07']);
      expect(days(['7. März 2026']), ['2026-03-07']);
      expect(days(['7 mars 2026']), ['2026-03-07']);
      expect(days(['1st of April 2026']), ['2026-04-01']);
    });

    test('the other way round when the first number cannot be a month', () {
      expect(days(['3/25/2026']), ['2026-03-25']);
    });

    test('times, after the date or before it', () {
      expect(days(['Exam 7.3.2026 at 14:30']), ['2026-03-07 14:30']);
      expect(days(['Exam 7.3.2026, 14.30 Uhr']), ['2026-03-07 14:30']);
      expect(days(['7 March 2026 2 pm']), ['2026-03-07 14:00']);
      expect(days(['7 March 2026 12 am']), ['2026-03-07 00:00']);
      expect(days(['7.3.2026 um 9 Uhr']), ['2026-03-07 09:00']);
      expect(days(['14:00, on 7 March 2026']), ['2026-03-07 14:00']);
      expect(days(['7.3.2026 10:00-12:00']), ['2026-03-07 10:00']);
      expect(days(['7.3.2026']), ['2026-03-07']); // no time, none made up
    });

    test('two dates in a line are not read as a time', () {
      expect(days(['from 7.3.2026 to 10.12.2026']), ['2026-03-07', '2026-12-10']);
    });

    test('what is not taken', () {
      expect(days(['7 March']), isEmpty); // no year
      expect(days(['7.3.']), isEmpty);
      expect(days(['31.2.2026']), isEmpty); // not a day
      expect(days(['Version 1.2.3']), isEmpty);
      expect(days(['5.5.1999']), isEmpty); // past
      expect(days(['1.1.2099']), isEmpty); // too far
      expect(days(['1.2.34']), isEmpty);
      expect(days(['page 12.03']), isEmpty);
    });

    test('today counts, yesterday does not', () {
      expect(days(['1.3.2026']), ['2026-03-01']);
      expect(days(['28.2.2026']), isEmpty);
    });

    test('the line is kept for the task, and the same date twice counts once', () {
      final f = findDates(['  Midterm   exam on 7.3.2026  ', 'Midterm exam on 7.3.2026'], today);
      expect(f.length, 1);
      expect(f.single.line, 'Midterm exam on 7.3.2026');
      expect(findDates(['A 7.3.2026', 'B 7.3.2026'], today).length, 2); // different lines, different tasks
    });

    test('the key is the same every time', () {
      expect(findDates(['Exam 7.3.2026 9:00'], today).single.key, findDates(['Exam 7.3.2026 9:00'], today).single.key);
    });
  });

  group('the summary', () {
    String summary(String line) => findDates([line], today).single.summary;

    test('date, time and the little words before them are gone', () {
      expect(summary('Midterm 7.3.2026 at 14:30'), 'Midterm');
      expect(summary('Midterm exam on 7.3.2026, room B12'), 'Midterm exam, room B12');
      expect(summary('Midterm exam on 7.3.2026 at 14:30, room B12'), 'Midterm exam, room B12');
      expect(summary('Final exam: 20 June 2026'), 'Final exam');
      expect(summary('Abgabe am 7. März 2026 um 9 Uhr'), 'Abgabe');
      expect(summary('14:00, on 7 March 2026 - Seminar'), 'Seminar');
      expect(summary('Project due (7.3.2026)'), 'Project due');
      expect(summary('Lab report [2026-03-07 10:00]'), 'Lab report');
    });

    test('the first letter is a capital, a long line is cut at a word', () {
      expect(summary('hand in the essay by 7.3.2026'), 'Hand in the essay');
      final long = findDates(['${'word ' * 30}7.3.2026'], today).single.summary;
      expect(long.length, lessThanOrEqualTo(71));
      expect(long, endsWith('…'));
    });

    test('a line that was only a date has no summary', () {
      expect(summary('7.3.2026'), '');
      expect(summary('Am 7.3.2026 um 14:00'), '');
    });

    test('other dates in the line are left in', () {
      final all = findDates(['Semester 1.4.2026 until 30.6.2026'], today);
      expect(all.map((f) => f.summary), ['Semester until 30.6.2026', 'Semester 1.4.2026']);
    });
  });

  test('templates take the found date', () {
    final f = findDates(['Exam 7.3.2026 at 14:30'], today).single;
    expect(fillTemplate('{time} {line} ({found}) {title}', title: 'Course', now: today, found: f),
        '14:30 Exam 7.3.2026 at 14:30 (2026-03-07) Course');
    expect(fillTemplate('{time} {line}', title: '', now: today, found: findDates(['Exam 7.3.2026'], today).single), ' Exam 7.3.2026'.trim() == 'Exam 7.3.2026' ? ' Exam 7.3.2026' : ' Exam 7.3.2026');
  });

  group('the automation', () {
    late NoteRepository notes;
    late TaskRepository tasks;
    late AutomationService service;

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key LIKE 'automations%'");
      await db.delete('tasks');
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      service = AutomationService(notes, tasks, now: () => today);
      await service.load();
      await service.add(const Automation(
        id: 'd',
        event: AutomationEvent.dateFound,
        action: AutomationAction.addTask,
        params: {'title': '{time} {line}'},
      ));
    });
    tearDown(() => service.dispose());

    test('the summary leaves the date out of the title, or falls back to the note', () async {
      await service.update(service.all.single.copyWith(params: {'title': '{time} {summary}'}));
      await service.scanForDates(_Editor(['Midterm exam on 7.3.2026 at 14:30, room B12', 'On 8.3.2026']), noteId: 'n');
      expect((await tasks.listTasks()).map((t) => t.title), ['14:30 Midterm exam, room B12', 'Course']);
    });

    test('each date becomes a task on its day, with the time in the text', () async {
      await service.scanForDates(_Editor(['Lecture notes', 'Midterm 7.3.2026 at 14:30', 'Final exam: 20 June 2026']), noteId: 'n');
      final all = await tasks.listTasks();
      expect(all.map((t) => t.title), ['14:30 Midterm 7.3.2026 at 14:30', 'Final exam: 20 June 2026']);
      expect(all.map((t) => t.dueDate), [DateTime(2026, 3, 7), DateTime(2026, 6, 20)]);
    });

    test('opening the note again adds nothing new, even after a restart', () async {
      final editor = _Editor(['Midterm 7.3.2026 at 14:30']);
      await service.scanForDates(editor, noteId: 'n');
      await service.scanForDates(editor, noteId: 'n');
      expect((await tasks.listTasks()).length, 1);

      final again = AutomationService(notes, tasks, now: () => today);
      await again.load();
      await again.scanForDates(editor, noteId: 'n');
      again.dispose();
      expect((await tasks.listTasks()).length, 1);

      // another note with the same line is another task; so is a date that is new
      await service.scanForDates(editor, noteId: 'other');
      await service.scanForDates(_Editor(['Midterm 7.3.2026 at 14:30', 'Retake 9.3.2026']), noteId: 'n');
      expect((await tasks.listTasks()).length, 3);
    });

    test('the report says how many dates and what was done', () async {
      final report = await service.scanForDates(_Editor(['Midterm 7.3.2026', 'Final 20 June 2026']), noteId: 'n');
      expect((report.found, report.acted, report.error), (2, 2, null));
      final again = await service.scanForDates(_Editor(['Midterm 7.3.2026', 'Final 20 June 2026']), noteId: 'n');
      expect((again.found, again.acted), (2, 0)); // all handled before
      expect(service.all.single.lastResult, contains('all handled before'));
      expect(service.all.single.lastResult, contains('2 dates'));
      final none = await service.scanForDates(_Editor(['Nothing here']), noteId: 'n');
      expect(none.found, 0);
      expect(service.all.single.lastResult, startsWith('No dates found'));
    });

    test('forgetting makes the dates new again', () async {
      final editor = _Editor(['Midterm 7.3.2026']);
      await service.scanForDates(editor, noteId: 'n');
      await service.scanForDates(editor, noteId: 'n');
      expect((await tasks.listTasks()).length, 1);
      await service.forgetHandled('d');
      await service.scanForDates(editor, noteId: 'n');
      expect((await tasks.listTasks()).length, 2);
    });

    test('a failure is reported, not thrown', () async {
      final report = await service.scanForDates(_Broken(), noteId: 'n');
      expect(report.error, contains('no text'));
    });

    test('nothing is read when no automation wants dates', () async {
      await service.update(service.all.single.copyWith(enabled: false));
      final report = await service.scanForDates(_Editor(['Midterm 7.3.2026']), noteId: 'n');
      expect(report.found, 0); // not even read
      expect(await tasks.listTasks(), isEmpty);
    });

    test('it can be limited to a folder', () async {
      await service.update(service.all.single.copyWith(folderId: 'f1'));
      await service.scanForDates(_Editor(['Midterm 7.3.2026']), noteId: 'n', folderId: 'f2');
      expect(await tasks.listTasks(), isEmpty);
      await service.scanForDates(_Editor(['Midterm 7.3.2026']), noteId: 'n', folderId: 'f1');
      expect((await tasks.listTasks()).length, 1);
    });

    test('the date and what it has to do with exporting', () {
      expect(AutomationAction.exportPdf.worksAfter(AutomationEvent.dateFound), isFalse);
      expect(AutomationAction.addTask.worksAfter(AutomationEvent.dateFound), isTrue);
      expect(AutomationAction.moveToFolder.worksAfter(AutomationEvent.dateFound), isTrue);
    });
  });

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');
  testWidgets('the text of a real PDF note is read for dates', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final year = DateTime.now().year + 1;

    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('dates_');
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Column(children: [
            pw.Text('Syllabus'),
            pw.Text('Final exam on 15 June $year at 14:30'),
          ])));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 1;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: key, noteId: id, repository: repo)));
    for (var i = 0; i < 60 && (find.byType(Image).evaluate().isEmpty); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    final handle = key.currentState! as NoteEditorHandle;
    final lines = (await tester.runAsync(handle.pdfTextLines))!;
    final found = findDates(lines, DateTime.now());
    expect(found.length, 1);
    expect(found.single.day, '$year-06-15');
    expect(found.single.time, '14:30');
    expect(found.single.line, contains('Final exam'));
  });
}
