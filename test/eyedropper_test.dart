import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/color_sample.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('colorAtPixel', () {
    ByteData pixels(List<int> rgba) => ByteData.sublistView(Uint8List.fromList(rgba));

    test('reads the pixel at a place of the row', () {
      final data = pixels([0, 0, 0, 255, 200, 10, 20, 255, 1, 2, 3, 255, 4, 5, 6, 255]);
      expect(colorAtPixel(data, 2, 2, 1, 0), const Color(0xFFC80A14));
      expect(colorAtPixel(data, 2, 2, 1, 1), const Color(0xFF040506));
    });

    test('a see-through pixel is laid on the ground, an empty one or one outside is nothing', () {
      final data = pixels([255, 0, 0, 128, 9, 9, 9, 0]);
      final half = colorAtPixel(data, 2, 1, 0, 0, ground: const Color(0xFFFFFFFF))!;
      expect(half.toARGB32(), const Color(0xFFFF7F7F).toARGB32());
      expect(colorAtPixel(data, 2, 1, 1, 0), isNull);
      expect(colorAtPixel(data, 2, 1, 2, 0), isNull);
      expect(colorAtPixel(data, 2, 1, 0, -1), isNull);
    });
  });

  group('the eyedropper in the editor', () {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    late NoteRepository repo;

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late String id;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('settings');
        repo = NoteRepository(db);
        id = await repo.createNote();
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
    }

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    Offset onPage(WidgetTester tester, Offset p) => tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + p;

    Future<void> drawLine(WidgetTester tester, Offset a, Offset b) async {
      final g = await tester.createGesture();
      await g.down(onPage(tester, a));
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(onPage(tester, Offset.lerp(a, b, i / 12)!));
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    /// Presses on [at] with the eyedropper, waits for the picture of the area, and lets go.
    Future<void> pick(WidgetTester tester, Offset at) async {
      final g = await tester.createGesture();
      await g.down(onPage(tester, at));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.byKey(const ValueKey('eyedropper-loupe')), findsOneWidget, reason: 'the ring shows the colour while the pointer is down');
      await g.up();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    bool pickerOn(WidgetTester tester) => tester.widget<IconButton>(find.byKey(const ValueKey('eyedropper-button'))).isSelected ?? false;

    testWidgets('picks the colour of a line, then the pen draws again in it', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3); // (red)
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight); // (a thick line, easy to hit)
      }
      await tester.pumpAndSettle();
      await drawLine(tester, const Offset(100, 200), const Offset(400, 200));
      final red = strokes().single.color;
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1); // (back to black)
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('eyedropper-layer')), findsOneWidget);

      await pick(tester, const Offset(250, 200));
      expect(find.byKey(const ValueKey('eyedropper-layer')), findsNothing, reason: 'it picks once, then the pen draws');
      expect(find.byKey(const ValueKey('eyedropper-loupe')), findsNothing);
      expect(strokes(), hasLength(1), reason: 'picking draws nothing');

      await drawLine(tester, const Offset(100, 400), const Offset(400, 400));
      expect(strokes().last.color.toARGB32(), red.toARGB32());
    });

    testWidgets('the paper is picked as it is shown, and a new colour joins the added colours', (tester) async {
      await open(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('eyedropper-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('eyedropper-button')));
      await tester.pumpAndSettle();
      expect(pickerOn(tester), isTrue);
      await pick(tester, const Offset(300, 500));
      await drawLine(tester, const Offset(100, 300), const Offset(400, 300));
      final c = strokes().single.color;
      expect(c.a, 1.0);
      expect(c.r, greaterThan(0.9), reason: 'blank paper is (nearly) white');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      final saved = await tester.runAsync(() => repo.settings.penColors());
      expect(saved!.map((s) => s.toARGB32()), contains(c.toARGB32()));
    });

    testWidgets('the button and the key switch it off again, and another tool does too', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('eyedropper-button')));
      await tester.pumpAndSettle();
      expect(pickerOn(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey('eyedropper-button')));
      await tester.pumpAndSettle();
      expect(pickerOn(tester), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE); // (the eraser)
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('eyedropper-layer')), findsNothing);
    });
  });
}
