import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/gradient.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/models/shapes.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/shape_style_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const red = Color(0xFFFF0000), blue = Color(0xFF0000FF);

DrawingStroke square({FillGradient? gradient, Color? fill = red, String id = 'sq'}) => DrawingStroke(
      id: id,
      color: Colors.black,
      width: 2,
      points: shapePoints(ShapeTool.rectangle, const Offset(10, 10), const Offset(110, 90)),
      fill: fill,
      gradient: gradient,
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('a gradient', () {
    test('is written and read again, and what cannot be read is none', () {
      const g = FillGradient(end: blue, angle: 45, radial: true);
      expect(FillGradient.decode(g.encode()), g);
      expect(FillGradient.decode(const FillGradient(end: blue).encode())!.radial, isFalse);
      for (final bad in [null, '', 'x', '{}', '[1]', '{"e":"a"}']) {
        expect(FillGradient.decode(bad), isNull, reason: '$bad');
      }
    });

    test('starts and ends where the corners are, along its angle', () {
      const box = Rect.fromLTWH(0, 0, 100, 40);
      var (from, to) = const FillGradient(end: blue, angle: 0).line(box);
      expect(from.dx, closeTo(0, 1e-6));
      expect(to.dx, closeTo(100, 1e-6));
      expect(from.dy, closeTo(20, 1e-6));
      (from, to) = const FillGradient(end: blue, angle: 90).line(box);
      expect(from.dy, closeTo(0, 1e-6));
      expect(to.dy, closeTo(40, 1e-6));
      (from, to) = const FillGradient(end: blue, angle: 180).line(box);
      expect(from.dx, closeTo(100, 1e-6), reason: 'turned: the first colour is on the right');
    });

    test('is part of the stamp of the line, so that a change is saved, and a copy keeps it', () {
      final s = square();
      final before = s.stamp;
      s.gradient = const FillGradient(end: blue);
      expect(s.stamp, isNot(before));
      final withIt = s.stamp;
      s.gradient = const FillGradient(end: blue, angle: 10);
      expect(s.stamp, isNot(withIt));
      expect(s.copyAt(const Offset(5, 5)).gradient, s.gradient);
    });

    test('is as faint as its layer', () {
      final s = square(gradient: const FillGradient(end: blue))..layer = 'a';
      final out = LayerStack(const [NoteLayer('a', 'A', opacity: 0.5)]).forExport([s]).single;
      expect(out.fill!.a, closeTo(0.5, 0.01));
      expect(out.gradient!.end.a, closeTo(0.5, 0.01));
      expect(out.gradient!.end.b, closeTo(1, 0.01));
    });
  });

  group('drawn', () {
    Future<List<int>> row(List<DrawingStroke> strokes, {int y = 50}) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 120, 100), Paint()..color = Colors.white);
      InkLayerPainter(strokes: strokes).paint(canvas, const Size(120, 100));
      final img = await recorder.endRecording().toImage(120, 100);
      final data = (await img.toByteData())!;
      int px(int x) => data.getUint8((y * 120 + x) * 4);
      int pb(int x) => data.getUint8((y * 120 + x) * 4 + 2);
      return [px(20), pb(20), px(100), pb(100), px(60), pb(60)];
    }

    testWidgets('a linear gradient goes from the first colour to the second across the shape', (tester) async {
      await tester.runAsync(() async {
        final plain = await row([square()]);
        expect(plain[0], greaterThan(240));
        expect(plain[2], greaterThan(240), reason: 'one colour all over');
        final g = await row([square(gradient: const FillGradient(end: blue, angle: 0))]);
        expect(g[0], greaterThan(g[2] + 100), reason: 'red on the left, less of it on the right');
        expect(g[3], greaterThan(g[1] + 100), reason: 'and blue on the right');
        final back = await row([square(gradient: const FillGradient(end: blue, angle: 180))]);
        expect(back[0], lessThan(back[2] - 100), reason: 'turned round');
      });
    });

    testWidgets('a radial one has the first colour in the middle', (tester) async {
      await tester.runAsync(() async {
        final g = await row([square(gradient: const FillGradient(end: blue, radial: true))]);
        expect(g[4], greaterThan(200), reason: 'red in the middle');
        expect(g[4], greaterThan(g[2] + 40), reason: 'less of it towards the corners');
      });
    });

    testWidgets('a line with no fill, or an open one, has no gradient', (tester) async {
      await tester.runAsync(() async {
        final none = await row([square(fill: null, gradient: const FillGradient(end: blue))]);
        expect(none[0], greaterThan(240));
        expect(none[1], greaterThan(240));
        expect(none[0] == 255 && none[1] == 255, isTrue, reason: 'white page, nothing inside');
      });
    });
  });

  group('kept with the note', () {
    test('in the database, in a note file and with the others working on it', () async {
      final dir = await Directory.systemTemp.createTemp('gradient');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final files = NoteFileService(repo, supportDirectory: () async => dir);
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [square(gradient: const FillGradient(end: blue, angle: 30)), DrawingStroke(color: Colors.blue, width: 2, points: const [Offset(0, 0), Offset(50, 50)])];
      await repo.saveNote(note);

      void check(NoteData n) {
        final s = n.strokes[0]!;
        expect(s.first.gradient, const FillGradient(end: blue, angle: 30));
        expect(s.last.gradient, isNull);
      }

      check((await repo.loadNote(id))!);
      check((await repo.loadNote((await files.importBytes((await files.exportBytes(id))!)).noteId))!);

      // a change of the gradient alone is saved
      final back = (await repo.loadNote(id))!;
      back.strokes[0]!.first.gradient = null;
      await repo.saveNote(back);
      expect((await repo.loadNote(id))!.strokes[0]!.first.gradient, isNull);

      final a = Replica('a'), b = Replica('b');
      final na = NoteData(id: 'n'), nb = NoteData(id: 'n');
      na.strokes[0] = [square(gradient: const FillGradient(end: blue, radial: true))];
      for (final op in a.localChanges(na)) {
        b.apply(nb, op, makeBox: (i) => TextBoxWidgetModel(id: i, position: Offset.zero), saveImage: (i, bytes, e) => '', onNoteField: (f, d) => Replica.applyNoteField(nb, f, d));
      }
      expect(nb.strokes[0]!.single.gradient, const FillGradient(end: blue, radial: true));
    });
  });

  group('the style dialog', () {
    Future<ShapeStyle?> choose(WidgetTester tester, ShapeStyle start, Future<void> Function() act) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ShapeStyle? got;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () async => got = await showShapeStyleDialog(context, start), child: const Text('open')),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await act();
      await tester.ensureVisible(find.byKey(const ValueKey('style-apply')));
      await tester.tap(find.byKey(const ValueKey('style-apply')));
      await tester.pumpAndSettle();
      return got;
    }

    Future<void> kind(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.byKey(const ValueKey('gradient-kind')));
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('gradient-kind')), matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    testWidgets('makes the fill a gradient to another colour, with an angle, and takes it away again', (tester) async {
      final got = await choose(tester, const ShapeStyle(color: Colors.black, width: 3), () async {
        await kind(tester, 'Linear');
        await tester.ensureVisible(find.byKey(ValueKey('gradient-${Colors.green.toARGB32().toRadixString(16)}')));
        await tester.tap(find.byKey(ValueKey('gradient-${Colors.green.toARGB32().toRadixString(16)}')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('gradient-angle')));
        await tester.drag(find.byKey(const ValueKey('gradient-angle')), const Offset(60, 0));
        await tester.pump();
      });
      expect(got!.fill, isNotNull, reason: 'a gradient needs a fill to start from');
      expect(got.gradient, isNotNull);
      expect(got.gradient!.radial, isFalse);
      expect(got.gradient!.end.r, closeTo(Colors.green.r, 0.01));
      expect(got.gradient!.angle, isNot(90), reason: 'the slider moved');

      final radial = await choose(tester, ShapeStyle(color: Colors.black, width: 3, fill: red, gradient: got.gradient), () async {
        await kind(tester, 'Radial');
      });
      expect(radial!.gradient!.radial, isTrue);
      expect(radial.gradient!.end, got.gradient!.end, reason: 'the second colour stays');

      final none = await choose(tester, ShapeStyle(color: Colors.black, width: 3, fill: red, gradient: got.gradient), () async {
        await kind(tester, 'None');
      });
      expect(none!.gradient, isNull);
      expect(none.fill, red, reason: 'the fill is still the first colour');
    });

    testWidgets('no fill is no gradient', (tester) async {
      final got = await choose(tester, ShapeStyle(color: Colors.black, width: 3, fill: red, gradient: const FillGradient(end: blue)), () async {
        await tester.tap(find.byKey(const ValueKey('fill-none')));
        await tester.pump();
      });
      expect(got!.fill, isNull);
      expect(got.gradient, isNull);
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<void> open(WidgetTester tester, void Function(NoteData) fill) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        fill(note);
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    testWidgets('a note with gradients exports to a PDF that has them', (tester) async {
      await open(tester, (n) {
        n.strokes[0] = [square(gradient: const FillGradient(end: blue, angle: 0)), square(id: 'sq2', gradient: const FillGradient(end: blue, radial: true))];
      });
      final dir = Directory.systemTemp.createTempSync('gradientpdf');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = '${dir.path}/out.pdf';
      String? problem = 'not run';
      await tester.runAsync(() async {
        final state = tester.state(find.byType(FixedPageNoteEditor)) as dynamic;
        problem = await state.exportPdfTo(target) as String?;
      });
      expect(problem, isNull);
      final text = String.fromCharCodes(File(target).readAsBytesSync());
      expect(text, contains('/ShadingType 2'), reason: 'along a line');
      expect(text, contains('/ShadingType 3'), reason: 'from the middle');
    });
  });
}
