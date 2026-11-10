import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/shapes.dart';
import 'package:notes/screens/shape_style_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke box({Color? fill, StrokeDash dash = StrokeDash.solid}) => DrawingStroke(
      id: 's1',
      color: const Color(0xFF2196F3),
      width: 4,
      points: shapePoints(ShapeTool.rectangle, const Offset(10, 10), const Offset(110, 60)),
      fill: fill,
      dash: dash,
    );

void main() {
  setUpAll(AppDatabase.initFfi);

  test('shapes: a triangle and a diamond close themselves, and can be made even-sided', () {
    for (final tool in [ShapeTool.triangle, ShapeTool.diamond, ShapeTool.rectangle, ShapeTool.ellipse]) {
      final pts = shapePoints(tool, const Offset(0, 0), const Offset(100, 60));
      expect((pts.first - pts.last).distance, lessThan(1e-6), reason: tool.name);
      final s = DrawingStroke(color: Colors.black, width: 3, points: pts);
      expect(s.isClosed, isTrue, reason: tool.name);
    }
    final even = shapePoints(ShapeTool.diamond, Offset.zero, const Offset(100, 40), constrain: true);
    final xs = even.map((p) => p.dx), ys = even.map((p) => p.dy);
    expect(xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b), closeTo(100, 1e-6));
    expect(ys.reduce((a, b) => a > b ? a : b) - ys.reduce((a, b) => a < b ? a : b), closeTo(100, 1e-6));
    // a line is not closed: there is nothing to fill
    expect(DrawingStroke(color: Colors.black, width: 3, points: shapePoints(ShapeTool.line, Offset.zero, const Offset(50, 50))).isClosed, isFalse);
  });

  test('the fill and the dashes are part of the stroke\'s stamp, so that a change is saved', () {
    final a = box();
    final stamp = a.stamp;
    a.fill = const Color(0x552196F3);
    expect(a.stamp, isNot(stamp));
    final withFill = a.stamp;
    a.dash = StrokeDash.dashed;
    expect(a.stamp, isNot(withFill));
    a.width = 8;
    expect(a.stamp, isNot(withFill));
  });

  test('they are kept in the database', () async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final id = await repo.createNote();
    final n = (await repo.loadNote(id))!;
    n.strokes = {
      0: [box(fill: const Color(0x802196F3), dash: StrokeDash.dotted)],
    };
    await repo.saveNote(n);
    var back = (await repo.loadNote(id))!;
    expect(back.strokes[0]!.single.fill, const Color(0x802196F3));
    expect(back.strokes[0]!.single.dash, StrokeDash.dotted);
    // a change of the style alone is saved
    back.strokes[0]!.single
      ..fill = null
      ..dash = StrokeDash.dashed
      ..color = const Color(0xFFE91E63);
    await repo.saveNote(back);
    back = (await repo.loadNote(id))!;
    expect(back.strokes[0]!.single.fill, isNull);
    expect(back.strokes[0]!.single.dash, StrokeDash.dashed);
    expect(back.strokes[0]!.single.color, const Color(0xFFE91E63));
  });

  test('and in note files, which older files still open', () {
    final bytes = encodeStrokes({
      2: [box(fill: const Color(0x802196F3), dash: StrokeDash.dashed)],
    });
    final back = decodeStrokes(bytes);
    expect(back[2]!.single.fill, const Color(0x802196F3));
    expect(back[2]!.single.dash, StrokeDash.dashed);
    expect(back[2]!.single.id, 's1');
    final plain = decodeStrokes(encodeStrokes({0: [box()]}));
    expect(plain[0]!.single.fill, isNull);
    expect(plain[0]!.single.dash, StrokeDash.solid);
  });

  test('a stroke block from before the fill and the dashes (version 2) is still read', () {
    final id = 'abc'.codeUnits;
    final data = ByteData(12 + 17 + id.length + 16);
    var at = 0;
    void u32(int v) {
      data.setUint32(at, v, Endian.little);
      at += 4;
    }

    void f32(double v) {
      data.setFloat32(at, v, Endian.little);
      at += 4;
    }

    u32(0x54534E55);
    u32(2);
    u32(1);
    data.setUint8(at++, id.length);
    for (final b in id) {
      data.setUint8(at++, b);
    }
    u32(3);
    u32(0xFF112233);
    f32(2.5);
    u32(2);
    f32(1);
    f32(2);
    f32(3);
    f32(4);
    final back = decodeStrokes(data.buffer.asUint8List());
    final s = back[3]!.single;
    expect(s.id, 'abc');
    expect(s.width, 2.5);
    expect(s.points, [const Offset(1, 2), const Offset(3, 4)]);
    expect(s.fill, isNull);
    expect(s.dash, StrokeDash.solid);
  });

  test('and are sent to the others working on the note', () {
    final a = box(fill: const Color(0x802196F3), dash: StrokeDash.dotted);
    final note = NoteData(id: 'n', strokes: {0: [a]});
    final sender = Replica('me');
    final ops = sender.localChanges(note);
    final theirs = NoteData(id: 'n');
    final receiver = Replica('you');
    for (final op in ops) {
      receiver.apply(theirs, op, makeBox: (_) => throw UnimplementedError(), saveImage: (_, _, _) => '', onNoteField: (_, _) {});
    }
    final got = theirs.strokes[0]!.single;
    expect(got.fill, const Color(0x802196F3));
    expect(got.dash, StrokeDash.dotted);
    // a change of look arrives too
    a
      ..fill = null
      ..color = const Color(0xFFE91E63)
      ..width = 9;
    for (final op in sender.localChanges(note)) {
      receiver.apply(theirs, op, makeBox: (_) => throw UnimplementedError(), saveImage: (_, _, _) => '', onNoteField: (_, _) {});
    }
    expect(theirs.strokes[0]!.single.fill, isNull);
    expect(theirs.strokes[0]!.single.color, const Color(0xFFE91E63));
    expect(theirs.strokes[0]!.single.width, 9);
  });

  testWidgets('the style dialog gives back the line and the fill that were chosen', (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ShapeStyle? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await showShapeStyleDialog(context, const ShapeStyle(color: Colors.black, width: 3)),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('line-${Colors.redAccent.toARGB32().toRadixString(16)}')));
    await tester.tap(find.byKey(const ValueKey('fill-same')));
    await tester.tap(find.text('Dashed'));
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('style-width')), const Offset(60, 0));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('style-apply')));
    await tester.pumpAndSettle();
    expect(got, isNotNull);
    expect(got!.color.toARGB32(), Colors.redAccent.toARGB32());
    expect(got!.dash, StrokeDash.dashed);
    expect(got!.width, greaterThan(3));
    expect(got!.fill, isNotNull);
    expect(got!.fill!.r, closeTo(Colors.redAccent.r, 0.01)); // (the fill is the line's colour, see-through)
    expect(got!.fill!.a, lessThan(1));
  });
}
