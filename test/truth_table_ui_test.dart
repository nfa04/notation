import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/truth_table_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the dialog', () {
    Future<void> show(WidgetTester tester, {String initial = '', List<List<String>>? answer}) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                final cells = await showTruthTable(context, initial: initial);
                answer?.addAll(cells ?? const []);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
    }

    testWidgets('a formula gets its table and its kind', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await show(tester);
      expect(find.byKey(const ValueKey('truth-table-view')), findsNothing); // nothing typed yet
      await tester.enterText(find.byKey(const ValueKey('truth-table-formula')), 'p -> q');
      await tester.pump();
      expect(find.byKey(const ValueKey('truth-table-view')), findsOneWidget);
      expect(find.text('p → q'), findsWidgets);
      expect(find.byKey(const ValueKey('truth-table-kind')), findsOneWidget);
      expect(find.text('Sometimes true'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('truth-table-formula')), 'p or not p');
      await tester.pump();
      expect(find.text('Always true (a tautology)'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('truth-table-formula')), 'p and !p');
      await tester.pump();
      expect(find.text('Never true (a contradiction)'), findsOneWidget);
    });

    testWidgets('two formulas are compared', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await show(tester);
      await tester.enterText(find.byKey(const ValueKey('truth-table-formula')), '!(p & q) = !p | !q');
      await tester.pump();
      expect(find.byKey(const ValueKey('truth-table-same')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('truth-table-formula')), 'p -> q = q -> p');
      await tester.pump();
      expect(find.byKey(const ValueKey('truth-table-differ')), findsOneWidget);
      expect(find.text('Not the same: they differ in 2 of 4 rows'), findsOneWidget);
    });

    testWidgets('what cannot be read is told, and nothing can be put on the page', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await show(tester);
      await tester.enterText(find.byKey(const ValueKey('truth-table-formula')), 'p and');
      await tester.pump();
      expect(find.byKey(const ValueKey('truth-table-problem')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('truth-table-put'))).onPressed, isNull);
    });

    testWidgets('the signs are put in where the cursor is', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await show(tester, initial: 'p ');
      await tester.tap(find.byKey(const ValueKey('truth-table-sign-and')));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('truth-table-formula'))).controller!.text, 'p ∧');
    });

    testWidgets('put on the page gives the cells', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final answer = <List<String>>[];
      await show(tester, initial: 'p xor q', answer: answer);
      await tester.tap(find.byKey(const ValueKey('truth-table-put')));
      await tester.pumpAndSettle();
      expect(answer, [
        ['p', 'q', 'p ⊕ q'],
        ['0', '0', '0'],
        ['0', '1', '1'],
        ['1', '0', '1'],
        ['1', '1', '0'],
      ]);
    });
  });

  group('on the page', () {
    late NoteRepository repo;
    late String id;

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote(title: 'Logic');
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    testWidgets('the table becomes a text box', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('add-truth-table')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('truth-table-formula')), 'p -> q');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('truth-table-put')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      final note = (await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return repo.loadNote(id);
      }))!;
      final texts = [for (final b in note.textBoxes[0] ?? <TextBoxWidgetModel>[]) b.controller.text];
      expect(texts, hasLength(1));
      expect(texts.single, startsWith('| p | q | p → q |'));
      expect(texts.single, contains('| 1 | 0 | 0 |'));
    });
  });
}
