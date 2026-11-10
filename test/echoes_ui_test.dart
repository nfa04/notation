
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id, other;
  final opened = <(String, int?)>[];

  Future<FeatureSettings> open(WidgetTester tester, {bool withFacts = true, bool on = true}) async {
    opened.clear();
    final features = FeatureSettings((k) async => null, (k, v) async {});
    if (!on) await features.set(Feature.echoes, false);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('notes');
      await db.delete('facts');
      repo = NoteRepository(db);
      other = await repo.createNote(title: 'Linear algebra 3');
      id = await repo.createNote(title: 'Today');
      if (withFacts) {
        await repo.knowledge.replaceFacts(other, 1, 'm', 'x', [
          StoredFact(noteId: other, page: 2, title: 'Eigenvalues', sentence: 'An eigenvalue of a matrix is a root of its characteristic polynomial.', keywords: const ['eigenvalue', 'characteristic polynomial', 'matrix']),
        ]);
      }
    });
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(
        key: ValueKey(id),
        noteId: id,
        repository: repo,
        features: features,
        onOpenNote: (n) => opened.add((n, null)),
        onOpenNoteAt: (n, page) => opened.add((n, page)),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    return features;
  }

  /// Writes [text] in the written document of the note.
  Future<void> write(WidgetTester tester, String text) async {
    await tester.tap(find.text('Document'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(BlockEditor));
    await tester.pump(const Duration(milliseconds: 300));
    tester.widget<BlockEditor>(find.byType(BlockEditor)).controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    await tester.pump();
  }

  /// The moment of waiting, and the look-up that follows (the facts come from the database).
  Future<void> wait(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 2000));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
    }
  }

  testWidgets('a text that has the terms of another note names that note, which opens at the page of the fact', (tester) async {
    await open(tester);
    await write(tester, 'Today we need the eigenvalue of the matrix, from its characteristic polynomial.');
    expect(find.byKey(const ValueKey('echoes')), findsNothing, reason: 'not before the writing stops');
    await wait(tester);
    expect(find.byKey(const ValueKey('echoes')), findsOneWidget);
    expect(find.text('Linear algebra 3'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('echo-$other')));
    await tester.pump();
    expect(opened, [(other, 2)]);

    await tester.tap(find.byKey(const ValueKey('echoes-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('echoes')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a text about something else, a note without facts and the tool switched off show nothing', (tester) async {
    await open(tester);
    await write(tester, 'Buy flour and yeast for the bread on Saturday.');
    await wait(tester);
    expect(find.byKey(const ValueKey('echoes')), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await open(tester, withFacts: false);
    await write(tester, 'Today we need the eigenvalue of the matrix, from its characteristic polynomial.');
    await wait(tester);
    expect(find.byKey(const ValueKey('echoes')), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await open(tester, on: false);
    await write(tester, 'Today we need the eigenvalue of the matrix, from its characteristic polynomial.');
    await wait(tester);
    expect(find.byKey(const ValueKey('echoes')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
