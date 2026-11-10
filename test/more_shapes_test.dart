import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/bezier.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/shapes.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/shortcuts/shortcut_action.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Rect bounds(List<Offset> pts) =>
    Rect.fromLTRB(pts.map((p) => p.dx).reduce(math.min), pts.map((p) => p.dy).reduce(math.min), pts.map((p) => p.dx).reduce(math.max), pts.map((p) => p.dy).reduce(math.max));

double maxGap(List<Offset> pts) {
  var gap = 0.0;
  for (var i = 1; i < pts.length; i++) {
    gap = math.max(gap, (pts[i] - pts[i - 1]).distance);
  }
  return gap;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the new shapes', () {
    const a = Offset(100, 100), b = Offset(340, 260);
    const closedShapes = [
      ShapeTool.roundedRectangle, ShapeTool.rightTriangle, ShapeTool.parallelogram, ShapeTool.pentagon,
      ShapeTool.hexagon, ShapeTool.star, ShapeTool.heart, ShapeTool.cross, ShapeTool.speechBubble,
    ];

    test('each closed shape fills the box between the two points exactly, closes on itself and can be found anywhere on it', () {
      for (final tool in closedShapes) {
        for (final (from, to) in [(a, b), (b, a)]) {
          final pts = shapePoints(tool, from, to);
          final box = Rect.fromPoints(from, to), got = bounds(pts);
          expect([got.left, got.top, got.right, got.bottom], [for (final v in [box.left, box.top, box.right, box.bottom]) closeTo(v, 0.01)], reason: '${tool.name} fills its box');
          expect((pts.first - pts.last).distance, lessThan(0.5), reason: '${tool.name} closes');
          expect(maxGap(pts), lessThanOrEqualTo(6.5), reason: '${tool.name} has a point about every 5 units');
        }
      }
    });

    test('Shift makes a closed shape\'s box a square', () {
      for (final tool in closedShapes) {
        final box = bounds(shapePoints(tool, a, b, constrain: true));
        expect(box.width, closeTo(box.height, 0.01), reason: tool.name);
      }
    });

    test('the double arrow has a head at each end, and a line (Shift: 45 degrees) goes level or at 45', () {
      final pts = shapePoints(ShapeTool.doubleArrow, const Offset(100, 100), const Offset(400, 100));
      expect(pts.where((p) => (p - const Offset(100, 100)).distance < 0.01).length, greaterThanOrEqualTo(2), reason: 'the path is at the start twice, between the barbs');
      expect(pts.where((p) => (p - const Offset(400, 100)).distance < 0.01).length, greaterThanOrEqualTo(2));
      final box = bounds(pts);
      expect(box.left, closeTo(100, 0.01), reason: 'the start is the tip of one head');
      expect(box.right, closeTo(400, 0.01), reason: 'the end the tip of the other');
      expect(box.height, greaterThan(10), reason: 'the barbs of both heads go to the sides');
      // Shift: the line goes level (30 is nearer 0 degrees than 45)
      final level = shapePoints(ShapeTool.doubleArrow, const Offset(0, 0), const Offset(100, 20), constrain: true);
      expect(level.any((p) => (p - Offset(math.sqrt(100 * 100 + 20 * 20), 0)).distance < 0.01), isTrue, reason: 'the tip is as far as the pen, along 0 degrees');
    });

    test('the pen for curves has nothing to drag out, and every shape is named for the menu and a shortcut', () {
      expect(shapePoints(ShapeTool.bezier, a, b), isNotEmpty);
      final actions = {for (final s in shortcutActions(mac: false)) s.id};
      for (final tool in ShapeTool.values) {
        expect(actions, contains('shape.${tool.name}'), reason: '${tool.name} can be chosen by a shortcut');
        expect(tool.label, isNotEmpty);
      }
    });
  });

  group('a curved path', () {
    test('without handles it is straight, with them it bends, and its points are close enough to be found', () {
      final straight = CurvedPath([PathNode(const Offset(0, 0)), PathNode(const Offset(100, 0))]);
      expect(straight.points().every((p) => p.dy == 0), isTrue);
      expect(maxGap(straight.points()), lessThanOrEqualTo(4.01));
      final bent = CurvedPath([PathNode(const Offset(0, 0))..pullOut(const Offset(0, 60)), PathNode(const Offset(100, 0))..pullIn(const Offset(100, 60))]);
      final pts = bent.points();
      expect(pts.first, const Offset(0, 0));
      expect(pts.last, const Offset(100, 0));
      expect(bounds(pts).height, greaterThan(30), reason: 'it leaves along the handle, so it bulges');
      expect(maxGap(pts), lessThanOrEqualTo(4.01));
    });

    test('pulling a handle pulls the other the opposite way, and a corner has none', () {
      final n = PathNode(const Offset(50, 50))..pullOut(const Offset(70, 60));
      expect(n.inn, const Offset(30, 40));
      n.pullIn(const Offset(40, 50));
      expect(n.out, const Offset(60, 50));
      n.sharpen();
      expect(n.smooth, isFalse);
      final moved = PathNode(const Offset(0, 0), out: const Offset(10, 0))..moveBy(const Offset(5, 5));
      expect((moved.at, moved.out), (const Offset(5, 5), const Offset(15, 5)));
    });

    test('closed, it comes back to its first point; and what is touched is the handle first, then the nearest point', () {
      final p = CurvedPath([PathNode(const Offset(0, 0)), PathNode(const Offset(100, 0)), PathNode(const Offset(50, 80))], true);
      expect(p.points().last, const Offset(0, 0));
      final open = CurvedPath([PathNode(const Offset(0, 0)), PathNode(const Offset(100, 0))]);
      expect(open.points(to: const Offset(100, 100)).last, const Offset(100, 100));
      final h = CurvedPath([PathNode(const Offset(0, 0), out: const Offset(10, 0)), PathNode(const Offset(40, 0))]);
      expect(h.hit(const Offset(12, 0), 5)!.part, PathPart.out, reason: 'a handle is taken before a point');
      expect(h.hit(const Offset(38, 0), 5)!.node, 1);
    });

    test('nothing is near: no hit', () {
      final p = CurvedPath([PathNode(const Offset(0, 0))]);
      expect(p.hit(const Offset(100, 100), 14), isNull);
      expect(p.hit(const Offset(5, 5), 14)!.part, PathPart.point);
    });
  });

  testWidgets('the pen for curves: points are put one by one, a drag bends the line, a tap on the first point closes it', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('shape-tool')));
    await tester.tap(find.byKey(const ValueKey('shape-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shape-bezier')));
    await tester.pumpAndSettle();

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    Future<void> tap(Offset at) async {
      final g = await tester.createGesture();
      await g.down(origin + at);
      await g.up();
      await tester.pump();
    }

    Future<void> pull(Offset at, Offset to) async {
      final g = await tester.createGesture();
      await g.down(origin + at);
      await tester.pump(); // (the page stops scrolling with the pen down, as it does between two events on a device)
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(origin + Offset.lerp(at, to, i / 8)!);
      }
      await g.up();
      await tester.pump();
    }

    // nothing is drawn until the line is finished: only its points show
    await tap(const Offset(100, 300));
    expect(find.byKey(const ValueKey('pen-path')), findsOneWidget);
    expect(strokes(), isEmpty);
    await pull(const Offset(300, 300), const Offset(360, 200)); // a point with its handle pulled: smooth
    await tap(const Offset(500, 400)); // a corner
    expect(find.byKey(const ValueKey('pen-done')), findsOneWidget);
    // a tap on the last point finishes the line
    await tap(const Offset(500, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pen-path')), findsNothing);
    final open = strokes().single;
    expect(open.points.first, const Offset(100, 300));
    expect(open.points.last, const Offset(500, 400));
    expect(bounds(open.points).top, lessThan(290), reason: 'the pulled handle bent the line upward');
    expect(open.fill, isNull);

    // a second one, closed by a tap on its first point
    await tap(const Offset(600, 600));
    await tap(const Offset(800, 600));
    await tap(const Offset(700, 750));
    await tap(const Offset(600, 600));
    await tester.pumpAndSettle();
    expect(strokes().length, 2);
    final closed = strokes().last;
    expect((closed.points.first - closed.points.last).distance, lessThan(0.5));
    expect(find.byKey(const ValueKey('pen-path')), findsNothing);

    // the buttons: a point is taken back, the line dropped
    await tap(const Offset(100, 700));
    await tap(const Offset(200, 700));
    await tester.tap(find.byKey(const ValueKey('pen-undo-point')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pen-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pen-path')), findsNothing);
    expect(strokes().length, 2);

    // and "close the shape" finishes a line of three points as a closed one
    await tap(const Offset(100, 500));
    await tap(const Offset(250, 500));
    await tap(const Offset(180, 560));
    await tester.tap(find.byKey(const ValueKey('pen-close')));
    await tester.pumpAndSettle();
    expect(strokes().length, 3);
    expect((strokes().last.points.first - strokes().last.points.last).distance, lessThan(0.5));

    // each line is a step to take back
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect(strokes().length, 2);

    // putting the pen down (another mode) finishes a line in hand instead of losing it
    await tap(const Offset(100, 100));
    await tap(const Offset(200, 120));
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pen-path')), findsNothing);
    expect(strokes().length, 3);
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
  });
}
