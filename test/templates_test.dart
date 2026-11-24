import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/screens/dashboard_view.dart';
import 'package:notes/markdown/table_formulas.dart';
import 'package:notes/templates/template_documents.dart';
import 'package:notes/templates/templates.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late TemplateService service;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('templates');
    repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    service = TemplateService(repo, NoteFileService(repo, supportDirectory: () async => dir), now: () => DateTime(2026, 3, 9));
  });
  tearDown(() => dir.delete(recursive: true));

  test('a note from a page that comes with the app has its look and its words', () async {
    final lecture = service.builtIn.firstWhere((t) => t.id == 'lecture');
    final id = await service.createFrom(lecture);
    final note = (await repo.loadNote(id))!;
    expect(note.title, lecture.name);
    expect(note.background, PageBackground.lines);
    expect(note.documentText, contains('2026-03-09'));

    final cornell = await service.createFrom(service.builtIn.firstWhere((t) => t.id == 'cornell'));
    expect((await repo.loadNote(cornell))!.textBoxes[0], hasLength(3));

    final grid = await service.createFrom(service.builtIn.firstWhere((t) => t.id == 'grid'), folderId: null);
    expect((await repo.loadNote(grid))!.background, PageBackground.grid);
  });

  test('the infinite canvas is a page to start from, and a note file keeps it', () async {
    final id = await service.createFrom(service.builtIn.firstWhere((t) => t.id == 'canvas'));
    expect((await repo.loadNote(id))!.pageFormat, PageFormat.infinite);

    expect(await service.saveAsTemplate(id, 'Board'), isTrue);
    final saved = (await service.saved()).single;
    final copy = await service.createFromSaved(saved.id);
    expect((await repo.loadNote(copy!))!.pageFormat, PageFormat.infinite);
    await service.remove(saved.id); // (the database is shared by the tests)
  });

  test('a note kept as a template makes new notes like it, and can be removed', () async {
    final id = await repo.createNote(title: 'My layout');
    final n = (await repo.loadNote(id))!;
    n.background = PageBackground.grid;
    n.documentText = 'Name: ';
    n.textBoxes = {
      0: [TextBoxWidgetModel(id: 'a', position: const Offset(10, 10), initialText: 'Hello')],
    };
    await repo.saveNote(n);

    expect(await service.saveAsTemplate(id, 'Weekly'), isTrue);
    final saved = await service.saved();
    expect(saved.map((t) => t.name), ['Weekly']);

    final copy = await service.createFromSaved(saved.single.id);
    expect(copy, isNotNull);
    expect(copy, isNot(id));
    final c = (await repo.loadNote(copy!))!;
    expect(c.background, PageBackground.grid);
    expect(c.documentText, 'Name: ');
    expect(c.textBoxes[0]!.single.controller.text, 'Hello');

    await service.remove(saved.single.id);
    expect(await service.saved(), isEmpty);
    expect(await service.createFromSaved(saved.single.id), isNull);
  });

  test('every template makes a note, with no ids repeated and nothing left unfilled', () async {
    final all = service.builtIn;
    expect(all.map((t) => t.id).toSet(), hasLength(all.length));
    for (final t in all) {
      final note = (await repo.loadNote(await service.createFrom(t)))!;
      expect(note.documentText, isNot(contains('null')), reason: t.id);
      if (t.id == 'weekly') expect(note.documentText, contains('Week 11'));
    }
    expect(all.where((t) => t.group != TemplateGroup.paper), hasLength(greaterThan(15)));
    expect(all.map((t) => t.group).toSet(), TemplateGroup.values.toSet());
  });

  test('the sums in the budget, habit, exam and lab templates work themselves out', () {
    List<List<String>> rows(String text) => [
          for (final l in text.split('\n'))
            if (l.startsWith('|') && !l.contains('---')) [for (final c in l.substring(1, l.length - 1).split('|')) c.trim()]
        ];
    final budget = rows(budgetText(DateTime(2026, 3, 9)));
    expect(budget.where((r) => r.any(isFormula)), isNotEmpty);
    final habits = worked([...rows(habitsText(DateTime(2026, 3, 9))).take(2).map((r) => [...r])]);
    expect(habits[1].last, '0');
    final lab = worked(rows(labText(DateTime(2026, 3, 9))).skip(0).take(5).toList());
    expect(lab.every((r) => r.every((c) => !c.startsWith('='))), isTrue);
    final exam = worked([for (final r in rows(examText()).take(2)) r]);
    expect(exam.every((r) => r.every((c) => !isFormula(c))), isTrue);
  });

  test('the week number is the ISO one', () {
    expect(templateWeek(DateTime(2026, 3, 9)), 11);
    expect(templateWeek(DateTime(2026, 1, 1)), 1);
    expect(templateWeek(DateTime(2027, 1, 1)), 53);
  });

  testWidgets('the dashboard offers the pages and opens the new note', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? opened;
    await tester.pumpWidget(MaterialApp(home: DashboardView(repository: repo, templates: service, onOpenNote: (id) => opened = id)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-note-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('make-new-from-template')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('template-search')), 'meeting');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('template-meeting')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect((await tester.runAsync(() => repo.loadNote(opened!)))!.documentText, contains('Action items'));
    await tester.pumpWidget(const SizedBox());
  });
}
