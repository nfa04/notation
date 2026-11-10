import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/arrange.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('aligning', () {
    const rects = [Rect.fromLTWH(10, 10, 20, 20), Rect.fromLTWH(50, 40, 40, 10), Rect.fromLTWH(30, 100, 10, 30)];

    test('each side and each middle of the box around them', () {
      Rect moved(int i, AlignTo to) => rects[i].shift(alignDeltas(rects, to)[i]);
      expect(moved(1, AlignTo.left).left, 10);
      expect(moved(0, AlignTo.right).right, 90);
      expect(moved(2, AlignTo.centre).center.dx, 50);
      expect(moved(1, AlignTo.top).top, 10);
      expect(moved(0, AlignTo.bottom).bottom, 130);
      expect(moved(1, AlignTo.middle).center.dy, 70);
      expect(alignDeltas(const [], AlignTo.left), isEmpty);
    });

    test('distributing leaves the outer two and gives the rest the same space between', () {
      final row = [const Rect.fromLTWH(0, 0, 10, 10), const Rect.fromLTWH(15, 0, 30, 10), const Rect.fromLTWH(90, 0, 10, 10)];
      final d = distributeDeltas(row, horizontal: true);
      final out = [for (var i = 0; i < 3; i++) row[i].shift(d[i])];
      expect(out.first.left, 0);
      expect(out.last.right, 100);
      expect(out[1].left - out[0].right, closeTo(out[2].left - out[1].right, 1e-9));
      expect(distributeDeltas(row.take(2).toList(), horizontal: true), everyElement(Offset.zero), reason: 'two have nothing between them');
      // out of order in the list, in a column
      final col = [const Rect.fromLTWH(0, 90, 10, 10), const Rect.fromLTWH(0, 0, 10, 10), const Rect.fromLTWH(0, 20, 10, 10)];
      final c = distributeDeltas(col, horizontal: false);
      expect(col[2].shift(c[2]).top, 45);
    });

    test('lines that touch are one thing', () {
      final g = overlapGroups(const [Rect.fromLTWH(0, 0, 10, 10), Rect.fromLTWH(10, 5, 10, 10), Rect.fromLTWH(100, 100, 5, 5), Rect.fromLTWH(18, 12, 5, 5)]);
      expect(g, [[0, 1, 3], [2]]);
    });
  });

  testWidgets('three text boxes are lined up on their left sides and taken back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [
        TextBoxWidgetModel(id: 'a', position: const Offset(100, 100), size: const Size(150, 40), initialText: 'Aaa'),
        TextBoxWidgetModel(id: 'b', position: const Offset(200, 200), size: const Size(150, 40), initialText: 'Bbb'),
        TextBoxWidgetModel(id: 'c', position: const Offset(300, 300), size: const Size(150, 40), initialText: 'Ccc'),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    Future<void> lassoAll() async {
      final lasso = await tester.startGesture(at(60, 60), kind: PointerDeviceKind.touch);
      for (final p in [at(60, 60), at(600, 60), at(600, 450), at(60, 450), at(60, 65)]) {
        await lasso.moveTo(p);
        await tester.pump();
      }
      await lasso.up();
      await tester.pumpAndSettle();
    }

    await lassoAll();

    expect(find.byKey(const ValueKey('duplicate-selection')), findsOneWidget, reason: 'the lasso took them');
    double x(String t) => tester.getTopLeft(find.text(t)).dx;
    final before = [x('Aaa'), x('Bbb'), x('Ccc')];
    expect(before.toSet().length, 3);
    await tester.tap(find.byKey(const ValueKey('arrange-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('arrange-left')));
    await tester.pumpAndSettle();
    expect([x('Aaa'), x('Bbb'), x('Ccc')].map((v) => v.round()).toSet().length, 1, reason: 'all start at the left edge of the leftmost');
    expect(x('Aaa'), closeTo(before[0], 0.5));

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect([x('Aaa'), x('Bbb'), x('Ccc')], before);

    // the same three, spaced evenly down: the middle one goes to the middle (taking back let go of the selection)
    await lassoAll();
    await tester.tap(find.byKey(const ValueKey('arrange-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('arrange-spaceDown')));
    await tester.pumpAndSettle();
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Bbb') - y('Aaa'), closeTo(y('Ccc') - y('Bbb'), 1));
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  });
}
