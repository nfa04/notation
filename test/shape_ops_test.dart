import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/shape_ops.dart';
import 'package:notes/models/shapes.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

double area(List<Offset> pts) {
  var sum = 0.0;
  for (var i = 0; i + 1 < pts.length; i++) {
    sum += pts[i].dx * pts[i + 1].dy - pts[i + 1].dx * pts[i].dy;
  }
  return sum.abs() / 2;
}

List<Offset> rect(double l, double t, double r, double b) => shapePoints(ShapeTool.rectangle, Offset(l, t), Offset(r, b));

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('putting shapes together', () {
    final a = rect(0, 0, 100, 100), b = rect(50, 50, 150, 150);

    test('union is both, the overlap is the part they share, subtracting takes the second out of the first', () {
      expect(combineShapes([a, b], ShapeOp.union).map(area).first, closeTo(100 * 100 * 2 - 50 * 50, 60));
      expect(combineShapes([a, b], ShapeOp.intersect).single.map((p) => p.dx).reduce((x, y) => x < y ? x : y), closeTo(50, 0.01));
      expect(area(combineShapes([a, b], ShapeOp.intersect).single), closeTo(50 * 50, 30));
      expect(area(combineShapes([a, b], ShapeOp.subtract).single), closeTo(100 * 100 - 50 * 50, 60));
      expect(combineShapes([a, b], ShapeOp.exclude).length, 2, reason: 'the two corners that are left are two outlines');
    });

    test('a shape cut out of the middle leaves a ring: two outlines, the outer first, and a point inside the hole is inside the outer only', () {
      final ring = combineShapes([rect(0, 0, 200, 200), rect(60, 60, 140, 140)], ShapeOp.subtract);
      expect(ring.length, 2);
      expect(area(ring.first), greaterThan(area(ring.last)));
      expect(insideOutline(ring.first, const Offset(100, 100)), isTrue);
      expect(insideOutline(ring.last, const Offset(100, 100)), isTrue);
      expect(insideOutline(ring.last, const Offset(30, 30)), isFalse);
    });

    test('outlines are closed, close together, and what is not a shape is left out', () {
      final r = combineShapes([a, b], ShapeOp.union).single;
      expect(r.first, r.last);
      for (var i = 1; i < r.length; i++) {
        expect((r[i] - r[i - 1]).distance, lessThan(5));
      }
      expect(combineShapes(const [], ShapeOp.union), isEmpty);
      expect(combineShapes([const [Offset(0, 0), Offset(1, 1)]], ShapeOp.union), isEmpty);
      expect(combineShapes([a, rect(300, 300, 400, 400)], ShapeOp.intersect), isEmpty, reason: 'nothing shared');
    });
  });

  testWidgets('two selected shapes are joined into one, which can be taken back', (tester) async {
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
        DrawingStroke(color: Colors.red, width: 3, points: rect(100, 150, 250, 300), fill: Colors.yellow),
        DrawingStroke(color: Colors.blue, width: 3, points: rect(200, 250, 350, 400)),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final lasso = await tester.startGesture(at(60, 100), kind: PointerDeviceKind.touch);
    for (final p in [at(60, 100), at(420, 100), at(420, 460), at(60, 460), at(60, 105)]) {
      await lasso.moveTo(p);
      await tester.pump();
    }
    await lasso.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('combine-shapes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('combine-union')));
    await tester.pumpAndSettle();
    final joined = strokes();
    expect(joined.length, 1);
    expect(joined.single.color.toARGB32(), Colors.red.toARGB32(), reason: 'the look of the lowest');
    expect(joined.single.fill?.toARGB32(), Colors.yellow.toARGB32());
    expect(area(joined.single.points), closeTo(150 * 150 * 2 - 50 * 50, 150));

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect(strokes().length, 2);
    expect(strokes().first.color.toARGB32(), Colors.red.toARGB32());
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  });
}
