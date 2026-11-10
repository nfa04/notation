import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/models/align_snap.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const page = Size(600, 800);

  group('lining up a moved thing', () {
    test(
      'an edge near another thing\'s edge is pulled onto it, and a line shows where they meet',
      () {
        final other = const Rect.fromLTWH(300, 400, 100, 50);
        final s = alignWhileMoving(
          const Rect.fromLTWH(104, 100, 80, 40),
          [other],
          page,
          threshold: 6,
        );
        // (its right edge, 184, is far from every edge; its left, 104, from the page's left, 0, too)
        expect(s.delta, Offset.zero);
        expect(s.lines, isEmpty);

        final near = alignWhileMoving(const Rect.fromLTWH(297, 100, 80, 40), [
          other,
        ], page);
        expect(near.delta, const Offset(3, 0), reason: 'left edge onto 300');
        expect(
          near.lines,
          contains(const AlignLine(true, 300, 100, 450)),
          reason: 'it runs from the moved thing to the other',
        );
      },
    );

    test(
      'middles line up too, and the nearer of two matches wins, on each axis on its own',
      () {
        final other = const Rect.fromLTWH(
          300,
          400,
          100,
          50,
        ); // middle 350 across, 425 down
        final s = alignWhileMoving(const Rect.fromLTWH(311, 403, 80, 40), [
          other,
        ], page); // middle 351 across, 423 down; its top is 3 from the top
        expect(
          s.delta,
          const Offset(-1, 2),
          reason: 'the middle (2 away) beats the top (3 away)',
        );
        expect(
          s.lines.where((l) => l.vertical).map((l) => l.at),
          contains(350),
        );
        expect(
          s.lines.where((l) => !l.vertical).map((l) => l.at),
          contains(425),
        );
      },
    );

    test('the edges and the middle of the page count', () {
      final s = alignWhileMoving(
        const Rect.fromLTWH(221, 3, 160, 40),
        const [],
        page,
      ); // middle 301
      expect(s.delta, const Offset(-1, -3));
      expect(s.lines, contains(const AlignLine(true, 300, 0, 800)));
      expect(
        s.lines,
        contains(const AlignLine(false, 0, 0, 600)),
        reason: 'its top meets the top of the page',
      );
    });

    test('nothing near: nothing moves and nothing is shown', () {
      final s = alignWhileMoving(const Rect.fromLTWH(130, 130, 50, 50), [
        const Rect.fromLTWH(300, 400, 100, 50),
      ], page);
      expect(s.delta, Offset.zero);
      expect(s.lines, isEmpty);
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<void> pull(
      WidgetTester tester, {
      FeatureSettings? features,
      required bool snaps,
    }) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        repo = NoteRepository(
          await AppDatabase.open(path: inMemoryDatabasePath),
        );
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.textBoxes[0] = [
          TextBoxWidgetModel(
            id: 'fixed',
            position: const Offset(400, 400),
            size: const Size(200, 40),
            initialText: 'Fixed',
          ),
          TextBoxWidgetModel(
            id: 'mover',
            position: const Offset(100, 100),
            size: const Size(200, 40),
            initialText: 'Mover',
          ),
        ];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FixedPageNoteEditor(
            key: ValueKey(id),
            noteId: id,
            repository: repo,
            features: features,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();

      double left(String text) => tester.getTopLeft(find.text(text)).dx;
      final g = await tester.startGesture(
        tester.getTopLeft(find.text('Mover')) + const Offset(20, 10),
      );
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(20, 5));
        await tester.pump();
      }
      expect(
        find.byKey(const ValueKey('align-lines')),
        findsNothing,
        reason: 'far from everything',
      );
      await g.moveBy(Offset(left('Fixed') - left('Mover') - 3, 0));
      await tester.pump();
      if (snaps) {
        expect(
          left('Mover'),
          left('Fixed'),
          reason: 'three away from the other box: pulled onto it',
        );
        expect(find.byKey(const ValueKey('align-lines')), findsOneWidget);
      } else {
        expect(
          left('Mover'),
          isNot(left('Fixed')),
          reason: 'the feature is off: it stays where it was put',
        );
        expect(find.byKey(const ValueKey('align-lines')), findsNothing);
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(left('Mover') == left('Fixed'), snaps);
      expect(find.byKey(const ValueKey('align-lines')), findsNothing);
    }

    testWidgets(
      'a text box pulled near another one falls into line with it, and the lines go when it is let go',
      (tester) => pull(tester, snaps: true),
    );

    testWidgets('with the feature off it does not', (tester) async {
      final store = <String, String>{};
      final features = FeatureSettings(
        (k) async => store[k],
        (k, v) async => store[k] = v,
      );
      await features.apply(
        {...FeaturePresets.everything}..remove(Feature.alignLines),
      );
      await pull(tester, features: features, snaps: false);
    });
  });
}
