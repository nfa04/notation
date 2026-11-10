
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/text_equation.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TextEditingValue at(String text, int offset) =>
    TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset));

void main() {
  setUpAll(AppDatabase.initFfi);

  group('which equation is meant', () {
    test('the formula under the cursor', () {
      final t = equationTarget(at(r'a $x+1=2$ and $y=3$ end', 18))!;
      expect(t.latex, 'y=3');
    });

    test('else the first formula that is an equation', () {
      final t = equationTarget(at(r'Area $\pi r^2$ then $A=2r$', 0))!;
      expect(t.latex, 'A=2r');
    });

    test('a selection wins, dollars stripped', () {
      const text = r'one $x=1$ two $y=2$';
      final t = equationTarget(TextEditingValue(text: text, selection: const TextSelection(baseOffset: 4, extentOffset: 9)))!;
      expect(t.latex, 'x=1');
    });

    test('plain text on the cursor line works too', () {
      final t = equationTarget(at('notes\n2x + 3 = 11\nmore', 9))!;
      expect(t.latex, '2x + 3 = 11');
      expect(t.insertAt, 17);
    });

    test('an empty text has nothing', () {
      expect(equationTarget(at('', 0)), isNull);
    });

    test('the answer goes in a paragraph below the line', () {
      final v = at('x+1=2 tail\nnext', 0);
      final out = withSolution(v, equationTarget(v)!, 'x = 1');
      expect(out.text, 'x+1=2 tail\n\n\$x = 1\$\nnext');
    });
  });

  testWidgets('a text box with an equation can be solved from its toolbar', (tester) async {
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
        TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: r'Solve $2x + 3 = 11$'),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('solve-in-text')), findsNothing); // no box selected yet
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130)); // into the box
    await tester.pumpAndSettle();
    final text = find.byType(EditableText);
    expect(text, findsWidgets);
    await tester.tap(find.byKey(const ValueKey('solve-in-text')));
    await tester.pumpAndSettle();
    expect(find.text('Solution'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-solution')));
    await tester.pumpAndSettle();
    expect(find.textContaining(r'x = 4'), findsWidgets);
  });

  testWidgets('a text box with an equation can be calculated from the menu on highlighted text', (tester) async {
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
        TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: r'Solve $2x + 3 = 11$'),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130)); // into the box
    await tester.pumpAndSettle();
    final field = tester.state<EditableTextState>(find.byType(EditableText).first);
    field.widget.controller.selection = const TextSelection(baseOffset: 6, extentOffset: 19);
    await tester.pump();
    field.showToolbar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calculate'));
    await tester.pumpAndSettle();
    expect(find.text('Solution'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-solution')));
    await tester.pumpAndSettle();
    expect(find.textContaining(r'x = 4'), findsWidgets);
  });

  testWidgets('a text box with an integral or an expression can be integrated and differentiated', (tester) async {
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
        TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: r'$x^2 + 3x$'),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('solve-in-text')), findsNothing); // no box selected yet
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130)); // into the box
    await tester.pumpAndSettle();
    final text = find.byType(EditableText);
    expect(text, findsWidgets);
    await tester.tap(find.byKey(const ValueKey('solve-in-text')));
    await tester.pumpAndSettle();
    expect(find.text('What should I do?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('calc-derive')));
    await tester.pumpAndSettle();
    expect(find.text('Result'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-solution')));
    await tester.pumpAndSettle();
    expect(find.textContaining(r'2x + 3'), findsWidgets);
  });
}
