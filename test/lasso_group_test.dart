import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 40, 20), Paint()..color = Colors.red);
  final image = await recorder.endRecording().toImage(40, 20);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the lasso takes drawings, text boxes and pictures together, to move, delete and take back', (tester) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('lasso_');
      final pic = File('${dir.path}/p.png')..writeAsBytesSync(await _png());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [
        DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 20; i++) Offset(120.0 + i * 5, 150.0 + i)]), // inside the lasso
        DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 20; i++) Offset(120.0 + i * 5, 700.0 + i)]), // far below it
      ];
      note.textBoxes[0] = [
        TextBoxWidgetModel(id: 'in', position: const Offset(130, 200), initialText: 'inside'),
        TextBoxWidgetModel(id: 'out', position: const Offset(130, 600), initialText: 'outside'),
      ];
      note.images[0] = [
        ImageItem(id: 'pic-in', path: pic.path, position: const Offset(300, 150), size: const Size(80, 40)),
        ImageItem(id: 'pic-out', path: pic.path, position: const Offset(300, 800), size: const Size(80, 40)),
      ];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    Future<List<TextBoxWidgetModel>> boxes() async => (await tester.runAsync(() async {
          await tester.pump(const Duration(seconds: 1)); // the autosave
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return (await repo.loadNote(id))!.textBoxes[0]!;
        }))!;
    Future<List<ImageItem>> pictures() async => (await tester.runAsync(() async => (await repo.loadNote(id))!.images[0]!))!;

    await tester.ensureVisible(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    // a loop around the top half: the stroke, the box named "in", and the picture "pic-in"
    final lasso = await tester.createGesture();
    await lasso.down(origin + const Offset(80, 100));
    for (final p in const [Offset(450, 100), Offset(450, 330), Offset(80, 330), Offset(80, 105)]) {
      await lasso.moveTo(origin + p);
    }
    await lasso.up();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete the selection'), findsOneWidget); // more than drawings are selected
    expect(find.byTooltip('Delete drawing'), findsNothing);

    // drag the selection 100 right and 40 down, by grabbing the drawing in it
    final before = strokes().first.points.first;
    final drag = await tester.createGesture();
    await drag.down(origin + const Offset(170, 156));
    for (var i = 1; i <= 10; i++) {
      await drag.moveTo(origin + Offset(170 + i * 10, 156 + i * 4));
    }
    await drag.up();
    await tester.pumpAndSettle();
    final moved = strokes().first.points.first - before;
    expect(moved.dx, greaterThan(60));
    expect(moved.dy, greaterThan(20));
    var b = await boxes();
    final inside = b.firstWhere((x) => x.id == 'in'), outside = b.firstWhere((x) => x.id == 'out');
    expect(inside.position.dx, closeTo(130 + moved.dx, 0.5)); // the box went with the drawing
    expect(inside.position.dy, closeTo(200 + moved.dy, 0.5));
    expect(outside.position, const Offset(130, 600)); // the others did not
    var pics = await pictures();
    expect(pics.firstWhere((x) => x.id == 'pic-in').position.dx, closeTo(300 + moved.dx, 0.5));
    expect(pics.firstWhere((x) => x.id == 'pic-out').position, const Offset(300, 800));

    // the move is one step to take back
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes().first.points.first, before);
    b = await boxes();
    expect(b.firstWhere((x) => x.id == 'in').position, const Offset(130, 200));
    pics = await pictures();
    expect(pics.firstWhere((x) => x.id == 'pic-in').position, const Offset(300, 150));

    // select again and delete: the three go, the other three stay
    final again = await tester.createGesture();
    await again.down(origin + const Offset(80, 100));
    for (final p in const [Offset(450, 100), Offset(450, 330), Offset(80, 330), Offset(80, 105)]) {
      await again.moveTo(origin + p);
    }
    await again.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete the selection'));
    await tester.pumpAndSettle();
    expect(strokes().length, 1);
    b = await boxes();
    expect(b.map((x) => x.id), ['out']);
    expect((await pictures()).map((x) => x.id), ['pic-out']);

    // and taking it back brings all three back
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes().length, 2);
    expect((await boxes()).map((x) => x.id), ['in', 'out']);
    expect((await pictures()).map((x) => x.id), ['pic-in', 'pic-out']);
  });
}
