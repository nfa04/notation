import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/canvas_view.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke _line(Offset from, Offset to, {double width = 4}) => DrawingStroke(color: Colors.black, width: width, points: [from, to]);

/// A finger that goes down at [from] and moves by [by] in small steps (the first ones are the slop, which moves nothing).
Future<void> _drag(WidgetTester tester, Offset from, Offset by) async {
  final g = await tester.startGesture(from);
  for (var i = 1; i <= 20; i++) {
    await g.moveTo(from + by * (i / 20));
    await tester.pump(const Duration(milliseconds: 10));
  }
  await g.up();
  await tester.pump();
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('what is on a canvas', () {
    test('the bounds hold the strokes (with their width), the boxes and the pictures', () {
      expect(canvasContentBounds(), isNull);
      final bounds = canvasContentBounds(
        strokes: [_line(const Offset(100, 200), const Offset(300, 250))],
        boxes: [TextBoxWidgetModel(id: 'b', position: const Offset(400, 100), size: const Size(200, 0))],
      )!;
      expect(bounds.left, 98);
      expect(bounds.top, 100);
      expect(bounds.right, 600);
      expect(bounds.bottom, 252); // (the box is at least 40 high; the stroke goes to 250 and is 4 wide)
    });

    test('the window on a canvas is the bounds with room round them, in the proportions asked for', () {
      final empty = canvasWindow(null);
      expect(empty.contains(canvasOrigin + const Offset(100, 100)), isTrue);
      final w = canvasWindow(const Rect.fromLTWH(1000, 1000, 2000, 100), aspect: 0.75);
      expect(w.height / w.width, closeTo(0.75, 1e-9));
      expect(w.contains(const Offset(1000, 1050)), isTrue);
      expect(w.contains(const Offset(3000, 1050)), isTrue);
    });

    test('a turn of the view is put in one round and settles on a quarter turn it is near', () {
      expect(settledTurn(0.03), 0.0, reason: 'under 4 degrees from straight');
      expect(settledTurn(-0.03), 0.0);
      expect(settledTurn(0.3), closeTo(0.3, 1e-12));
      expect(settledTurn(math.pi / 2 + 0.05), closeTo(math.pi / 2, 1e-12));
      expect(settledTurn(2 * math.pi + 0.3), closeTo(0.3, 1e-9), reason: 'a whole turn more is the same view');
      expect(settledTurn(-math.pi + 0.02), closeTo(math.pi, 1e-12), reason: 'upside down is one number');
      final v = turnedBy(const Offset(1, 0), math.pi / 2);
      expect(v.dx, closeTo(0, 1e-12));
      expect(v.dy, closeTo(1, 1e-12), reason: 'a quarter turn clockwise on the screen (y goes down)');
      expect(turnedBy(turnedBy(const Offset(3, 4), 0.7), -0.7).dx, closeTo(3, 1e-12));
    });

    test('the infinite canvas is not one of the papers', () {
      expect(PageFormat.papers, isNot(contains(PageFormat.infinite)));
      expect(PageFormat.infinite.isInfinite, isTrue);
      expect(PageFormat.a4.isInfinite, isFalse);
    });
  });

  testWidgets('a canvas note is saved as one, with what was put anywhere on it', (tester) async {
    await tester.runAsync(() async {
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pageFormat = PageFormat.infinite;
      note.strokes[0] = [_line(canvasOrigin - const Offset(30000, 20000), canvasOrigin + const Offset(40000, 10))];
      await repo.saveNote(note);
      final back = (await repo.loadNote(id))!;
      expect(back.pageFormat, PageFormat.infinite);
      expect(back.strokes[0]!.single.points.first, canvasOrigin - const Offset(30000, 20000));
    });
  });

  group('the editor', () {
    late NoteRepository repo;
    late String id;

    Future<void> open(WidgetTester tester, {bool canvas = true}) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote(title: 'Canvas');
        final note = (await repo.loadNote(id))!;
        if (canvas) note.pageFormat = PageFormat.infinite;
        note.textBoxes[0] = [
          TextBoxWidgetModel(id: 'b', position: canvas ? canvasOrigin + const Offset(100, 100) : const Offset(100, 100), initialText: 'hello canvas'),
        ];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    }

    testWidgets('has no pages and no PDF', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('canvas-fit')), findsOneWidget);
      expect(find.byKey(const ValueKey('pages-menu')), findsNothing);
      expect(find.text('Export PDF'), findsNothing);
      expect(find.text('Import PDF'), findsNothing);
      expect(find.byTooltip('Page size'), findsNothing);
      expect(find.byType(CustomScrollView), findsNothing);
      await close(tester);
    });

    testWidgets('a notebook still has its pages and the PDF', (tester) async {
      await open(tester, canvas: false);
      expect(find.byKey(const ValueKey('canvas-fit')), findsNothing);
      expect(find.byKey(const ValueKey('pages-menu')), findsOneWidget);
      expect(find.text('Export PDF'), findsOneWidget);
      await close(tester);
    });

    testWidgets('starts at what is on it, and the wheel moves it', (tester) async {
      await open(tester);
      final box = find.text('hello canvas');
      expect(box, findsOneWidget);
      final before = tester.getTopLeft(box);
      expect(before.dy, lessThan(300)); // (in view without scrolling to it)

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(700, 400)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
      await tester.pump();
      expect(tester.getTopLeft(box).dy, closeTo(before.dy - 100, 0.5)); // sideways too
      await tester.sendEventToBinding(mouse.scroll(const Offset(60, 0)));
      await tester.pump();
      expect(tester.getTopLeft(box).dx, closeTo(before.dx - 60, 0.5));
      await close(tester);
    });

    testWidgets('two fingers on a trackpad move it in every direction', (tester) async {
      await open(tester);
      final box = find.text('hello canvas');
      final before = tester.getTopLeft(box);
      final pad = TestPointer(2, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.panZoomStart(const Offset(700, 400)));
      await tester.sendEventToBinding(pad.panZoomUpdate(const Offset(700, 400), pan: const Offset(-50, -30)));
      await tester.sendEventToBinding(pad.panZoomUpdate(const Offset(700, 400), pan: const Offset(-80, -30)));
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();
      expect(tester.getTopLeft(box).dx, closeTo(before.dx - 80, 0.5));
      expect(tester.getTopLeft(box).dy, closeTo(before.dy - 30, 0.5));
      await close(tester);
    });

    testWidgets('Ctrl and the wheel zoom around the pointer, and the button shows everything again', (tester) async {
      await open(tester);
      final box = find.text('hello canvas');
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(700, 400)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -200)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('165%'), findsOneWidget);
      expect(tester.getSize(box).width, greaterThan(40));

      await tester.tap(find.byKey(const ValueKey('canvas-fit')));
      await tester.pump();
      expect(find.text('165%'), findsNothing); // (all of it fits at the normal size, which is as far as it zooms in)
      expect(tester.getTopLeft(box).dy, inInclusiveRange(0, 900));
      await close(tester);
    });

    testWidgets('the buttons zoom without a wheel or fingers, and the lock stops them', (tester) async {
      await open(tester);
      final box = find.text('hello canvas');
      double shown() => tester.getBottomRight(box).dx - tester.getTopLeft(box).dx; // (on the screen, not the size it is laid out at)
      final width = shown();
      await tester.tap(find.byKey(const ValueKey('zoom-in')));
      await tester.pump();
      expect(shown(), closeTo(width * 1.25, 1));
      await tester.tap(find.byKey(const ValueKey('zoom-out')));
      await tester.tap(find.byKey(const ValueKey('zoom-out')));
      await tester.pump();
      expect(shown(), closeTo(width / 1.25, 1));
      await tester.tap(find.byKey(const ValueKey('zoom-lock')));
      await tester.pump();
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('zoom-in'))).onPressed, isNull);
      await close(tester);
    });

    testWidgets('a finger drags the canvas along, and two fingers pinch it', (tester) async {
      await open(tester);
      final box = find.text('hello canvas');
      final before = tester.getTopLeft(box);
      await _drag(tester, const Offset(300, 700), const Offset(-120, -200));
      final after = tester.getTopLeft(box);
      expect(after.dx, lessThan(before.dx - 30));
      expect(after.dy, lessThan(before.dy - 60));

      final a = await tester.startGesture(const Offset(600, 500));
      final b = await tester.startGesture(const Offset(700, 500));
      await tester.pump();
      await a.moveTo(const Offset(500, 500));
      await b.moveTo(const Offset(800, 500));
      await tester.pump();
      expect(find.textContaining('%'), findsOneWidget); // (zoomed away from 100%)
      await a.up();
      await b.up();
      await tester.pump(const Duration(seconds: 1));
      await close(tester);
    });

    testWidgets('two fingers turn the canvas about where they are, and the button puts it straight', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('canvas-straighten')), findsNothing);
      final box = find.text('hello canvas');
      final a = await tester.startGesture(const Offset(600, 500));
      final b = await tester.startGesture(const Offset(800, 500));
      await tester.pump();
      // (the second finger goes round the first by about 30 degrees, in steps)
      for (var i = 1; i <= 10; i++) {
        final t = i / 10 * math.pi / 6;
        await b.moveTo(const Offset(600, 500) + Offset(math.cos(t), math.sin(t)) * 200);
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('canvas-straighten')), findsOneWidget);
      expect(find.textContaining('°'), findsOneWidget);
      final turned = tester.getRect(box);
      expect(turned.height, greaterThan(40), reason: 'the line of text stands at a slant, so its box on the screen is taller');

      await tester.tap(find.byKey(const ValueKey('canvas-straighten')));
      await tester.pump();
      expect(find.byKey(const ValueKey('canvas-straighten')), findsNothing);
      expect(tester.getRect(box).height, lessThan(turned.height));
      await close(tester);
    });

    testWidgets('a quarter turn with the keys: the pen draws where it is on the turned canvas', (tester) async {
      await open(tester);
      await tester.ensureVisible(find.text('Draw'));
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight); // (6 steps of 15 degrees)
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('90°'), findsOneWidget);

      // to the right on the screen is up on a canvas turned a quarter clockwise
      final start = const Offset(500, 400);
      final g = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(start + Offset(i * 20.0, 0));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      final points = (await tester.runAsync(() => repo.loadNote(id)))!.strokes[0]!.single.points;
      expect((points.last.dx - points.first.dx).abs(), lessThan(2));
      expect(points.first.dy - points.last.dy, closeTo(200, 2), reason: '200 px at 100 %');
      await close(tester);
    });

    testWidgets('the mouse drags the canvas in every direction while selecting, and draws instead with the pen', (tester) async {
      await open(tester);
      final box = find.text('hello canvas');
      final before = tester.getTopLeft(box);
      final g = await tester.startGesture(const Offset(300, 700), kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 20; i++) {
        await g.moveTo(const Offset(300, 700) + const Offset(-120, -200) * (i / 20));
        await tester.pump(const Duration(milliseconds: 10));
      }
      await g.up();
      await tester.pump();
      expect(tester.getTopLeft(box).dx, lessThan(before.dx - 30));
      expect(tester.getTopLeft(box).dy, lessThan(before.dy - 60));

      await tester.ensureVisible(find.text('Draw'));
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      final still = tester.getTopLeft(box);
      final d = await tester.startGesture(const Offset(300, 700), kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 20; i++) {
        await d.moveTo(const Offset(300, 700) + const Offset(100, -100) * (i / 20));
        await tester.pump(const Duration(milliseconds: 10));
      }
      await d.up();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getTopLeft(box), still);
      await close(tester);
    });

    testWidgets('a double tap makes a text box where the finger is on the canvas', (tester) async {
      await open(tester);
      await _drag(tester, const Offset(300, 700), const Offset(0, -300));
      const at = Offset(700, 600);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      final saved = await tester.runAsync(() => repo.loadNote(id));
      final boxes = saved!.textBoxes[0]!;
      expect(boxes, hasLength(2));
      final made = boxes.firstWhere((b) => b.id != 'b');
      expect(made.position.dx, closeTo(canvasOrigin.dx + 60 + 700, 10)); // (the window starts 40 before the first box, which is 100 in)
      expect(made.position.dy, inInclusiveRange(canvasOrigin.dy + 800, canvasOrigin.dy + 900));
      await close(tester);
    });

    testWidgets('a notebook becomes a canvas from the list of page sizes, its first page moving to the middle', (tester) async {
      await open(tester, canvas: false);
      await tester.ensureVisible(find.byTooltip('Page size')); // (the toolbar scrolls sideways)
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Page size'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-size-infinite')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('make-canvas')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('canvas-fit')), findsOneWidget);
      expect(find.text('Export PDF'), findsNothing);
      expect(find.text('hello canvas'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('undo-any'))).onPressed, isNull);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      final saved = await tester.runAsync(() => repo.loadNote(id));
      expect(saved!.pageFormat, PageFormat.infinite);
      expect(saved.textBoxes[0]!.single.position, canvasOrigin + const Offset(100, 100));
      await close(tester);
    });

    testWidgets('writes where the pen is on the surface, far from the corner of the page', (tester) async {
      await open(tester);
      await tester.ensureVisible(find.text('Draw'));
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();

      // move the canvas, then draw: the stroke is where it was drawn on the canvas, not in the window
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(700, 400)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 300)));
      await tester.pump();

      final start = const Offset(400, 300);
      final g = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(start + Offset(i * 20.0, i * 5.0));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));

      final saved = await tester.runAsync(() => repo.loadNote(id));
      final strokes = saved!.strokes[0]!;
      expect(strokes, hasLength(1));
      final first = strokes.single.points.first;
      expect(first.dx, greaterThan(canvasOrigin.dx - 100));
      expect(first.dx, lessThan(canvasOrigin.dx + 600));
      expect(first.dy, greaterThan(canvasOrigin.dy)); // (300 px further down than the window started)
      expect(saved.pageFormat, PageFormat.infinite);
      await close(tester);
    });
  });
}
