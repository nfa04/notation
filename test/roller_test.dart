import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/brush.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('with the roller chosen in the brush menu a line is a roller line, with no pressure; the brush of an extension is in the same menu and used', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => Brushes.sync('ext:', const []));
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    Future<void> drag(Offset from, Offset to) async {
      final g = await tester.createGesture();
      await g.down(origin + from);
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(origin + Offset.lerp(from, to, i / 12)!);
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    await drag(const Offset(100, 100), const Offset(400, 160));
    expect(strokes().single.brush, penBrushId, reason: 'the pen is the default');

    await tester.ensureVisible(find.byKey(const ValueKey('brush-picker')));
    await tester.tap(find.byKey(const ValueKey('brush-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('brush-roller')));
    await tester.pumpAndSettle();
    await drag(const Offset(100, 300), const Offset(400, 360));
    expect(strokes().last.brush, rollerBrushId);
    expect(strokes().last.pressures, isNull);

    Brushes.register(const ParamBrush('ext:inks/felt', 'Felt', BrushParams(width: 3)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('brush-picker')));
    await tester.tap(find.byKey(const ValueKey('brush-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('brush-ext:inks/felt')));
    await tester.pumpAndSettle();
    await drag(const Offset(100, 500), const Offset(400, 560));
    expect(strokes().last.brush, 'ext:inks/felt');
    expect(strokes().last.width, closeTo(9, 1e-9), reason: 'the width chosen (3), three times as thick');
  });
}
