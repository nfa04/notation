
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/undo_stack.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('steps are taken back newest first, done again, and forgotten when something new is done', () {
    final log = <String>[];
    UndoStep step(String name) => UndoStep(() => log.add('undo $name'), () => log.add('redo $name'));
    final stack = UndoStack(limit: 3);
    expect((stack.canUndo, stack.canRedo, stack.undo(), stack.redo()), (false, false, false, false));
    stack
      ..push(step('a'))
      ..push(step('b'))
      ..push(step('c'));
    stack.undo();
    stack.undo();
    expect(log, ['undo c', 'undo b']);
    expect(stack.canRedo, isTrue);
    stack.redo();
    expect(log.last, 'redo b');
    stack.push(step('d')); // something new: c can no longer be redone
    expect(stack.canRedo, isFalse);
    stack.undo();
    stack.undo();
    stack.undo();
    expect(log.skip(2), ['redo b', 'undo d', 'undo b', 'undo a']);
    expect(stack.canUndo, isFalse);
    // only the newest `limit` steps are kept
    final small = UndoStack(limit: 2)
      ..push(step('1'))
      ..push(step('2'))
      ..push(step('3'));
    small
      ..undo()
      ..undo();
    expect(small.canUndo, isFalse);
    expect(log.skip(6), ['undo 3', 'undo 2']);
    stack
      ..push(step('x'))
      ..clear();
    expect((stack.canUndo, stack.canRedo), (false, false));
  });

  testWidgets('undo takes back what was done last, wherever it was, and redo does it again', (tester) async {
    tester.view.physicalSize = const Size(1600, 3200); // two pages on screen
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
    });
    await tester.runAsync(() => repo.settings.set('draw_bar_more', '1')); // (the rarely used tools are folded away by default)
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    // the tools are on the right, not in the top bar
    expect(find.byKey(const ValueKey('undo-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('redo-button')), findsOneWidget);
    expect(find.byTooltip('Undo Last Stroke'), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('undo-button'))).onPressed, isNull); // nothing to take back yet
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('redo-button'))).onPressed, isNull);

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    Future<void> draw(String page, double y) async {
      final origin = tester.getTopLeft(find.byKey(ValueKey(page)));
      final g = await tester.createGesture();
      await g.down(origin + Offset(100, y));
      for (var i = 1; i <= 20; i++) {
        await g.moveTo(origin + Offset(100.0 + i * 15, y + (i.isEven ? 9 : -9)));
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    Future<void> tap(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    List<double> ys() => (strokes().map((s) => s.points.first.dy).toList()..sort());

    // two pages, drawn on in turn: the last one drawn goes first, whichever page it is on
    await draw('page-0', 200); // (the second page appears once the first has something on it)
    await draw('page-1', 300);
    await draw('page-0', 400);
    expect(ys(), [200.0, 300.0, 400.0]);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('undo-button'))).onPressed, isNotNull);

    await tap('undo-button');
    expect(ys(), [200.0, 300.0]); // the one on the first page, not the last page that had a line
    await tap('undo-button');
    expect(ys(), [200.0]);
    await tap('redo-button');
    expect(ys(), [200.0, 300.0]);
    await draw('page-0', 400); // something new: the one taken back cannot come back any more
    await draw('page-0', 600);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('redo-button'))).onPressed, isNull);
    expect(ys(), [200.0, 300.0, 400.0, 600.0]);

    // rubbing out is one step, however many lines it crosses
    await tester.tap(find.byTooltip('Eraser (drawings only)'));
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final g = await tester.createGesture();
    await g.down(origin + const Offset(250, 350));
    for (var y = 360.0; y <= 650; y += 10) {
      await g.moveTo(origin + Offset(250, y));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(ys(), [200.0, 300.0]);
    await tap('undo-button');
    expect(ys(), [200.0, 300.0, 400.0, 600.0]); // both back, in one go
    await tap('redo-button');
    expect(ys(), [200.0, 300.0]);
    await tap('undo-button');

    // clearing the page on screen (the first) leaves the other page alone, and can be taken back
    expect(find.byTooltip('Clear All Annotations'), findsNothing); // no longer in the top bar
    await tap('clear-page');
    expect(ys(), [300.0]);
    await tap('undo-button');
    expect(ys(), [200.0, 300.0, 400.0, 600.0]);
    await tap('redo-button');
    expect(ys(), [300.0]);
    await tap('undo-button');
    expect(ys(), [200.0, 300.0, 400.0, 600.0]);

    // and it is saved: what was taken back does not come back when the note is opened again
    await tap('undo-button'); // the rubbing out is taken back no more; this was the last step of drawing: 600 goes
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(saved.strokes.values.fold<int>(0, (n, l) => n + l.length), strokes().length);
  });

  testWidgets('moving selected drawings and deleting them can be taken back', (tester) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 20; i++) Offset(200.0 + i * 5, 300.0 + i)])];
      await repo.saveNote(note);
    });
    await tester.runAsync(() => repo.settings.set('draw_bar_more', '1')); // (the rarely used tools are folded away by default)
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    Future<void> tap(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.ensureVisible(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final lasso = await tester.createGesture();
    await lasso.down(origin + const Offset(150, 250));
    for (final p in const [Offset(400, 250), Offset(400, 400), Offset(150, 400), Offset(150, 250)]) {
      await lasso.moveTo(origin + p);
    }
    await lasso.up();
    await tester.pumpAndSettle();

    // drag the selection 100 to the right and 200 down
    final before = strokes().single.points.first;
    final drag = await tester.createGesture();
    await drag.down(origin + const Offset(250, 305));
    for (var i = 1; i <= 10; i++) {
      await drag.moveTo(origin + Offset(250 + i * 10, 305 + i * 20));
    }
    await drag.up();
    await tester.pumpAndSettle();
    final after = strokes().single.points.first;
    expect(after.dx, greaterThan(before.dx + 50));
    expect(after.dy, greaterThan(before.dy + 100));

    await tap('undo-button'); // the move
    expect(strokes().single.points.first, before);
    await tap('redo-button');
    expect(strokes().single.points.first, after);
    await tap('undo-button');
    expect(strokes().single.points.first, before);
  });
}
