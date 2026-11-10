import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/free_transform.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the maths', () {
    const rect = Rect.fromLTWH(100, 100, 200, 100);

    test('a perspective map takes the corners to the corners and keeps straight lines straight', () {
      final quad = [const Offset(120, 110), const Offset(280, 100), const Offset(320, 220), const Offset(90, 200)];
      final h = Homography.rectToQuad(rect, quad)!;
      final corners = quadOf(rect);
      for (var i = 0; i < 4; i++) {
        expect((h.apply(corners[i]) - quad[i]).distance, lessThan(1e-6));
      }
      // three points on a line of the rectangle stay on a line
      final a = h.apply(const Offset(100, 100)), b = h.apply(const Offset(200, 150)), c = h.apply(const Offset(300, 200));
      final cross = (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
      expect(cross.abs(), lessThan(1e-6));
    });

    test('the same corners change nothing; a shape that folds is refused', () {
      final h = Homography.rectToQuad(rect, quadOf(rect))!;
      expect((h.apply(const Offset(170, 140)) - const Offset(170, 140)).distance, lessThan(1e-9));
      final bowtie = [rect.topLeft, rect.bottomRight, rect.topRight, rect.bottomLeft];
      expect(Homography.rectToQuad(rect, bowtie), isNull);
    });

    test('rotation keeps the lengths and turns by the angle', () {
      final q = quadRotated(quadOf(rect), rect.center, math.pi / 2);
      expect((q[1] - q[0]).distance, closeTo(200, 1e-9));
      expect((q[1] - q[0]).direction, closeTo(math.pi / 2, 1e-9));
    });

    test('perspective mirrors a pull, skew only slides along the edge', () {
      final q = quadOf(rect);
      final p = quadPerspective(q, 0, const Offset(30, 4));
      expect(p[0], q[0] + const Offset(30, 4));
      expect(p[1], q[1] + const Offset(-30, 0));
      final s = quadSkewed(q, 0, const Offset(40, 25));
      expect(s[0], q[0] + const Offset(40, 0));
      expect(s[1], q[1] + const Offset(40, 0));
      expect(s[2], q[2]);
      expect(s[3], q[3]);
    });

    test('a warp net in its first places changes nothing, and a moved point is reached exactly', () {
      final g = WarpGrid.identity(rect);
      expect((g.apply(const Offset(133, 177)) - const Offset(133, 177)).distance, lessThan(1e-6));
      g.points[5] = g.points[5] + const Offset(0, 30);
      expect((g.apply(g.homeOf(5)) - g.points[5]).distance, lessThan(1e-6));
      expect((g.apply(rect.topLeft) - rect.topLeft).distance, lessThan(1e-6));
    });

    test('long steps get points to bend, with pressures between theirs', () {
      final r = refinedLine([const Offset(0, 0), const Offset(100, 0)], [0, 100], 10);
      expect(r.points.length, 11);
      expect(r.pressures!.length, 11);
      expect(r.pressures![5], 50);
      expect(r.points.last, const Offset(100, 0));
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<Offset Function(double, double)> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
      return at;
    }

    Future<List<Offset>> saved(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      return (await tester.runAsync(() => repo.loadNote(id)))!.strokes[0]!.single.points;
    }

    Future<void> pull(WidgetTester tester, String key, Offset by) async {
      final from = tester.getCenter(find.byKey(ValueKey(key)));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.touch);
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(from + by * (i / 6));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
    }

    testWidgets('distort pulls a corner, done keeps it, and one step takes it back', (tester) async {
      await open(tester);
      final before = await saved(tester);
      await tester.tap(find.byKey(const ValueKey('transform-selection')));
      await tester.pump();
      expect(find.byKey(const ValueKey('transform-corner-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('resize-br')), findsNothing, reason: 'the transform takes the place of the resize handles');

      await pull(tester, 'transform-corner-2', const Offset(60, 40));
      await tester.tap(find.byKey(const ValueKey('transform-done')));
      await tester.pump();
      expect(find.byKey(const ValueKey('transform-corner-2')), findsNothing);
      final after = await saved(tester);
      expect(after.length, before.length);
      expect(after.first.dx, closeTo(before.first.dx, 0.01), reason: 'the opposite corner stays');
      final far = after.reduce((a, b) => (a.dx + a.dy) > (b.dx + b.dy) ? a : b);
      final was = before.reduce((a, b) => (a.dx + a.dy) > (b.dx + b.dy) ? a : b);
      expect(far.dx, closeTo(was.dx + 60, 1));
      expect(far.dy, closeTo(was.dy + 40, 1));

      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pump();
      final undone = await saved(tester);
      expect(undone.first, before.first);
      expect(undone.last.dx, closeTo(before.last.dx, 1e-6));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('cancel puts the lines back, and rotating turns them about the middle', (tester) async {
      await open(tester);
      final before = await saved(tester);
      await tester.tap(find.byKey(const ValueKey('transform-selection')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('transform-rotate')));
      await tester.pump();
      // the stick is above the top edge: pulling it to the right of the middle turns the drawing clockwise
      await pull(tester, 'transform-rotate-handle', const Offset(120, 40));
      var width = 0.0, minX = 1e9, maxX = -1e9;
      await tester.tap(find.byKey(const ValueKey('transform-done')));
      await tester.pump();
      final after = await saved(tester);
      for (final p in after) {
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
      }
      width = maxX - minX;
      expect(width, isNot(closeTo(76, 1)), reason: 'it was turned');
      // lengths are kept
      final a = (before.first - before.last).distance, b = (after.first - after.last).distance;
      expect(b, closeTo(a, 0.5));

      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pump();
      await tester.tap(find.byType(CustomScrollView), warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('cancel leaves the drawing as it was', (tester) async {
      await open(tester);
      final before = await saved(tester);
      await tester.tap(find.byKey(const ValueKey('transform-selection')));
      await tester.pump();
      await pull(tester, 'transform-corner-0', const Offset(-30, -30));
      await tester.tap(find.byKey(const ValueKey('transform-cancel')));
      await tester.pump();
      final after = await saved(tester);
      expect(after.first, before.first);
      expect(after.last, before.last);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('warp bends the line through new points', (tester) async {
      await open(tester);
      final before = await saved(tester);
      await tester.tap(find.byKey(const ValueKey('transform-selection')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('transform-warp')));
      await tester.pump();
      expect(find.byKey(const ValueKey('transform-net-5')), findsOneWidget);
      await pull(tester, 'transform-net-5', const Offset(0, 25));
      await tester.tap(find.byKey(const ValueKey('transform-done')));
      await tester.pump();
      final after = await saved(tester);
      expect(after.length, greaterThan(before.length), reason: 'the long steps got points to bend');
      expect(after.first.dx, closeTo(before.first.dx, 0.01));
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
