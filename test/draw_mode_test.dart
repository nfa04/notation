import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

  for (final size in [const Size(1600, 1000), const Size(900, 1300), const Size(412, 900)]) {
    testWidgets('switching to Draw works on $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        final dir = await Directory.systemTemp.createTemp('draw_');
        final pic = '${dir.path}/p.png';
        await File(pic).writeAsBytes(await _png());
        final folder = await repo.createFolder('F');
        await repo.setFolderThemeImage(folder, pic);
        id = await repo.createNote(folderId: folder);
        final note = (await repo.loadNote(id))!;
        note.documentText = '# Title\n\nSome text ' * 6;
        note.strokes[0] = [DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 50; i++) Offset(100.0 + i * 5, 300.0 + i)])];
        note.strokes[2] = [DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 50; i++) Offset(100.0 + i * 5, 300.0 + i)])];
        note.images[0] = [ImageItem(id: 'p', path: pic, position: const Offset(50, 50), size: const Size(200, 100))];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Draw')); // the toolbar scrolls sideways on a narrow screen
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
      expect(find.byTooltip('Eraser (drawings only)'), findsOneWidget);

      // the page list is the same one as before (not rebuilt), and back again
      await tester.ensureVisible(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Eraser (drawings only)'), findsNothing);
      expect(find.byType(CustomScrollView), findsOneWidget);
    });
  }
}
