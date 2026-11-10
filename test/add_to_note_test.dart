import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_model.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;
  late FakeModel model;

  Future<void> open(WidgetTester tester, {String document = '# Greek history\n\nAncient Greece began in the Bronze Age.'}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote(title: 'History');
      final n = (await repo.loadNote(id))!;
      n.documentText = document;
      await repo.saveNote(n);
    });
    model = FakeModel()..respond = (_) => 'Greece had city-states.';
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: AiService(providers: [model]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Future<void> openAssistant(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
  }

  Future<String> savedDocument(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    return (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return (await repo.loadNote(id))!.documentText;
    }))!;
  }

  Future<void> ask(WidgetTester tester) async {
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Summarise');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    final add = find.byKey(const ValueKey('assistant-add-1'));
    for (var i = 0; i < 100 && add.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(add, findsOneWidget);
  }

  testWidgets('an answer goes to the end of the written document, with nothing but its text', (tester) async {
    await open(tester);
    await openAssistant(tester);
    await ask(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-add-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-target-document')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-target-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-target-textBox')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-target-document')));
    await tester.pumpAndSettle();
    expect(find.text('Added to the written document'), findsOneWidget);
    expect(await savedDocument(tester), '# Greek history\n\nAncient Greece began in the Bronze Age.\n\nGreece had city-states.\n');
  });

  testWidgets('"a page of its own" is a page break and then the text; on an empty note there is no page to break from', (tester) async {
    await open(tester);
    await openAssistant(tester);
    await ask(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-add-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-target-page')));
    await tester.pumpAndSettle();
    expect(find.text('Added on a page of its own'), findsOneWidget);
    expect(await savedDocument(tester), '# Greek history\n\nAncient Greece began in the Bronze Age.\n\n\\pagebreak\n\nGreece had city-states.\n');
  });

  testWidgets('on a note with no written text yet, the page target just writes the text', (tester) async {
    await open(tester, document: '');
    await openAssistant(tester);
    await ask(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-add-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-target-page')));
    await tester.pumpAndSettle();
    expect(await savedDocument(tester), 'Greece had city-states.\n');
    expect(find.text('Added to the written document'), findsOneWidget, reason: 'no page break was needed: it is the first page');
  });

  testWidgets('adding to the document is one step of the note\'s undo', (tester) async {
    await open(tester);
    await openAssistant(tester);
    await ask(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-add-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-target-document')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect(await savedDocument(tester), '# Greek history\n\nAncient Greece began in the Bronze Age.');
  });

  testWidgets('the Summary sheet puts the text in the document under its name', (tester) async {
    await open(tester);
    await openAssistant(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-make-summary')));
    final add = find.byKey(const ValueKey('note-ai-add-text'));
    for (var i = 0; i < 100 && add.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-target-page')));
    await tester.pumpAndSettle();
    expect(await savedDocument(tester), '# Greek history\n\nAncient Greece began in the Bronze Age.\n\n\\pagebreak\n\n## Summary\n\nGreece had city-states.\n');
    expect(find.byKey(const ValueKey('note-ai-text')), findsNothing, reason: 'the sheet closed');
  });

  testWidgets('the Generated panel stays beside the page, shows what was made and puts it in the note', (tester) async {
    await open(tester);
    await tester.runAsync(() => repo.ai.put(NoteAiRow(noteId: id, kind: 'studyGuide', content: '- Key term: polis', createdAt: DateTime(2026, 10, 30))));
    await tester.ensureVisible(find.byKey(const ValueKey('generated-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('generated-button')));
    for (var i = 0; i < 20 && find.byKey(const ValueKey('generated-item-studyGuide')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('generated-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('generated-item-studyGuide')), findsOneWidget);
    expect(find.text('30.10.2026'), findsOneWidget);
    // what is not made yet is offered, what is made is not
    expect(find.byKey(const ValueKey('generated-make-summary')), findsOneWidget);
    expect(find.byKey(const ValueKey('generated-make-studyGuide')), findsNothing);
    // opened, it can be read in the panel (once it has slid in)
    expect(find.byKey(const ValueKey('generated-text-studyGuide')), findsNothing);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('Study guide'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('generated-text-studyGuide')), findsOneWidget);
    // and put in the note without leaving the page
    await tester.tap(find.byKey(const ValueKey('generated-add-studyGuide')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-target-document')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('generated-panel')), findsOneWidget, reason: 'the panel stays open');
    expect(await savedDocument(tester), '# Greek history\n\nAncient Greece began in the Bronze Age.\n\n## Study guide\n\n- Key term: polis\n');
  });

  testWidgets('keeping an answer with the note leaves the pages and the written document alone, and the panel has it', (tester) async {
    await open(tester);
    await openAssistant(tester);
    await ask(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-add-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-target-keep')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-target-keep')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Kept with the note'), findsOneWidget);
    expect(await savedDocument(tester), '# Greek history\n\nAncient Greece began in the Bronze Age.', reason: 'not in the written document');
    final rows = (await tester.runAsync(() => repo.ai.of(id)))!;
    expect(rows.map((r) => (r.kind, r.content)), [('saved', 'Greece had city-states.')]);
    final boxes = (await tester.runAsync(() async => (await repo.loadNote(id))!.textBoxes.values.expand((l) => l).length))!;
    expect(boxes, 0, reason: 'not a text box either');

    // the panel lists it (the snackbar offers to show it)
    await tester.tap(find.text('Show'));
    final item = find.byKey(ValueKey('generated-kept-${rows.single.key}'));
    for (var i = 0; i < 20 && item.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(item, findsOneWidget);
    expect(find.text('Greece had city-states.'), findsWidgets);
    // from there it can still be put in the note, but not kept again
    await tester.tap(find.byKey(ValueKey('generated-add-${rows.single.key}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-target-keep')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-target-document')));
    await tester.pumpAndSettle();
    expect(await savedDocument(tester), '# Greek history\n\nAncient Greece began in the Bronze Age.\n\nGreece had city-states.\n');
    expect((await tester.runAsync(() => repo.ai.of(id)))!, hasLength(1), reason: 'and it stays kept');
    // and it can be thrown away
    await tester.tap(find.byKey(ValueKey('generated-delete-${rows.single.key}')));
    for (var i = 0; i < 20 && item.evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(item, findsNothing);
    expect((await tester.runAsync(() => repo.ai.of(id)))!, isEmpty);
  });

  testWidgets('what the sheet made is not offered to be kept: it is kept already', (tester) async {
    await open(tester);
    await openAssistant(tester);
    await tester.tap(find.byKey(const ValueKey('assistant-make-summary')));
    final add = find.byKey(const ValueKey('note-ai-add-text'));
    for (var i = 0; i < 100 && add.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-target-document')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-target-keep')), findsNothing);
  });

  test('a kept text goes with the note in its file', () async {
    final dir = await Directory.systemTemp.createTemp('kept_');
    addTearDown(() => dir.delete(recursive: true));
    final db = await AppDatabase.open(path: '${dir.path}/n.db');
    final notes = NoteRepository(db);
    final service = NoteFileService(notes, supportDirectory: () async => dir);
    final id = await notes.createNote(title: 'History');
    await notes.ai.put(NoteAiRow(noteId: id, kind: 'saved', key: '17', content: 'Greece had city-states.', createdAt: DateTime(2026, 10, 31)));
    final bytes = (await service.exportBytes(id))!;
    final other = await service.importBytes(bytes);
    final rows = await notes.ai.of(other.noteId);
    expect(rows.map((r) => (r.kind, r.key, r.content)), [('saved', '17', 'Greece had city-states.')]);
    await db.close();
  });

  testWidgets('the Generated panel and the assistant take turns beside the page', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-panel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('generated-button')));
    for (var i = 0; i < 20 && find.byKey(const ValueKey('generated-none')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('generated-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('generated-none')), findsOneWidget, reason: 'nothing made yet says so');
    expect(find.byKey(const ValueKey('assistant-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('generated-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('generated-panel')), findsNothing);
  });
}
