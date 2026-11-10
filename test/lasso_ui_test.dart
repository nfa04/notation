import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.stylus, PointerDeviceKind.touch]) {
    testWidgets('the lasso selects a drawing with a $kind', (tester) async {
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
        note.strokes[0] = [
          DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
            for (var i = 0; i < 20; i++) Offset(300.0 + i * 4, 300.0 + (i.isEven ? 0 : 10)),
          ]),
        ];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
      await tester.pumpAndSettle();

      // the page starts at x = (1600 - 56 bar - 1 - 800) / 2 and 16 below the toolbar
      final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
      final left = (1600 - 57 - 800) / 2;
      Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);

      final g = await tester.startGesture(at(280, 280), kind: kind, buttons: kind == PointerDeviceKind.mouse ? kPrimaryMouseButton : 0);
      for (final p in [at(280, 280), at(400, 280), at(400, 340), at(280, 340), at(280, 285)]) {
        await g.moveTo(p);
        await tester.pump();
      }
      await g.up();
      await tester.pump();

      expect(find.byTooltip('Delete drawing'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1)); // let the double-tap timer run out
    });
  }

  testWidgets('the corners of the selection resize it, the shape keeps its proportions, and it can be taken back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
          for (var i = 0; i < 20; i++) Offset(300.0 + i * 4, 300.0 + (i.isEven ? 0 : 10)),
        ]),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();

    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final lasso = await tester.startGesture(at(280, 280), kind: PointerDeviceKind.touch);
    for (final p in [at(280, 280), at(400, 280), at(400, 340), at(280, 340), at(280, 285)]) {
      await lasso.moveTo(p);
      await tester.pump();
    }
    await lasso.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('resize-br')), findsOneWidget);
    expect(find.byKey(const ValueKey('resize-tl')), findsOneWidget);

    Future<Rect> savedBounds() async {
      await tester.pump(const Duration(seconds: 3)); // the note is saved a moment after a change
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      final points = (await tester.runAsync(() => repo.loadNote(id)))!.strokes[0]!.single.points;
      var r = Rect.fromPoints(points.first, points.first);
      for (final p in points) {
        r = r.expandToInclude(Rect.fromPoints(p, p));
      }
      return r;
    }

    final before = await savedBounds();
    expect(before.width, closeTo(76, 0.5));

    // pull the lower right corner out along the diagonal
    final handle = tester.getCenter(find.byKey(const ValueKey('resize-br')));
    final g = await tester.startGesture(handle, kind: PointerDeviceKind.touch);
    for (var i = 1; i <= 6; i++) {
      await g.moveTo(handle + Offset(15.0 * i, 4.2 * i));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    final after = await savedBounds();
    expect(after.width, greaterThan(before.width * 1.6));
    expect(after.height / after.width, closeTo(before.height / before.width, 0.02)); // proportions kept
    expect(after.topLeft.dx, closeTo(before.topLeft.dx, 0.5)); // the opposite corner stays

    // one step back
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pump();
    final undone = await savedBounds();
    expect(undone.width, closeTo(before.width, 0.5));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the Delete key removes what the lasso selected', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
          for (var i = 0; i < 20; i++) Offset(300.0 + i * 4, 300.0 + (i.isEven ? 0 : 10)),
        ]),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();

    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final lasso = await tester.startGesture(at(280, 280), kind: PointerDeviceKind.touch);
    for (final p in [at(280, 280), at(400, 280), at(400, 340), at(280, 340), at(280, 285)]) {
      await lasso.moveTo(p);
      await tester.pump();
    }
    await lasso.up();
    await tester.pump();
    expect(find.byTooltip('Delete drawing'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(find.byTooltip('Delete drawing'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });
}
