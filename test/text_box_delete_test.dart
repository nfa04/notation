
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a selected text box has its delete button next to it, not in the top bar', (tester) async {
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
      note.textBoxes[0] = [
        TextBoxWidgetModel(id: 'a', position: const Offset(100, 200), initialText: 'first box'),
        TextBoxWidgetModel(id: 'b', position: const Offset(100, 500), initialText: 'second box'),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    expect(find.byKey(const ValueKey('delete-text-box')), findsNothing); // nothing selected

    await tester.tapAt(origin + const Offset(150, 230)); // into the first box
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete-text-box')), findsOneWidget);
    // it sits right above that box, at its left edge
    final button = tester.getRect(find.byKey(const ValueKey('delete-text-box')));
    expect(button.left, greaterThanOrEqualTo(origin.dx + 100 - 10));
    expect(button.bottom, lessThanOrEqualTo(origin.dy + 200 + 4));
    // and none in the top bar any more
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    // the styling tools are in the same row, left of it, and not in the top bar
    final row = find.ancestor(of: find.byKey(const ValueKey('delete-text-box')), matching: find.byType(Row)).first;
    final tools = tester.getRect(find.byKey(const ValueKey('delete-text-box')));
    for (final tip in ['Bold', 'Italic', 'Underline', 'Style: background, border, opacity']) {
      final at = tester.getCenter(find.descendant(of: row, matching: find.byTooltip(tip)));
      expect(at.dy, closeTo(tools.center.dy, 2), reason: tip);
      expect(at.dx, lessThan(tools.left + 1), reason: tip);
    }
    expect(find.descendant(of: find.byType(AppBar), matching: find.byKey(const ValueKey('box-style'))), findsNothing);

    await tester.tap(find.byKey(const ValueKey('delete-text-box')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete-text-box')), findsNothing);
    final texts = tester.widgetList<EditableText>(find.byType(EditableText)).map((e) => e.controller.text).toList();
    expect(texts.where((t) => t == 'first box'), isEmpty);
    expect(find.textContaining('second box'), findsOneWidget); // the other one stays

    // saved
    await tester.pump(const Duration(seconds: 1)); // the autosave timer
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(saved.textBoxes[0]!.map((b) => b.id), ['b']);
  });
}
