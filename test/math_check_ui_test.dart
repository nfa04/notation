import 'dart:ui';

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_prefetcher.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ink_prefetch_test.dart' show FakeReader, scribble, until, word;

void main() {
  setUpAll(AppDatabase.initFfi);

  group('rows of writing', () {
    test('lines that are close are one block, and each line is a row', () {
      final strokes = [...word('a', 100, 100), ...word('b', 100, 130), ...word('c', 100, 160)];
      final blocks = clusterStrokes(0, strokes);
      expect(blocks, hasLength(1), reason: 'close enough to be one block');
      final rows = rowsOf(blocks.single);
      expect(rows, hasLength(3));
      expect(rows.map((r) => r.ids.first[0]), ['a', 'b', 'c']);
      expect(rows.first.bounds.top, lessThan(rows.last.bounds.top));
    });

    test('one line stays one row', () {
      final block = clusterStrokes(0, word('a', 100, 100)).single;
      expect(rowsOf(block), hasLength(1));
      expect(rowsOf(block).single.key, block.key);
    });

    test('the parts of a fraction stay together', () {
      // a numerator, a bar and a denominator: their middles are less than a letter apart
      final top = word('n', 100, 100, n: 2);
      final bar = [scribble('bar', 96, 123, w: 50, h: 1)];
      final bottom = word('d', 100, 126, n: 2);
      final rows = rowsOf(clusterStrokes(0, [...top, ...bar, ...bottom]).single);
      expect(rows, hasLength(1));
    });
  });

  group('reading line by line', () {
    test('a block of lines is read as lines, and the readings are there to use', () async {
      final strokes = {
        0: [...word('a', 100, 100), ...word('b', 100, 130), ...word('c', 100, 160)]
      };
      final text = FakeReader((s) => 'x = 1');
      final math = FakeReader((s) => 'line ${s.first.id[0]}');
      final reader = InkPrefetcher(strokes: () => strokes, idle: const Duration(milliseconds: 10));
      reader.configure(text: text, math: math, rows: true);
      await until(() => reader.waiting == 0);
      final read = reader.readings();
      expect(read.map((r) => r.latex), ['line a', 'line b', 'line c']);
      expect(read.map((r) => r.block.bounds.top), orderedEquals([...read.map((r) => r.block.bounds.top)]..sort()));
      reader.dispose();
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;
    CardRepository? cardRepo;

    // three lines of a solution, which the "formula reader" reads as the three steps
    Future<FeatureSettings> open(WidgetTester tester, Map<String, String> lines, {bool tool = true, bool withCards = false, Map<String, List<String>> again = const {}}) async {
      final features = FeatureSettings((k) async => null, (k, v) async {});
      if (!tool) await features.set(Feature.checkMaths, false);
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        await db.delete('review_cards');
        cardRepo = withCards ? CardRepository(db) : null;
        await repo.settings.set('index_handwriting', '0'); // (reading for the search is not what these tests are about)
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        var y = 300.0;
        note.strokes[0] = [for (final name in lines.keys) ...word(name, 300, y += 30)];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(
        home: FixedPageNoteEditor(
          key: ValueKey(id),
          noteId: id,
          repository: repo,
          handwriting: FakeReader((s) => 'x = 1'),
          math: FakeReader((s) => lines[s.first.id[0]]!, sayAgain: (s) => again[s.first.id[0]] ?? const []),
          inkIdle: const Duration(milliseconds: 40),
          features: features,
          cards: cardRepo,
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      return features;
    }

    Future<void> circleAll(WidgetTester tester) async {
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
      await tester.pumpAndSettle();
      final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
      final left = (1600 - 57 - 800) / 2;
      Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
      final g = await tester.startGesture(at(280, 310), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (final p in [at(280, 310), at(420, 310), at(420, 430), at(280, 430), at(280, 315)]) {
        await g.moveTo(p);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
    }

    testWidgets('with the tool on, a solution is checked a little behind the pen and each line gets its mark', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 5'});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      expect(find.byKey(const ValueKey('math-mark-right')), findsOneWidget, reason: '2x = 8 follows');
      expect(find.byKey(const ValueKey('math-mark-wrong')), findsOneWidget, reason: 'x = 5 does not');

      // the mark says why
      await tester.tap(find.byKey(const ValueKey('math-mark-wrong')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-check-sheet')), findsOneWidget);
      expect(find.text('This does not follow from the line above'), findsOneWidget);
      expect(find.text('The line above has:'), findsOneWidget);
      // it is the sheet of the manual check: every line of the solution, not only the one that was tapped
      expect(find.byKey(const ValueKey('math-check-edit-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('math-check-edit-1')), findsOneWidget);
      expect(find.text('This looks right'), findsOneWidget);
    });

    testWidgets('the sheet of a wrong line can keep the mistake as a flashcard, once', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 5'}, withCards: true);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      for (var round = 0; round < 2; round++) {
        await tester.tap(find.byKey(const ValueKey('math-mark-wrong')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('math-check-keep-card-2')));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // (the card is written to the database)
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('math-check-sheet')), findsNothing, reason: 'the sheet closes');
        expect(find.text(round == 0 ? 'Kept it as a flashcard, to ask again later' : 'This mistake is a flashcard already'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }
      final kept = (await tester.runAsync(() => cardRepo!.due(source: id)))!;
      expect(kept, hasLength(1));
      expect(kept.single.card.front, contains('x = 5'));
      expect(kept.single.card.back, contains('This does not follow from the line above'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the cards there is no such button, and a line that is right has none', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 5'});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('math-mark-wrong')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-check-keep-card-2')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('what was read can be corrected in the sheet of a mark, and the line is checked again', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 5'});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('math-mark-wrong')));
      await tester.pumpAndSettle();
      expect(find.text('This does not follow from the line above'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('math-check-edit-2'))).controller!.text, 'x = 5');

      await tester.enterText(find.byKey(const ValueKey('math-check-edit-2')), r'x = 4');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('This looks right'), findsNWidgets(2), reason: 'it was misread, and now it is right (the line above was right already)');
      expect(find.text('This does not follow from the line above'), findsNothing);
      expect(find.byKey(const ValueKey('math-mark-right')), findsNWidgets(2), reason: 'the marks behind the sheet changed too');
      expect(find.byKey(const ValueKey('math-mark-wrong')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a mistake that reads as no mistake another way is marked "not sure", and the other reading can be picked', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 5'}, again: {'c': [r'x = 4']});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      expect(find.byKey(const ValueKey('math-mark-unsure')), findsOneWidget);
      expect(find.byKey(const ValueKey('math-mark-wrong')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('math-mark-unsure')));
      await tester.pumpAndSettle();
      expect(find.text('I am not sure I read this right'), findsOneWidget);
      expect(find.text('Or did you write:'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('math-check-other-2-0')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('math-check-edit-2'))).controller!.text, 'x = 4');
      expect(find.text('This looks right'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('math-mark-unsure')), findsNothing);
      expect(find.byKey(const ValueKey('math-mark-right')), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a mistake that every reading shows stays a mistake', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 5'}, again: {'c': [r'x = 6', r'x = 5']});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump();
      expect(find.byKey(const ValueKey('math-mark-wrong')), findsOneWidget);
      expect(find.byKey(const ValueKey('math-mark-unsure')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a line can be read again from its sheet, and says when it reads the same', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 4'}, again: {'b': [r'2x = 6']});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('math-mark-right')).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-check-look-again-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('math-check-look-again-1')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-check-other-1-0')), findsOneWidget, reason: 'the other reading is offered');
      expect(find.byKey(const ValueKey('math-check-look-again-1')), findsNothing, reason: 'once is enough');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the sheet of the manual check can be corrected as well', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 5'});
      await circleAll(tester);
      await tester.tap(find.byKey(const ValueKey('check-selected-maths')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.text('This does not follow from the line above'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('math-check-edit-2')), r'x = 4');
      await tester.pumpAndSettle();
      expect(find.text('This does not follow from the line above'), findsNothing);
      expect(find.text('This looks right'), findsNWidgets(2));
    });

    testWidgets('with the tool off nothing is read or marked, and switching it on starts it', (tester) async {
      final features = await open(tester, {'a': r'2x + 3 = 11', 'b': r'x = 5'}, tool: false);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
      expect(find.byKey(const ValueKey('math-mark-wrong')), findsNothing);
      await tester.runAsync(() => features.set(Feature.checkMaths, true));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      expect(find.byKey(const ValueKey('math-mark-wrong')), findsOneWidget);
      await tester.runAsync(() => features.set(Feature.checkMaths, false));
      await tester.pump();
      expect(find.byKey(const ValueKey('math-mark-wrong')), findsNothing);
    });

    testWidgets('circling some maths and pressing the button checks it now', (tester) async {
      await open(tester, {'a': r'2x + 3 = 11', 'b': r'2x = 8', 'c': r'x = 5'});
      await circleAll(tester);
      await tester.tap(find.byKey(const ValueKey('check-selected-maths')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-check-sheet')), findsOneWidget);
      expect(find.text('This looks right'), findsOneWidget);
      expect(find.text('This does not follow from the line above'), findsOneWidget);
      expect(find.text('Nothing to check in this line'), findsOneWidget, reason: 'the first line is an equation to solve');
    });

    testWidgets('what the model reads as an environment is shown as text (the formula widget cannot lay it out)', (tester) async {
      await open(tester, {'a': r'\begin{array}{} \end{array}', 'b': r'\begin{aligned} a &= b \\ c \end{aligned}'});
      await circleAll(tester);
      await tester.tap(find.byKey(const ValueKey('check-selected-maths')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-check-sheet')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text(r'\begin{array}{} \end{array}'), findsAtLeastNWidgets(2), reason: 'in the field, and as text');
    });

    testWidgets('a line that waits for its result shows it', (tester) async {
      await open(tester, {'a': r'17 \cdot 24 ='});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
      await tester.pump();
      expect(find.byKey(const ValueKey('math-mark-answer')), findsOneWidget);
    });

    testWidgets('without the formula reader the tool does nothing and nothing breaks', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        await repo.settings.set('index_handwriting', '0'); // (reading for the search is not what these tests are about)
        id = await repo.createNote();
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, features: FeatureSettings((k) async => null, (k, v) async {}))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('math-check-sheet')), findsNothing);
    });
  });
}
