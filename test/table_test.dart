
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/markdown/markdown_pdf.dart';
import 'package:notes/markdown/markdown_table.dart';
import 'package:notes/markdown/markdown_view.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('markdown tables', () {
    test('a table is read into rows of cells, the dash line left out', () {
      final rows = parseTableText('| a | b |\n| --- | --- |\n| 1 | x \\| y |\n');
      expect(rows, [
        ['a', 'b'],
        ['1', 'x | y']
      ]);
      expect(parseTableText('just text'), isNull);
      expect(parseTableText('| a | b |'), isNull); // no dash line: not a table
    });

    test('writing and reading give the same table, however odd the cells', () {
      final rows = [
        ['Name', 'Note'],
        ['a|b', '**bold**'],
        ['', 'last'],
      ];
      expect(parseTableText(tableText(rows)), rows);
    });

    test('a table block is found among other lines with the offsets of its text', () {
      const src = 'before\n| a | **b** |\n|---|---|\n| 1 | 2 |\nafter';
      final blocks = parseMarkdown(src);
      expect(blocks.map((b) => b.type), [MdBlockType.paragraph, MdBlockType.table, MdBlockType.paragraph]);
      final table = blocks[1];
      expect(table.rows.length, 2);
      expect(table.rows[0][1].single.bold, isTrue);
      final two = table.rows[1][1].single;
      expect(src.substring(two.src, two.src + two.text.length), '2');
      expect(blocks[2].runs.single.text, 'after');
    });

    test('a bar line without a dash line stays text', () {
      expect(parseMarkdown('| a | b |\n| c | d |').map((b) => b.type), [MdBlockType.paragraph, MdBlockType.paragraph]);
    });

    test('inserting a table puts it on lines of its own at the cursor', () {
      final v = insertTable(const TextEditingValue(text: 'hello world', selection: TextSelection.collapsed(offset: 5)), 2, 3);
      expect(v.text.startsWith('hello\n\n| Column | Column | Column |'), isTrue);
      expect(v.text.endsWith('\n\n world'), isTrue);
      expect(parseTableText(v.text.split('\n\n')[1]), isNotNull);
    });

    testWidgets('it is drawn as a grid, not as bars', (tester) async {
      final c = RichInlineTextController()..text = '| Head | Two |\n|---|---|\n| cell | 2 |';
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MarkdownView(controller: c, fontSize: 16))));
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('cell'), findsOneWidget);
      expect(find.textContaining('|'), findsNothing);
    });

    test('it goes into the PDF as a table', () {
      final c = RichInlineTextController()..text = '| Head | Two |\n|---|---|\n| cell | 2 |';
      final blocks = markdownBlocksToPdf(c, 12);
      expect(blocks.length, 1);
      expect(blocks.single.runtimeType.toString(), 'Padding'); // the table inside its padding
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        id = await repo.createNote();
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    Future<void> chooseSize(WidgetTester tester, {int rows = 3, int columns = 2}) async {
      for (var i = 3; i < rows; i++) {
        await tester.tap(find.byKey(const ValueKey('table-rows-more')));
      }
      for (var i = 3; i > columns; i--) {
        await tester.tap(find.byKey(const ValueKey('table-columns-less')));
      }
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('table-create')));
      await tester.pumpAndSettle();
    }

    testWidgets('the top bar adds a table to the page as an element you type into', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('add-table')));
      await tester.pumpAndSettle();
      await chooseSize(tester, rows: 3, columns: 2);

      expect(find.byKey(const ValueKey('table-cell-0-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-cell-2-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-cell-0-2')), findsNothing); // two columns

      await tester.enterText(find.byKey(const ValueKey('table-cell-1-1')), 'typed');
      await tester.pump();
      final box = tester.widgetList<EditableText>(find.byType(EditableText)).first;
      expect(box, isNotNull);

      // more rows and columns
      await tester.tap(find.byKey(const ValueKey('table-add-row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-cell-3-0')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('table-add-column')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-cell-0-2')), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('table-cell-1-1'))).controller!.text, 'typed');
      await tester.tap(find.byKey(const ValueKey('table-remove-column')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-cell-0-2')), findsNothing);

      // saved as an ordinary text box whose text is the table
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
      final text = saved.textBoxes[0]!.single.controller.text;
      final rows = parseTableText(text)!;
      expect(rows.length, 4);
      expect(rows[1].contains('typed'), isTrue);
    });

    testWidgets('in document mode the table goes into the text at the cursor', (tester) async {
      await open(tester);
      await tester.tap(find.text('Document').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-table')));
      await tester.pumpAndSettle();
      await chooseSize(tester, rows: 2, columns: 3);
      expect(tester.widget<BlockEditor>(find.byType(BlockEditor)).controller.text.contains('| Column | Column | Column |'), isTrue);
    });
  });
}
