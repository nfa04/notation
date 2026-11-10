import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/shapes.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Matcher closeTo2(double v) => closeTo(v, 1e-6);

double maxGap(List<Offset> pts) {
  var gap = 0.0;
  for (var i = 1; i < pts.length; i++) {
    gap = math.max(gap, (pts[i] - pts[i - 1]).distance);
  }
  return gap;
}

Rect bounds(List<Offset> pts) =>
    Rect.fromLTRB(pts.map((p) => p.dx).reduce(math.min), pts.map((p) => p.dy).reduce(math.min), pts.map((p) => p.dx).reduce(math.max), pts.map((p) => p.dy).reduce(math.max));

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the shapes', () {
    const a = Offset(100, 100), b = Offset(300, 220);

    test('a line goes straight from one end to the other, densely', () {
      final pts = shapePoints(ShapeTool.line, a, b);
      expect((pts.first, pts.last), (a, b));
      expect(maxGap(pts), lessThanOrEqualTo(5.01)); // the eraser can find it anywhere
      final d = (b - a) / (b - a).distance;
      for (final p in pts) {
        final v = p - a;
        expect((v.dx * d.dy - v.dy * d.dx).abs(), lessThan(1e-6));
      }
    });

    test('a rectangle is closed and fills the box between the two points, whichever way it is dragged', () {
      for (final (from, to) in [(a, b), (b, a), (const Offset(300, 100), const Offset(100, 220))]) {
        final pts = shapePoints(ShapeTool.rectangle, from, to);
        expect(pts.first, pts.last); // it closes
        final box = Rect.fromPoints(from, to), got = bounds(pts);
        expect([got.left, got.top, got.right, got.bottom], [for (final v in [box.left, box.top, box.right, box.bottom]) closeTo2(v)]);
        expect(maxGap(pts), lessThanOrEqualTo(5.01));
        // every point is on the outline
        final r = Rect.fromPoints(from, to);
        for (final p in pts) {
          final onEdge = (p.dx - r.left).abs() < 1e-6 || (p.dx - r.right).abs() < 1e-6 || (p.dy - r.top).abs() < 1e-6 || (p.dy - r.bottom).abs() < 1e-6;
          expect(onEdge, isTrue);
        }
      }
    });

    test('an ellipse touches the middle of each side of its box and is closed', () {
      final pts = shapePoints(ShapeTool.ellipse, a, b);
      expect(bounds(pts).left, closeTo(100, 0.01));
      expect(bounds(pts).right, closeTo(300, 0.01));
      expect(bounds(pts).top, closeTo(100, 0.01));
      expect(bounds(pts).bottom, closeTo(220, 0.01));
      expect((pts.first - pts.last).distance, lessThan(1e-6));
      expect(maxGap(pts), lessThanOrEqualTo(6)); // dense enough even for a big one
      expect(maxGap(shapePoints(ShapeTool.ellipse, const Offset(0, 0), const Offset(900, 600))), lessThanOrEqualTo(6));
      // a point on the ellipse satisfies its equation
      for (final p in pts) {
        final x = (p.dx - 200) / 100, y = (p.dy - 160) / 60;
        expect(x * x + y * y, closeTo(1, 1e-6));
      }
    });

    test('an arrow ends in its head: tail, tip and two barbs', () {
      final pts = shapePoints(ShapeTool.arrow, a, b);
      expect(pts.first, a);
      final tipIndex = pts.indexWhere((p) => (p - b).distance < 1e-6);
      expect(tipIndex, greaterThan(0)); // the shaft reaches the tip
      // after the tip the line goes back along the barbs: it comes back to the tip and ends on the other barb
      final tips = pts.where((p) => (p - b).distance < 1e-6).length;
      expect(tips, 2);
      final barb = pts.last;
      expect((barb - b).distance, closeTo(24, 1)); // a barb is about 24 long on a long arrow
      expect(maxGap(pts), lessThanOrEqualTo(5.01));
      // a short arrow has a short head
      final small = shapePoints(ShapeTool.arrow, const Offset(0, 0), const Offset(30, 0));
      expect((small.last - const Offset(30, 0)).distance, lessThan(12));
    });

    test('Shift: lines go along 45 degree steps, rectangles and ellipses are even', () {
      final line = shapePoints(ShapeTool.line, const Offset(0, 0), const Offset(200, 30), constrain: true);
      expect(line.last.dy, closeTo(0, 1e-6)); // nearest of 0, 45, 90...: flat
      final diagonal = shapePoints(ShapeTool.line, const Offset(0, 0), const Offset(150, 120), constrain: true);
      expect(diagonal.last.dx, closeTo(diagonal.last.dy, 1e-6));
      expect(diagonal.last.distance, closeTo(const Offset(150, 120).distance, 1e-6)); // as long as it was pulled
      final square = shapePoints(ShapeTool.rectangle, const Offset(100, 100), const Offset(250, 160), constrain: true);
      expect(bounds(square).width, bounds(square).height);
      final up = shapePoints(ShapeTool.ellipse, const Offset(100, 100), const Offset(40, 20), constrain: true);
      expect(bounds(up).width, closeTo(bounds(up).height, 1e-6));
      expect(bounds(up).bottom, closeTo(100, 1e-6)); // it grows the way it was pulled
    });

    test('a point and a tiny drag do not break anything', () {
      for (final tool in ShapeTool.values) {
        expect(shapePoints(tool, const Offset(5, 5), const Offset(5, 5)), isNotEmpty);
        expect(shapePoints(tool, const Offset(5, 5), const Offset(5.2, 5.2)), isNotEmpty);
      }
    });
  });

  testWidgets('with a shape chosen the pen draws that shape, which can be taken back; freehand stays the default', (tester) async {
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
    Future<void> drag(Offset from, Offset to, {int steps = 12}) async {
      final g = await tester.createGesture();
      await g.down(origin + from);
      for (var i = 1; i <= steps; i++) {
        await g.moveTo(origin + Offset.lerp(from, to, i / steps)!);
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    Future<void> choose(ShapeTool tool) async {
      await tester.ensureVisible(find.byKey(const ValueKey('shape-tool')));
      await tester.tap(find.byKey(const ValueKey('shape-tool')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shape-${tool.name}')));
      await tester.pumpAndSettle();
    }

    // by default the pen draws what the hand does: an L stays an L
    Future<void> corner(Offset at) async {
      final g = await tester.createGesture();
      await g.down(origin + at);
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(origin + at + Offset(25.0 * i, 0));
      }
      for (var i = 1; i <= 4; i++) {
        await g.moveTo(origin + at + Offset(200, 20.0 * i));
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    await corner(const Offset(100, 100));
    expect(strokes().single.points.any((p) => (p - const Offset(300, 100)).distance < 1), isTrue);

    await choose(ShapeTool.rectangle);
    await drag(const Offset(100, 300), const Offset(400, 450));
    var shape = strokes().last;
    expect(shape.points.first, shape.points.last);
    expect([bounds(shape.points).left, bounds(shape.points).top, bounds(shape.points).right, bounds(shape.points).bottom], [100, 300, 400, 450].map((v) => closeTo(v, 0.01)).toList());

    // the shape follows the pen while it is held, so only the end counts: a wobbly drag gives a clean rectangle
    final g = await tester.createGesture();
    await g.down(origin + const Offset(500, 300));
    await g.moveTo(origin + const Offset(700, 500));
    await g.moveTo(origin + const Offset(650, 350));
    await g.moveTo(origin + const Offset(600, 400));
    await g.up();
    await tester.pumpAndSettle();
    final wobbly = bounds(strokes().last.points);
    expect([wobbly.left, wobbly.top, wobbly.right, wobbly.bottom], [500, 300, 600, 400].map((v) => closeTo(v, 0.01)).toList());

    // Shift makes it even
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await choose(ShapeTool.ellipse);
    await drag(const Offset(100, 600), const Offset(300, 650));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    final circle = bounds(strokes().last.points);
    expect(circle.width, closeTo(circle.height, 0.5));

    // an arrow and a line
    await choose(ShapeTool.arrow);
    await drag(const Offset(400, 700), const Offset(700, 760));
    await choose(ShapeTool.line);
    await drag(const Offset(400, 800), const Offset(700, 800));
    expect(strokes().length, 6);
    expect(strokes().last.points.map((p) => p.dy.toStringAsFixed(3)).toSet().length, 1); // dead level

    // each is one step to take back
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes().length, 5);
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes().length, 4);

    // the eraser finds a shape anywhere along it
    await tester.tap(find.byTooltip('Eraser (drawings only)'));
    await tester.pumpAndSettle();
    final eraser = await tester.createGesture();
    await eraser.down(origin + const Offset(250, 300)); // on the top edge of the first rectangle
    await eraser.up();
    await tester.pumpAndSettle();
    expect(strokes().length, 3);

    // back to the hand's own line
    await tester.tap(find.byTooltip('Eraser (drawings only)')); // the eraser off again
    await tester.pumpAndSettle();
    await choose(ShapeTool.freehand);
    await corner(const Offset(100, 850)); // (lower down the bottom toolbar covers the page)
    expect(strokes().last.points.any((p) => (p - const Offset(300, 850)).distance < 8), isTrue);
  });
}
