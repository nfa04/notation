import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// the editor saves when what it has differs from what it saved: a change it does not see there is lost when the note is closed
void main() {
  setUpAll(AppDatabase.initFfi);

  Future<(NoteRepository, String)> open(WidgetTester tester, {void Function(NoteData note)? fill}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      fill?.call(note);
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    return (repo, id);
  }

  Future<void> saved(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pump();
  }

  testWidgets('moving the top margin of the document is saved', (tester) async {
    final (repo, id) = await open(tester, fill: (n) => n.documentText = 'Text');
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final before = (await tester.runAsync(() => repo.loadNote(id)))!.marginTop;
    await tester.drag(find.byKey(const ValueKey('margin-top')), const Offset(0, 40), warnIfMissed: false);
    await tester.pumpAndSettle();
    await saved(tester);
    final after = (await tester.runAsync(() => repo.loadNote(id)))!.marginTop;
    expect(after, isNot(closeTo(before, 0.01)));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

  testWidgets('a text box and a picture that are put in a group stay in it', (tester) async {
    final dir = Directory.systemTemp.createTempSync('signature');
    addTearDown(() => dir.delete(recursive: true));
    final picture = File('${dir.path}/p.png')..writeAsBytesSync(onePixelPng);
    final (repo, id) = await open(tester, fill: (n) {
      n.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(130, 200), initialText: 'box')];
      n.images[0] = [ImageItem(id: 'm', path: picture.path, position: const Offset(300, 150), size: const Size(80, 40))];
    });
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    const tip = 'Lasso: draw around drawings, text boxes and pictures to select them';
    await tester.ensureVisible(find.byTooltip(tip));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(tip));
    await tester.pumpAndSettle();
    final lasso = await tester.createGesture();
    await lasso.down(origin + const Offset(80, 100));
    for (final p in const [Offset(450, 100), Offset(450, 330), Offset(80, 330), Offset(80, 105)]) {
      await lasso.moveTo(origin + p);
    }
    await lasso.up();
    await tester.pumpAndSettle();
    await saved(tester); // (what the lasso changed is written now; the group alone is what is left)

    await tester.ensureVisible(find.byKey(const ValueKey('group-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-selection')));
    await tester.pumpAndSettle();
    await saved(tester);
    final note = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(note.textBoxes[0]!.single.group, isNot(noGroup));
    expect(note.images[0]!.single.group, note.textBoxes[0]!.single.group);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });
}

final onePixelPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');
