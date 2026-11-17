import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/markdown/markdown_table.dart';
import 'package:notes/markdown/table_formulas.dart';
import 'package:notes/screens/table_editor.dart';

String show(List<List<String>> rows, int r, int c) => TableSheet(rows).display(r, c);

void main() {
  group('formulas in a table', () {
    final rows = [
      ['Item', 'Price', 'Count', 'Cost'],
      ['Pen', '1.50', '4', '=B2*C2'],
      ['Book', '12,5', '2', '=B3*C3'],
      ['Total', '', '', '=SUM(D2:D3)'],
    ];

    test('a cell works out from other cells, the head being row 1', () {
      expect(show(rows, 1, 3), '6');
      expect(show(rows, 2, 3), '25'); // a comma is a decimal sign in a cell
      expect(show(rows, 3, 3), '31');
      expect(show(rows, 1, 0), 'Pen'); // not a formula: as written
    });

    test('functions, brackets, precedence and rounding', () {
      final t = [
        ['a', 'b'],
        ['1', '=AVG(A2:A4)'],
        ['2', '=(A2+A3)*2-1'],
        ['4', '=ROUND(10/3, 2)'],
        ['x', '=MAX(A2:A5)+MIN(A2:A5)+COUNT(A2:A5)'],
      ];
      expect(show(t, 1, 1), '2.333333333');
      expect(show(t, 2, 1), '5');
      expect(show(t, 3, 1), '3.33');
      expect(show(t, 4, 1), '8'); // 4 + 1 + 3: the text in the range is left out
      expect(show([['a'], ['=SUM(1; 2; 3)']], 1, 0), '6');
    });

    test('mistakes show as marks, and a mark travels to the cells that use it', () {
      final t = [
        ['a', 'b'],
        ['0', '=1/A2'],
        ['=B2+1', '=A3'],
        ['=Z9', '=nonsense('],
        ['word', '=A5*2'],
      ];
      expect(show(t, 1, 1), '#DIV/0!');
      expect(show(t, 2, 0), '#DIV/0!');
      expect(show(t, 2, 1), '#DIV/0!');
      expect(show(t, 3, 0), '#REF!');
      expect(show(t, 3, 1), '#ERR');
      expect(show(t, 4, 1), '#ERR');
    });

    test('a cell that uses itself is a loop, not a hang', () {
      final t = [
        ['a', 'b'],
        ['=B2', '=A2'],
      ];
      expect(show(t, 1, 0), '#LOOP!');
      expect(show(t, 1, 1), '#LOOP!');
      expect(show([['a'], ['=A2']], 1, 0), '#LOOP!');
    });

    test('column names go on after Z', () {
      expect([for (final i in [0, 25, 26, 27, 51, 52]) columnName(i)], ['A', 'Z', 'AA', 'AB', 'AZ', 'BA']);
    });

    test('the number a cell says', () {
      expect(parseCellNumber('1 234,5'), 1234.5);
      expect(parseCellNumber('1,234.5'), 1234.5);
      expect(parseCellNumber('-3'), -3);
      expect(parseCellNumber('3 apples'), isNull);
      expect(parseCellNumber(''), isNull);
      expect(formatCellNumber(0.1 + 0.2), '0.3');
      expect(formatCellNumber(1e20), isNot(contains('.0')));
    });
  });

  group('sorting and totals', () {
    final rows = [
      ['Name', 'Qty'],
      ['pear', '10'],
      ['Apple', '2'],
      ['fig', ''],
      ['plum', '33'],
    ];

    test('by a column: numbers by value, text without regard to case, empty cells last either way', () {
      expect([for (final r in sortedTable(rows, 1)) r[0]], ['Name', 'Apple', 'pear', 'plum', 'fig']);
      expect([for (final r in sortedTable(rows, 1, descending: true)) r[0]], ['Name', 'plum', 'pear', 'Apple', 'fig']);
      expect([for (final r in sortedTable(rows, 0)) r[0]], ['Name', 'Apple', 'fig', 'pear', 'plum']);
    });

    test('rows of equal key keep their order', () {
      final t = [
        ['k', 'v'],
        ['1', 'a'],
        ['0', 'b'],
        ['1', 'c'],
        ['0', 'd'],
      ];
      expect([for (final r in sortedTable(t, 0)) r[1]], ['v', 'b', 'd', 'a', 'c']);
    });

    test('a row of totals stays at the end; a formula about its own row follows the row', () {
      final t = [
        ['Item', 'Price', 'Count', 'Cost'],
        ['pen', '3', '2', '=B2*C2'],
        ['ink', '1', '5', '=B3*C3'],
        ['Total', '', '', '=SUM(D2:D3)'],
      ];
      final sorted = sortedTable(t, 1);
      expect([for (final r in sorted) r[0]], ['Item', 'ink', 'pen', 'Total']);
      expect(sorted[1][3], '=B2*C2'); // ink moved from row 3 to row 2
      expect(sorted[2][3], '=B3*C3');
      expect(sorted[3][3], '=SUM(D2:D3)');
      expect(show(sorted, 3, 3), '11');
    });

    test('a table too short to sort is left alone', () {
      expect(sortedTable([['a'], ['b']], 0), [['a'], ['b']]);
    });

    test('totals: a sum of every column that holds only numbers, once', () {
      final more = withTotals(rows);
      expect(more.last, ['Total', '=SUM(B2:B5)']);
      expect(show(more, 5, 1), '45');
      expect(withTotals(more).length, more.length); // not added twice
    });

    test('the table the caret is in is sorted and totalled as text, the alignment kept', () {
      const text = '| Name | Qty |\n| --- | --: |\n| b | 2 |\n| a | 1 |';
      final v = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 40));
      final sorted = editTable(v, TableAction.sortAscending)!;
      expect(sorted.text, '| Name | Qty |\n| --- | --: |\n| a | 1 |\n| b | 2 |');
      final withSum = editTable(sorted, TableAction.totals)!;
      expect(withSum.text, endsWith('| Total | =SUM(B2:B3) |'));
      expect(withSum.text.split('\n')[1], '| --- | --: |');
    });
  });

  test('a document shows the result of a formula, and keeps the formula in its text', () {
    const text = '| a | b |\n| --- | --- |\n| 2 | =A2*21 |\n';
    final blocks = parseMarkdown(text);
    final table = blocks.firstWhere((b) => b.type == MdBlockType.table);
    expect(table.rows[1][1].map((r) => r.text).join(), '42');
    expect(table.rows[1][0].map((r) => r.text).join(), '2');
    expect(text, contains('=A2*21'));
  });

  testWidgets('the table of a text box: formulas show their results, sorting and totals work, the alignment stays', (tester) async {
    final source = TextEditingController(text: '| Item | Qty | Double |\n| --- | --: | --- |\n| b | 5 | =B2*2 |\n| a | 2 | =B3*2 |\n| c | 3 | =B4*2 |');
    addTearDown(source.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: TableEditor(source: source, fontSize: 14, textColor: Colors.black)))));

    expect(find.byKey(const ValueKey('table-result-1-2')), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('table-cell-1-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('table-sort-up')));
    await tester.pump();
    final lines = source.text.split('\n');
    expect([for (final l in lines.skip(2)) l.split('|')[1].trim()], ['a', 'c', 'b']);
    expect(lines[1], '| --- | --: | --- |'); // the alignment is still there
    expect(lines[2], contains('=B2*2')); // a formula follows its row
    expect(lines[4], contains('=B4*2'));

    await tester.tap(find.byKey(const ValueKey('table-totals')));
    await tester.pump();
    expect(source.text.split('\n').last, '| Total | =SUM(B2:B4) | =SUM(C2:C4) |');
  });
}
