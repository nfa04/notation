
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('a box is as tall in the PDF as it is in the editor, and never shorter than it was pulled', () {
    expect(exportBoxHeight(0, 44), 44); // fits its text: as tall as shown
    expect(exportBoxHeight(200, 44), 200); // pulled tall
    expect(exportBoxHeight(0, null), 0); // not on screen: the text decides
    expect(exportBoxHeight(120, null), 120);
    expect(exportBoxHeight(50, 90), 90); // the text needs more than it was pulled to
  });

  testWidgets('a selected text box can be pulled wider and taller at its corner, and keeps the size', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'a', position: const Offset(100, 200), initialText: 'a box')];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));

    expect(find.byKey(const ValueKey('resize-box-a')), findsNothing); // only while selected
    await tester.tapAt(origin + const Offset(150, 230));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('resize-box-a')), findsOneWidget);

    Rect boxRect() {
      final decorated = find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && w.constraints != null && w.constraints!.minHeight >= 0 && w.padding == const EdgeInsets.all(8));
      return tester.getRect(decorated.first);
    }

    final before = boxRect();
    expect(before.width, 260);
    final handle = tester.getCenter(find.byKey(const ValueKey('resize-box-a')));
    final g = await tester.createGesture();
    await g.down(handle);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(handle + Offset(i * 10.0, i * 20.0));
    }
    await g.up();
    await tester.pumpAndSettle();
    final after = boxRect();
    expect(after.left, before.left); // it did not move
    expect(after.top, before.top);
    // (the first few pixels only start the pull)
    expect(after.width, closeTo(360, 15));
    expect(after.height, closeTo(before.height + 200, 30));
    expect(after.width, greaterThan(before.width + 60));

    // not narrower than a usable width, nor off the page
    final grip = tester.getCenter(find.byKey(const ValueKey('resize-box-a')));
    final shrink = await tester.createGesture();
    await shrink.down(grip);
    for (var i = 1; i <= 30; i++) {
      await shrink.moveTo(grip - Offset(i * 20.0, 0));
    }
    await shrink.up();
    await tester.pumpAndSettle();
    expect(boxRect().width, 100);

    // saved: the width, and the height it was pulled to
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!.textBoxes[0]!.single;
    expect(saved.size.width, 100);
    expect(saved.size.height, greaterThan(150));
  });

  testWidgets('a note from before boxes could be resized keeps its boxes as tall as their text', (tester) async {
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'old', position: const Offset(10, 10), size: const Size(260, 140))];
      await repo.saveNote(note);
    });
    final loaded = (await tester.runAsync(() => repo.loadNote(id)))!.textBoxes[0]!.single;
    expect(loaded.size, const Size(260, 0));
    expect(TextBoxWidgetModel(id: 'n', position: Offset.zero).size.height, 0); // new ones fit their text
  });
}
