import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a selected drawing of circles and arrows is replaced by the clean diagram, and taking it back restores the drawing', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late List<DrawingStroke> drawn;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      await repo.settings.set('index_handwriting', '0');
      await repo.settings.set('pdf_handwriting_text', '0');
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      DrawingStroke stroke(List<Offset> p) => DrawingStroke(color: const Color(0xFF000000), width: 3, points: p);
      List<Offset> circle(Offset c, double r) => [for (var i = 0; i <= 48; i++) c + Offset(math.cos(0.6 + 2 * math.pi * 1.03 * i / 48), math.sin(0.6 + 2 * math.pi * 1.03 * i / 48)) * r];
      List<Offset> arrow(Offset a, Offset b) {
        final u = (b - a) / (b - a).distance;
        Offset barb(double t) => b - Offset(u.dx * math.cos(t) - u.dy * math.sin(t), u.dx * math.sin(t) + u.dy * math.cos(t)) * 12;
        return [for (var i = 0; i <= 20; i++) a + (b - a) * (i / 20), barb(0.5), b, barb(-0.5)];
      }

      drawn = [
        stroke(circle(const Offset(200, 300), 32)),
        stroke(circle(const Offset(450, 300), 32)),
        stroke(circle(const Offset(450, 300), 25)),
        stroke(arrow(const Offset(235, 300), const Offset(415, 300))),
        stroke(arrow(const Offset(100, 300), const Offset(165, 300))),
      ];
      note.strokes[0] = drawn;
      await repo.saveNote(note);
    });

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    // the lasso takes the whole drawing
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final lasso = await tester.startGesture(at(60, 200), kind: PointerDeviceKind.touch);
    for (final p in [at(60, 200), at(520, 200), at(520, 400), at(60, 400), at(60, 205)]) {
      await lasso.moveTo(p);
      await tester.pump();
    }
    await lasso.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('diagram-from-drawing')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('diagram-from-drawing')));
    await tester.pumpAndSettle();
    // (no handwriting model here: the circles are numbered, and the dialog says so)
    expect(find.byKey(const ValueKey('diagram-note')), findsOneWidget);
    final text = tester.widget<TextField>(find.byKey(const ValueKey('diagram-text'))).controller!.text;
    expect(text, contains('start: q0'));
    expect(text, contains('accept: q1'));
    expect(text, contains('q0 -> q1'));

    await tester.tap(find.byKey(const ValueKey('diagram-insert')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    var note = (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return (await repo.loadNote(id))!;
    }))!;
    expect(note.strokes[0]!.any((s) => drawn.any((d) => d.id == s.id)), isFalse, reason: 'the drawing is replaced');
    expect(note.textBoxes[0]!.map((b) => b.controller.text), containsAll(['q0', 'q1']));

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    note = (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return (await repo.loadNote(id))!;
    }))!;
    expect(note.strokes[0]!.map((s) => s.id).toList(), drawn.map((s) => s.id).toList(), reason: 'taking it back brings the drawing back, in its order');
    expect(note.textBoxes[0] ?? const [], isEmpty);
    expect(tester.takeException(), isNull);
  });
}
