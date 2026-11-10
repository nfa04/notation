import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/onion_skin.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke bar({String id = 'a', Color color = Colors.black}) =>
    DrawingStroke(id: id, color: color, width: 30, points: [for (var i = 0; i <= 10; i++) Offset(10.0 + i * 8, 50)], brush: penBrushId);

void main() {
  testWidgets('a ghost is the page in one colour, faint, and nothing where it has no lines', (tester) async {
    late ByteData data;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      OnionSkinPainter([OnionGhost([bar(color: Colors.blue)], const Color(0xFFFF0000), 0.3)]).paint(Canvas(recorder), const Size(100, 100));
      final image = await recorder.endRecording().toImage(100, 100);
      data = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      image.dispose();
    });
    int at(int x, int y, int channel) => data.getUint8((y * 100 + x) * 4 + channel);
    expect(at(50, 50, 0), 255, reason: 'red, not the blue of the line');
    expect(at(50, 50, 2), 0);
    expect(at(50, 50, 3), closeTo(77, 2), reason: '0.3 of full');
    expect(at(50, 5, 3), 0, reason: 'nothing where there is no line');
  });

  test('a change in the lines of a ghost repaints it', () {
    final a = bar();
    final p = OnionSkinPainter([OnionGhost([a], Colors.red, 0.3)]);
    expect(p.shouldRepaint(OnionSkinPainter([OnionGhost([a], Colors.red, 0.3)])), isFalse);
    expect(p.shouldRepaint(OnionSkinPainter([OnionGhost([bar(id: 'b'), a], Colors.red, 0.3)])), isTrue);
    expect(p.shouldRepaint(OnionSkinPainter([OnionGhost([a], Colors.red, 0.2)])), isTrue);
  });

  group('in the editor', () {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    testWidgets('the menu shows the next page, and the setting is kept', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.strokes[0] = [bar()];
        note.strokes[1] = [bar(id: 'n')];
        await repo.saveNote(note);
      });
      await tester.runAsync(() => repo.settings.set('draw_bar_more', '1')); // (the rarely used tools are folded away by default)
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('onion-skin-0')), findsNothing, reason: 'off to begin with');
      await tester.ensureVisible(find.byKey(const ValueKey('onion-skin')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('onion-skin')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('onion-back-3')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('onion-next')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('onion-skin-0')), findsOneWidget, reason: 'page 1 shows through on page 0');
      expect(await tester.runAsync(() => repo.settings.get('onion_next')), '1');
    });
  });
}
