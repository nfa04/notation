import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the undo button takes back changes that are not drawings, and redo does them again', (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote(title: 'First');
      final n = (await repo.loadNote(id))!;
      n.textBoxes = {
        0: [TextBoxWidgetModel(id: 'b', position: const Offset(40, 40), initialText: 'hello')],
      };
      await repo.saveNote(n);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    IconButton button(String key) => tester.widget<IconButton>(find.byKey(ValueKey(key)));
    expect(button('undo-any').onPressed, isNull);
    expect(button('redo-any').onPressed, isNull);

    // the title
    await tester.enterText(find.widgetWithText(TextField, 'First'), 'Second');
    await tester.pump(const Duration(milliseconds: 700));
    expect(button('undo-any').onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'First'), findsOneWidget);
    expect(button('redo-any').onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('redo-any')));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Second'), findsOneWidget);
    expect(button('redo-any').onPressed, isNull);

    // the text of a box
    await tester.tap(find.text('hello'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'hello'), 'bye');
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.widgetWithText(TextField, 'bye'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'hello'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Second'), findsOneWidget); // (the title is not touched by that)
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'First'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });
}
