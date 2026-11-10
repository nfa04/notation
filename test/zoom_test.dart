import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<List<int>> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 40, 20), Paint()..color = Colors.red);
  final image = await recorder.endRecording().toImage(40, 20);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;
  late Directory dir;

  Future<void> open(WidgetTester tester, {Size size = const Size(1600, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('zoom_');
      final pic = '${dir.path}/p.png';
      await File(pic).writeAsBytes(await _png());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
          for (var i = 0; i < 20; i++) Offset(300.0 + i * 4, 300.0 + (i.isEven ? 0 : 10)),
        ]),
      ];
      note.images[0] = [ImageItem(id: 'p', path: pic, position: const Offset(400, 600), size: const Size(200, 100))];
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'hello')];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Offset pageAt(WidgetTester tester, double x, double y) {
    final box = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final scale = tester.getSize(find.byKey(const ValueKey('page-0'))).width / 800;
    return Offset(box.dx + x * scale, box.dy + y * scale);
  }

  double pageWidth(WidgetTester tester) => tester.getSize(find.byKey(const ValueKey('page-0'))).width;

  group('letting go of a selection', () {
    testWidgets('a tap on nothing lets go of a drawing', (tester) async {
      await open(tester);
      await tester.tapAt(pageAt(tester, 330, 305));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Delete drawing'), findsOneWidget);

      await tester.tapAt(pageAt(tester, 600, 800)); // nothing there (lower down the bottom bar covers the page)
      await tester.pumpAndSettle();
      expect(find.byTooltip('Delete drawing'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a tap on nothing lets go of a picture', (tester) async {
      await open(tester);
      await tester.tapAt(pageAt(tester, 500, 650));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-delete')), findsOneWidget);

      await tester.tapAt(pageAt(tester, 600, 800));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-delete')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('picking one thing lets go of the other', (tester) async {
      await open(tester);
      await tester.tapAt(pageAt(tester, 500, 650)); // the picture
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-delete')), findsOneWidget);

      await tester.tapAt(pageAt(tester, 330, 305)); // the drawing
      await tester.pumpAndSettle();
      expect(find.byTooltip('Delete drawing'), findsOneWidget);
      expect(find.byKey(const ValueKey('image-delete')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a tap on nothing lets go of a text box', (tester) async {
      await open(tester);
      await tester.tapAt(pageAt(tester, 150, 130)); // in the text box
      await tester.pumpAndSettle();
      expect(find.byType(BottomAppBar), findsNothing); // (the formatting bar is a Material bar)
      final barBefore = find.byTooltip('Bold').evaluate().length + find.byIcon(Icons.format_bold_rounded).evaluate().length;
      expect(barBefore, greaterThan(0));

      await tester.tapAt(pageAt(tester, 600, 760));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.format_bold_rounded), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('zoom', () {
    testWidgets('Ctrl and the wheel zoom in and out', (tester) async {
      await open(tester);
      final normal = pageWidth(tester);
      expect(normal, closeTo(800, 0.5));

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.hover(const Offset(800, 400)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -400)));
      await tester.pumpAndSettle();
      final zoomedIn = pageWidth(tester);
      expect(zoomedIn, greaterThan(normal * 1.5));

      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 1200)));
      await tester.pumpAndSettle();
      expect(pageWidth(tester), lessThan(zoomedIn));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });

    testWidgets('the wheel without Ctrl scrolls and does not zoom', (tester) async {
      await open(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(800, 400)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 200)));
      await tester.pumpAndSettle();
      expect(pageWidth(tester), closeTo(800, 0.5));
    });

    testWidgets('two fingers pinch', (tester) async {
      await open(tester);
      final a = await tester.startGesture(const Offset(700, 400), pointer: 1);
      final b = await tester.startGesture(const Offset(900, 400), pointer: 2);
      for (var i = 1; i <= 6; i++) {
        await a.moveTo(Offset(700 - i * 30.0, 400));
        await b.moveTo(Offset(900 + i * 30.0, 400));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(pageWidth(tester), greaterThan(1100)); // the fingers went from 200 to 560 apart
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the lock stops the zoom, and the reset goes back to the normal size', (tester) async {
      await open(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.hover(const Offset(800, 400)));

      await tester.tap(find.byKey(const ValueKey('zoom-lock')));
      await tester.pump();
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -400)));
      await tester.pumpAndSettle();
      expect(pageWidth(tester), closeTo(800, 0.5)); // locked: nothing happened

      await tester.tap(find.byKey(const ValueKey('zoom-lock')));
      await tester.pump();
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -400)));
      await tester.pumpAndSettle();
      expect(pageWidth(tester), greaterThan(1200));

      await tester.tap(find.byKey(const ValueKey('zoom-reset')));
      await tester.pumpAndSettle();
      expect(pageWidth(tester), closeTo(800, 0.5));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });

    testWidgets('things are still where the pen lands when zoomed', (tester) async {
      await open(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.hover(const Offset(800, 400)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -300)));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(pageWidth(tester), greaterThan(1000));

      // the drawing is picked where it is on the zoomed page
      await tester.tapAt(pageAt(tester, 330, 305));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Delete drawing'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a narrow screen fits the page to its width', (tester) async {
      await open(tester, size: const Size(500, 900));
      expect(pageWidth(tester), closeTo(500, 0.5));
    });
  });

  group('dragging between pages', () {
    // two pages fit on the screen when zoomed out
    Future<void> zoomOut(WidgetTester tester) async {
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.hover(const Offset(800, 300)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 500)));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(pageWidth(tester), lessThan(600));
    }

    Offset onPage(WidgetTester tester, int page, double x, double y) {
      final box = tester.getTopLeft(find.byKey(ValueKey('page-$page')));
      final scale = tester.getSize(find.byKey(ValueKey('page-$page'))).width / 800;
      return Offset(box.dx + x * scale, box.dy + y * scale);
    }

    Future<void> dragTo(WidgetTester tester, Offset from, Offset to) async {
      final g = await tester.startGesture(from, pointer: 7);
      const steps = 12;
      for (var i = 1; i <= steps; i++) {
        await g.moveTo(Offset.lerp(from, to, i / steps)!);
        await tester.pump(const Duration(milliseconds: 20));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 400)); // past the double-tap timer
    }

    Future<dynamic> saved(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 2)); // the autosave
      return tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return repo.loadNote(id);
      });
    }

    testWidgets('a text box can be dragged onto the next page', (tester) async {
      await open(tester);
      await zoomOut(tester);
      expect(find.byKey(const ValueKey('page-1')), findsOneWidget);

      await dragTo(tester, onPage(tester, 0, 150, 130), onPage(tester, 1, 250, 300));
      expect(find.descendant(of: find.byKey(const ValueKey('page-1')), matching: find.text('hello', findRichText: true)),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('page-0')), matching: find.text('hello', findRichText: true)),
          findsNothing);

      final note = await saved(tester);
      expect(note.textBoxes.keys, [1]);
      final box = note.textBoxes[1]!.single;
      // it lands where it was dropped (the grip point stays under the pointer)
      expect(box.position.dx, closeTo(250 - 50, 130)); // the box follows the pointer from where the drag was taken up
      expect(box.position.dy, closeTo(300 - 30, 130));
    });

    testWidgets('a picture can be dragged onto the next page', (tester) async {
      await open(tester);
      await zoomOut(tester);

      await dragTo(tester, onPage(tester, 0, 500, 650), onPage(tester, 1, 400, 200));
      final note = await saved(tester);
      expect(note.images.keys, [1]);
      expect(note.images[1]!.single.position.dy, lessThan(200));
    });

    testWidgets('a selected drawing can be dragged onto the next page', (tester) async {
      await open(tester);
      await zoomOut(tester);

      await tester.tapAt(onPage(tester, 0, 330, 305)); // pick it
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('Delete drawing'), findsOneWidget);

      await dragTo(tester, onPage(tester, 0, 330, 305), onPage(tester, 1, 330, 200));
      final note = await saved(tester);
      expect(note.strokes.keys, [1]);
      final ys = note.strokes[1]!.single.points.map((p) => p.dy);
      expect(ys.reduce((a, b) => a < b ? a : b), closeTo(200, 130)); // near where it was dropped
    });

    testWidgets('dropping above the first page keeps the thing on it', (tester) async {
      await open(tester);
      await zoomOut(tester);
      await dragTo(tester, onPage(tester, 0, 150, 130), onPage(tester, 0, 150, -300));
      final note = await saved(tester);
      expect(note.textBoxes.keys, [0]);
      expect(note.textBoxes[0]!.single.position.dy, greaterThanOrEqualTo(0));
    });
  });
}
