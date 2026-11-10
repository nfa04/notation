import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_model.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  for (final (withDocument, withBoxes) in [(true, true), (false, true), (true, false), (false, false)]) {
    testWidgets('the summary sheet adds its text to the page without upsetting the accessibility tree (document: $withDocument, boxes: $withBoxes)', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote(title: 'History');
        final n = (await repo.loadNote(id))!;
        n.documentText = withDocument ? '# Greek history\n\nAncient Greece began in the Bronze Age.' : '';
        if (withBoxes) {
          final dir = await Directory.systemTemp.createTemp('repro_');
          final rec = ui.PictureRecorder();
          Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 40, 20), Paint()..color = Colors.red);
          final img = await rec.endRecording().toImage(40, 20);
          await File('${dir.path}/p.png').writeAsBytes((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
          n.images[0] = [ImageItem(id: 'p', path: '${dir.path}/p.png', position: const Offset(300, 300), size: const Size(100, 50))];
          n.textBoxes[0] = [TextBoxWidgetModel(id: 'b1', position: const Offset(100, 500), initialText: 'First box'), TextBoxWidgetModel(id: 'b2', position: const Offset(100, 600), initialText: 'Second box')];
        }
        await repo.saveNote(n);
      });
      final summary = 'Ancient Greece was comprised of independent city-states (*poleis*) with diverse political systems. ' * 20;
      final model = FakeModel()..respond = (_) => summary;
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: AiService(providers: [model]))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('assistant-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('assistant-make-summary')));
      final add = find.byKey(const ValueKey('note-ai-add-text'));
      for (var i = 0; i < 100 && add.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(add, findsOneWidget);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-target-textBox')));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }
}
