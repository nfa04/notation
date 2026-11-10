import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Holding Shift while picking things adds them to what is selected (and takes them out again), in the mode that picks by tapping, in
/// the draw mode (tap and lasso), and across the frame of a selection, which covers what is under it.
void main() {
  setUpAll(AppDatabase.initFfi);

  const pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

  late NoteRepository repo;
  late String id;
  late Directory dir;

  DrawingStroke line(double x, double y) => DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
        for (var i = 0; i < 20; i++) Offset(x + i * 4, y + (i.isEven ? 0 : 10)),
      ]);

  /// Three drawings in a column (A, B, C), a text box beside A, a picture beside B.
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('shiftsel_');
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      final picture = File('${dir.path}/p.png')..writeAsBytesSync(base64Decode(pngBase64));
      note.strokes[0] = [line(100, 200), line(100, 350), line(100, 500)];
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'box', position: const Offset(450, 200), initialText: 'hello')];
      note.images[0] = [ImageItem(id: 'img', path: picture.path, position: const Offset(450, 330), size: const Size(100, 80))];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Offset Function(double, double) pageAt(WidgetTester tester) {
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    return (x, y) => Offset(left + x, pageTop.dy + 16 + y);
  }

  Future<void> click(WidgetTester tester, Offset at, {bool shift = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await g.up();
    await tester.pump(const Duration(milliseconds: 50));
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }

  Future<void> lasso(WidgetTester tester, List<Offset> shape, {bool shift = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final g = await tester.startGesture(shape.first, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    for (final p in shape) {
      await g.moveTo(p);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }

  Future<NoteData> saved(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3)); // the note is saved a moment after a change
    return (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return (await repo.loadNote(id))!;
    }))!;
  }

  Future<void> tearDownPage(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1)); // (the double-tap timer)
    await tester.runAsync(() => dir.delete(recursive: true));
  }

  /// Which drawings are left, by their first point's height.
  List<double> left(NoteData note) => [for (final s in note.strokes[0] ?? <DrawingStroke>[]) s.points.first.dy];

  testWidgets('select mode: Shift adds a drawing to the selection and takes it out again; without Shift a tap picks only that one', (tester) async {
    await open(tester);
    final at = pageAt(tester);

    await click(tester, at(120, 205));
    expect(find.byTooltip('Delete drawing'), findsOneWidget);
    await click(tester, at(120, 355), shift: true);
    await click(tester, at(120, 505), shift: true);
    await click(tester, at(120, 355), shift: true); // out again
    await tester.tap(find.byTooltip('Delete drawing'));
    expect(left(await saved(tester)), [350.0], reason: 'the first and the last were selected together');
    await tearDownPage(tester);
  });

  testWidgets('select mode: a tap without Shift lets go of the others', (tester) async {
    await open(tester);
    final at = pageAt(tester);

    await click(tester, at(120, 205));
    await click(tester, at(120, 355), shift: true);
    await click(tester, at(120, 505)); // no Shift: only this one
    await tester.tap(find.byTooltip('Delete drawing'));
    expect(left(await saved(tester)), [200.0, 350.0]);
    await tearDownPage(tester);
  });

  testWidgets('select mode: a text box, a picture and a drawing are picked together, and deleted together', (tester) async {
    await open(tester);
    final at = pageAt(tester);

    await click(tester, at(480, 215)); // the text box, edited on its own
    expect(find.byTooltip('Delete text box'), findsOneWidget);
    await click(tester, at(120, 205), shift: true); // the drawing joins it: it is a group now
    expect(find.byTooltip('Delete text box'), findsNothing);
    expect(find.byTooltip('Delete the selection'), findsOneWidget);
    await click(tester, at(500, 370), shift: true); // and the picture
    await tester.tap(find.byTooltip('Delete the selection'));
    final note = await saved(tester);
    expect(left(note), [350.0, 500.0]);
    expect(note.textBoxes[0] ?? const [], isEmpty);
    expect(note.images[0] ?? const [], isEmpty);
    await tearDownPage(tester);
  });

  testWidgets('select mode: Shift picks what is under the frame of the selection', (tester) async {
    await open(tester);
    final at = pageAt(tester);

    await click(tester, at(120, 205));
    await click(tester, at(120, 505), shift: true); // the frame now covers the drawing between them
    await click(tester, at(120, 355), shift: true);
    await tester.tap(find.byTooltip('Delete drawing'));
    expect(left(await saved(tester)), isEmpty, reason: 'all three were selected');
    await tearDownPage(tester);
  });

  testWidgets('draw mode: Shift on a tap picks several drawings', (tester) async {
    await open(tester);
    final at = pageAt(tester);
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    await click(tester, at(120, 205));
    expect(find.byTooltip('Delete drawing'), findsOneWidget);
    await click(tester, at(120, 505), shift: true);
    await click(tester, at(120, 355), shift: true); // (inside the frame of the other two)
    await tester.tap(find.byTooltip('Delete drawing'));
    expect(left(await saved(tester)), isEmpty);
    await tearDownPage(tester);
  });

  testWidgets('draw mode: a lasso with Shift adds to the selection; one without Shift replaces it', (tester) async {
    await open(tester);
    final at = pageAt(tester);
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();

    List<Offset> around(double x0, double y0, double x1, double y1) => [at(x0, y0), at(x1, y0), at(x1, y1), at(x0, y1), at(x0, y0 + 4)];
    await lasso(tester, around(80, 180, 200, 230)); // the first drawing
    await lasso(tester, around(80, 480, 200, 540), shift: true); // and the last
    await tester.tap(find.byTooltip('Delete drawing'));
    expect(left(await saved(tester)), [350.0]);
    await tearDownPage(tester);
  });

  testWidgets('draw mode: a lasso without Shift replaces the selection', (tester) async {
    await open(tester);
    final at = pageAt(tester);
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();

    List<Offset> around(double x0, double y0, double x1, double y1) => [at(x0, y0), at(x1, y0), at(x1, y1), at(x0, y1), at(x0, y0 + 4)];
    await lasso(tester, around(80, 180, 200, 230));
    await lasso(tester, around(80, 480, 200, 540));
    await tester.tap(find.byTooltip('Delete drawing'));
    expect(left(await saved(tester)), [200.0, 350.0]);
    await tearDownPage(tester);
  });
}
