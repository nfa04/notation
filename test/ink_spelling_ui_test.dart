import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/spelling/hunspell.dart';
import 'package:notes/spelling/spell_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'close_editor.dart';
import 'ink_prefetch_test.dart' show FakeReader, word;
import 'spelling/hunspell_test.dart' show english, englishWords;

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;
  late SpellService spell;

  Future<void> setUpNote(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['ink_text', 'ink_reads', 'notes']) {
        await db.delete(t);
      }
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = word('w', 300, 300);
      await repo.saveNote(note);
      spell = SpellService((k) async => null, (k, v) async {}, languages: const []);
      spell.checker.dictionaries = [await HunspellDictionary.parse(utf8.encode(english), utf8.encode(englishWords))];
    });
  }

  Future<void> open(WidgetTester tester, FakeReader text, FakeReader? math) async {
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(key: UniqueKey(), noteId: id, repository: repo, handwriting: text, math: math, spell: spell, inkIdle: const Duration(milliseconds: 40)),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }


  for (final withMath in [false, true]) {
    testWidgets('a misspelled handwritten word is underlined once the writing is read; opened again, it is there without reading (maths check: $withMath)', (tester) async {
      await setUpNote(tester);
      final text = FakeReader((s) => 'the hapy dog = 1');
      final math = withMath ? FakeReader((s) => 'x=1') : null;
      await open(tester, text, math);
      expect(text.calls, isNotEmpty, reason: 'the writing was read');
      expect(find.byKey(const ValueKey('ink-spell-hapy')), findsOneWidget);
      await closeEditor(tester);

      final again = FakeReader((s) => 'the hapy dog = 1');
      final mathAgain = withMath ? FakeReader((s) => 'x=1') : null;
      await open(tester, again, mathAgain);
      expect(again.calls, isEmpty, reason: 'what was read is kept');
      expect(mathAgain?.calls ?? const [], isEmpty, reason: 'the formulas too');
      expect(find.byKey(const ValueKey('ink-spell-hapy')), findsOneWidget);
      await closeEditor(tester);
    });
  }

  testWidgets('words that are spelled right are marked and can be tapped once the person asks for it', (tester) async {
    await setUpNote(tester);
    final text = FakeReader((s) => 'the hapy dog');
    await open(tester, text, null);
    expect(find.byKey(const ValueKey('ink-spell-hapy')), findsOneWidget);
    expect(find.byKey(const ValueKey('ink-word-the')), findsNothing, reason: 'by default right words are not marked');
    await tester.runAsync(() => spell.setShowChecked(true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('ink-word-the')), findsOneWidget);
    expect(find.byKey(const ValueKey('ink-word-dog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ink-word-dog')));
    await tester.pumpAndSettle();
    expect(find.text('Read as: dog'), findsOneWidget);
    await closeEditor(tester);
  });
}
