
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the scrollbar preview shows the drawings, highlights and text boxes of the page', (tester) async {
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
      note.strokes[0] = [DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 20; i++) Offset(100.0 + i * 5, 300.0 + i)])];
      note.strokes[2] = [
        DrawingStroke(color: Colors.red, width: 3, points: [for (var i = 0; i < 20; i++) Offset(100.0 + i * 5, 300.0 + i)]),
        DrawingStroke(color: Colors.blue, width: 3, points: [for (var i = 0; i < 20; i++) Offset(100.0 + i * 5, 500.0 + i)]),
      ];
      note.textBoxes[2] = [
        TextBoxWidgetModel(
          id: 'b',
          position: const Offset(100, 100),
          initialText: 'on the third page',
          style: const TextBoxStyle(background: Color(0xFFFFF59D)),
        ),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final preview = find.byKey(const ValueKey('page-preview'));
    expect(preview, findsNothing);

    // drag the thumb down through the whole note: the preview shows each page in turn
    final thumb = find.byKey(const ValueKey('page-scrollbar-thumb'));
    final gesture = await tester.startGesture(tester.getCenter(thumb));
    final seenInk = <int>{};
    var sawText = false;
    var sawFill = false;
    for (var i = 0; i < 24; i++) {
      await gesture.moveBy(const Offset(0, 28));
      await tester.pump();
      for (final p in find.descendant(of: preview, matching: find.byType(CustomPaint)).evaluate()) {
        final painter = (p.widget as CustomPaint).painter;
        if (painter is InkLayerPainter && painter.strokes.isNotEmpty) seenInk.add(painter.strokes.length);
      }
      if (find.descendant(of: preview, matching: find.text('on the third page', findRichText: true)).evaluate().isNotEmpty) {
        sawText = true;
        sawFill = find
            .descendant(of: preview, matching: find.byType(Container))
            .evaluate()
            .any((e) => ((e.widget as Container).decoration as BoxDecoration?)?.color?.toARGB32() == 0xF2FFF59D);
      }
    }
    await gesture.up();
    await tester.pump();

    expect(seenInk, containsAll([1, 2]), reason: 'the drawings of page 1 (one stroke) and page 3 (two strokes)');
    expect(sawText, isTrue);
    expect(sawFill, isTrue, reason: 'the text box keeps its background');
  });
}
