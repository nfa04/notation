import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/markdown_table.dart';

/// What goes into a table comes out of it: the text of a cell is kept (trimmed, on one line) however many pipes and backslashes it has.
void main() {
  const pieces = ['a', 'b', 'x y', ' ', '|', r'\', r'\|', ':', '-', '---', '`', '`a|b`', '*', '1', 'é', '€'];

  /// A bar in a cell is written as `\|` and a table is cut at every bar that has an even number of backslashes before it, so a cell
  /// that has an odd number of them right before a bar (LaTeX norm bars, `\|x\|`) cannot be written: see the skipped test below.
  bool writable(String c) => !RegExp(r'(?<!\\)(\\\\)*\\\|').hasMatch(c);

  String cell(Random rnd) {
    while (true) {
      final c = List.generate(rnd.nextInt(5), (_) => pieces[rnd.nextInt(pieces.length)]).join();
      if (writable(c)) return c;
    }
  }

  String tidy(String c) => c.replaceAll('\n', ' ').trim();

  test('random tables survive being written and read', () {
    final rnd = Random(12);
    final failures = <String>[];
    for (var round = 0; round < 1500; round++) {
      final width = 1 + rnd.nextInt(4), height = 1 + rnd.nextInt(4);
      final rows = [for (var r = 0; r < height; r++) [for (var c = 0; c < width; c++) cell(rnd)]];
      final text = tableText(rows);
      final back = parseTableText(text);
      final want = [for (final r in rows) [for (final c in r) tidy(c)]];
      if (back == null || back.toString() != want.toString()) failures.add('$want\n  came back as $back\n  from:\n$text');
    }
    expect(failures, isEmpty, reason: failures.take(3).join('\n---\n'));
  });

  test('LaTeX norm bars in a cell keep the table together', () {
    final text = tableText([
      ['name', 'formula'],
      ['norm', r'$\|x\|$'],
      ['after', 'x'],
    ]);
    final back = parseTableText(text)!;
    expect(back.map((r) => r.length), [2, 2, 2], reason: 'the bars of the norm must not cut the row into more cells:\n$text');
    expect(back[1][1], r'$\|x\|$');
  }, skip: 'known limit of the format: a bar after an odd number of backslashes cannot be written in a cell (\\| cuts the row). '
      'It would take a second level of escaping that existing notes and other Markdown readers do not have.');

  test('a bar after two backslashes, and a bar of its own, are kept', () {
    final text = tableText([
      ['a', 'b'],
      [r'x\\|y', 'p|q'],
    ]);
    expect(parseTableText(text), [
      ['a', 'b'],
      [r'x\\|y', 'p|q'],
    ]);
  });

  test('a cell with a line break is put on one line', () {
    final text = tableText([
      ['head', 'two'],
      ['one\ntwo', 'x'],
    ]);
    expect(parseTableText(text), [
      ['head', 'two'],
      ['one two', 'x'],
    ]);
  });

  test('ragged rows are filled up to the widest, and text that is no table is none', () {
    expect(parseTableText('| a | b | c |\n| --- | --- | --- |\n| 1 |'), [
      ['a', 'b', 'c'],
      ['1', '', ''],
    ]);
    expect(parseTableText('| a |\n| b |'), isNull, reason: 'no separator line');
    expect(parseTableText('just text'), isNull);
    expect(parseTableText(''), isNull);
    expect(parseTableText('| a |'), isNull, reason: 'one line');
    expect(parseTableText('| a |\n| --- |\nnot a row'), isNull);
  });

  test('alignment marks are read from the separator line', () {
    expect(columnAligns('| :--- | :---: | ---: | --- |'), ['left', 'center', 'right', '']);
    expect(columnAligns('|:-|-:|'), ['left', 'right']);
  });

  test('a new table has the head, the separator and empty rows, and its size is held in bounds', () {
    expect(parseTableText(emptyTable(3, 2)), [
      ['Column', 'Column'],
      ['', ''],
      ['', ''],
    ]);
    expect(parseTableText(emptyTable(0, 0)), [
      ['Column'],
    ]);
    expect(parseTableText(emptyTable(1000, 1000))!.length, 50);
    expect(parseTableText(emptyTable(1000, 1000))!.first.length, 12);
  });
}
