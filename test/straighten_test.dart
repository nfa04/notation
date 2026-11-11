import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/shapes.dart';
import 'package:notes/models/straighten.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'close_editor.dart';

/// A hand-drawn line from [a] to [b], with some shake of up to [shake] units.
List<Offset> hand(Offset a, Offset b, {double shake = 2, int n = 40}) {
  final rnd = math.Random(3);
  return [
    for (var i = 0; i <= n; i++)
      Offset.lerp(a, b, i / n)! + Offset((rnd.nextDouble() - 0.5) * shake, (rnd.nextDouble() - 0.5) * shake),
  ];
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('what counts as a line', () {
    test('a shaky line becomes a straight one between its ends', () {
      final pts = hand(const Offset(100, 100), const Offset(400, 260));
      final line = straightLine(pts)!;
      expect(line.first, pts.first);
      expect(line.last, pts.last);
      final dir = (line.last - line.first) / (line.last - line.first).distance;
      for (final p in line) {
        final v = p - line.first;
        expect((v.dx * dir.dy - v.dy * dir.dx).abs(), lessThan(1e-6)); // all on one line
      }
    });

    test('a nearly horizontal one is made horizontal, a nearly vertical one vertical', () {
      final h = straightLine(hand(const Offset(100, 100), const Offset(400, 112)))!;
      expect(h.map((p) => p.dy).toSet().length, 1);
      expect(h.first.dx, closeTo(100, 3));
      expect(h.last.dx, closeTo(400, 3));
      final v = straightLine(hand(const Offset(100, 100), const Offset(110, 400)))!;
      expect(v.map((p) => p.dx).toSet().length, 1);
      // 30 degrees stays slanted
      final slanted = straightLine(hand(const Offset(100, 100), const Offset(360, 250), shake: 0))!;
      expect(slanted.first.dy, isNot(slanted.last.dy));
      expect(slanted.first.dx, isNot(slanted.last.dx));
    });

    test('the line is dense enough for the eraser to find it anywhere', () {
      final line = straightLine(hand(const Offset(0, 0), const Offset(300, 0)))!;
      for (var i = 1; i < line.length; i++) {
        expect((line[i] - line[i - 1]).distance, lessThanOrEqualTo(6.01));
      }
    });

    test('anything else is left as drawn', () {
      // a curve
      expect(straightLine([for (var i = 0; i <= 40; i++) Offset(100.0 + i * 8, 200 + 60 * math.sin(i / 40 * math.pi))]), isNull);
      // a circle
      expect(straightLine([for (var i = 0; i <= 40; i++) Offset(200 + 80 * math.cos(i / 40 * 2 * math.pi), 200 + 80 * math.sin(i / 40 * 2 * math.pi))]), isNull);
      // a zigzag
      expect(straightLine([for (var i = 0; i <= 40; i++) Offset(100.0 + i * 8, i.isEven ? 100 : 130)]), isNull);
      // out and back
      expect(straightLine([for (var i = 0; i <= 20; i++) Offset(100.0 + i * 10, 100), for (var i = 20; i >= 0; i--) Offset(100.0 + i * 10, 102)]), isNull);
      // a dot
      expect(straightLine(hand(const Offset(100, 100), const Offset(104, 100), n: 6)), isNull);
      expect(straightLine(const [Offset(1, 1), Offset(2, 2)]), isNull);
    });
  });

  testWidgets('a line drawn with the pen comes out straight, and can be left alone', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
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

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    Future<void> draw(List<Offset> pts) async {
      final g = await tester.createGesture();
      await g.down(origin + pts.first);
      for (final p in pts.skip(1)) {
        await g.moveTo(origin + p);
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    // a bit slanted and shaky: it comes out flat
    await draw(hand(const Offset(100, 300), const Offset(500, 310)));
    expect(strokes().length, 1);
    expect(strokes().single.points.map((p) => p.dy).toSet().length, 1);

    // a rough rectangle becomes the rectangle of the shape tool (closed, with straight sides), a squiggle stays
    final rough = shapePoints(ShapeTool.rectangle, const Offset(150, 500), const Offset(450, 700), step: 6);
    final rnd = math.Random(8);
    await draw([for (final p in rough) p + Offset((rnd.nextDouble() - 0.5) * 3, (rnd.nextDouble() - 0.5) * 3)]);
    expect(strokes().length, 2);
    final box = strokes().last;
    expect(box.points.map((p) => p.dx.round()).toSet(), containsAll([box.points.map((p) => p.dx).reduce(math.min).round(), box.points.map((p) => p.dx).reduce(math.max).round()]));
    expect(box.points.where((p) => (p.dx - box.points.first.dx).abs() < 0.01 || (p.dy - box.points.first.dy).abs() < 0.01).length, greaterThan(10)); // (along the sides)
    expect(box.isClosed, isTrue);

    // switched off, the next one stays as drawn
    await tester.ensureVisible(find.byKey(const ValueKey('straighten-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('straighten-toggle')));
    await tester.pumpAndSettle();
    await draw(hand(const Offset(100, 800), const Offset(500, 810)));
    expect(strokes().length, 3);
    expect(strokes().last.points.map((p) => p.dy).toSet().length, greaterThan(1));
    expect(await tester.runAsync(() => repo.settings.get('straighten_lines')), '0');
    await closeEditor(tester);
  });
}
