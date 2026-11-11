import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/spell_settings.dart';
import 'package:notes/spelling/hunspell.dart';
import 'package:notes/spelling/spell_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'hunspell_test.dart' show english, englishWords;

void main() {
  setUpAll(AppDatabase.initFfi);

  late SpellService service;
  setUp(() async {
    final map = <String, String>{};
    service = SpellService((k) async => map[k], (k, v) async => map[k] = v, languages: const []);
    service.checker.dictionaries = [await HunspellDictionary.parse(utf8.encode(english), utf8.encode(englishWords))];
  });

  testWidgets('in the written document, misspelled words are marked and the menu offers what was meant', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.documentText = 'the cat and teh dog';
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, spell: service)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    await tester.pump();

    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    expect([for (final r in controller.misspelled) controller.text.substring(r.start, r.end)], ['and', 'teh']);

    // put the cursor in the word and ask for the menu: "the" is offered
    controller.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump();
    tester.state<BlockEditorState>(find.byType(BlockEditor)).debugShowMenu();
    await tester.pumpAndSettle();
    expect(find.text('the'), findsWidgets);
    expect(find.text('Add to dictionary'), findsOneWidget);
    await tester.tap(find.text('the').last);
    await tester.pumpAndSettle();
    expect(controller.text, 'the cat and the dog');
    await tester.pumpWidget(const SizedBox()); // (the editor goes: so does the timer of a text that was just changed)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  testWidgets('a tap on a misspelled word offers what it may have been meant to be', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.documentText = 'the cat teh dog';
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, spell: service)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    await tester.pump();
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    expect(controller.misspelled, hasLength(1));

    // a tap on the word "teh": about where it is on the line
    final blocks = tester.state<BlockEditorState>(find.byType(BlockEditor));
    final at = blocks.screenRectOf(const TextRange(start: 9, end: 10))!.center;
    await tester.tapAt(at);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spell-suggestion-0')), findsOneWidget);
    expect(find.text('the'), findsWidgets);
    expect(find.text('Add to dictionary'), findsOneWidget);
    // the menu is under the word, not over it
    final word = blocks.screenRectOf(const TextRange(start: 8, end: 11))!;
    expect(tester.getTopLeft(find.byKey(const ValueKey('spell-suggestion-0'))).dy, greaterThanOrEqualTo(word.bottom));
    expect(tester.getTopLeft(find.byKey(const ValueKey('spell-suggestion-0'))).dx, closeTo(word.left, 20));
    await tester.tap(find.byKey(const ValueKey('spell-suggestion-0')));
    await tester.pumpAndSettle();
    expect(controller.text, 'the cat the dog');

    // a tap on a word that is right says nothing
    await tester.tapAt(blocks.screenRectOf(const TextRange(start: 5, end: 6))!.center);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spell-suggestion-0')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no spell checking without a service', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.documentText = 'the teh';
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    expect(controller.misspelled, isEmpty);
  });

  testWidgets('the settings list the languages with their licence, and the own words can be added and removed', (tester) async {
    final map = <String, String>{};
    final svc = SpellService((k) async => map[k], (k, v) async => map[k] = v, languages: const [DictionaryLanguage('en_US', 'English', 'en', 'en_US', 1, 'BSD-style')]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SpellSettings(service: svc)))));
    expect(find.text('English'), findsOneWidget);
    expect(find.textContaining('Licence: BSD-style'), findsOneWidget);
    expect(find.textContaining('Download about 1 MB'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('spell-new-word')), 'Zorblax');
    await tester.ensureVisible(find.byKey(const ValueKey('spell-add-word')));
    await tester.tap(find.byKey(const ValueKey('spell-add-word')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spell-word-Zorblax')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('spell-word-Zorblax')), matching: find.byType(Icon)).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spell-word-Zorblax')), findsNothing);
  });
}
