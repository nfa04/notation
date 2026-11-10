import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/images/picture_edit.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('a picture becomes a faded, locked reference under everything, and one step takes that back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('reference');
      final file = File('${dir.path}/p.png')..writeAsBytesSync(encodePicture(RgbaPicture.filled(8, 8, 200, 30, 30)));
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.images[0] = [ImageItem(id: 'p', path: file.path, position: const Offset(60, 100), size: const Size(200, 100))];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image-ctl-p')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('image-reference')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-ctl-p')), findsNothing, reason: 'locked: nothing to take hold of');
    expect(find.byKey(const ValueKey('image-pic-p')), findsOneWidget, reason: 'but it is to be seen');
    double fade() => tester.widgetList<Opacity>(find.descendant(of: find.byKey(const ValueKey('image-pic-p')), matching: find.byType(Opacity))).map((o) => o.opacity).fold(1.0, (a, b) => a * b);
    expect(fade(), closeTo(0.4, 0.01));

    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(saved.images[0]!.single.layer, 'reference');
    expect(saved.layers.layers.first.id, 'reference', reason: 'the bottom layer');
    expect(saved.layers.layers.first.locked, isTrue);

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-ctl-p')), findsOneWidget, reason: 'back on the page as it was');
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  });

  testWidgets('the colours of a picture are offered for the pen, and "add all" keeps them with the drawing bar\'s colours', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('palette');
      final pic = RgbaPicture.filled(20, 10, 220, 20, 20);
      for (var y = 0; y < 10; y++) {
        for (var x = 10; x < 20; x++) {
          pic.setPixel(x, y, 20, 30, 210, 255);
        }
      }
      final file = File('${dir.path}/p.png')..writeAsBytesSync(encodePicture(pic));
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.images[0] = [ImageItem(id: 'p', path: file.path, position: const Offset(60, 100), size: const Size(200, 100))];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image-ctl-p')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('image-palette')));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byKey(const ValueKey('palette-color-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('palette-color-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('palette-color-2')), findsNothing, reason: 'two colours in the picture');
    await tester.tap(find.byKey(const ValueKey('palette-add-all')));
    await tester.pumpAndSettle();
    final saved = await tester.runAsync(() => repo.settings.get('pen_colors'));
    expect(saved, isNotNull);
    expect(saved!.split(',').length, 2, reason: 'both colours are kept');
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  });
}
