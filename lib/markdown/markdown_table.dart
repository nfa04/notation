import 'package:flutter/services.dart';

/// Tables in Markdown: `| a | b |` rows, with a `|---|---|` line below the first
/// one. A table made by the table tool is always in this form; the same text is
/// what is saved, shown ([MarkdownView]) and exported.

/// A line that separates the head of a table from its rows: `|---|:--:|`.
final tableSeparator = RegExp(r'^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$');

bool isTableRow(String line) => line.trimLeft().startsWith('|');

/// Where the cells of [line] begin and end, between its unescaped bars
/// (`\|` is a bar inside a cell); the outer bars are not cells.
List<(int, int)> cellSpans(String line) {
  final bars = <int>[];
  for (var i = 0; i < line.length; i++) {
    if (line[i] == r'\') {
      i++;
    } else if (line[i] == '|') {
      bars.add(i);
    }
  }
  if (bars.isEmpty) return [(0, line.length)];
  final spans = <(int, int)>[];
  // text before the first bar is no cell when it is only space (the usual `| a |`)
  if (line.substring(0, bars.first).trim().isNotEmpty) spans.add((0, bars.first));
  for (var k = 0; k + 1 < bars.length; k++) {
    spans.add((bars[k] + 1, bars[k + 1]));
  }
  if (line.substring(bars.last + 1).trim().isNotEmpty) spans.add((bars.last + 1, line.length));
  return spans;
}

/// The text of one cell, unescaped.
String cellText(String line, (int, int) span) =>
    line.substring(span.$1, span.$2).trim().replaceAll(r'\|', '|');

String _escape(String cell) => cell.replaceAll('\n', ' ').replaceAll('|', r'\|');

/// The rows of [text] when all of it is one table, else null. Ragged rows are
/// filled up to the widest.
List<List<String>>? parseTableText(String text) {
  final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.length < 2 || !lines.every(isTableRow) || !tableSeparator.hasMatch(lines[1])) return null;
  final rows = <List<String>>[
    for (var i = 0; i < lines.length; i++)
      if (i != 1) [for (final s in cellSpans(lines[i])) cellText(lines[i], s)],
  ];
  final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
  for (final r in rows) {
    while (r.length < width) {
      r.add('');
    }
  }
  return rows;
}

bool isTableText(String text) => parseTableText(text) != null;

/// Markdown for [rows] (the first is the head).
String tableText(List<List<String>> rows) {
  final width = rows.isEmpty ? 1 : rows.first.length;
  String line(List<String> r) => '| ${r.map(_escape).join(' | ')} |';
  return [
    line(rows.first),
    '|${List.filled(width, ' --- ').join('|')}|',
    for (final r in rows.skip(1)) line(r),
  ].join('\n');
}

/// A table with [rows] rows of [columns] empty cells (the head included).
String emptyTable(int rows, int columns) => tableText([
      for (var r = 0; r < rows.clamp(1, 50); r++) List.filled(columns.clamp(1, 12), r == 0 ? 'Column' : ''),
    ]);

/// [v] with [block] inserted at the cursor, on lines of its own.
TextEditingValue insertBlock(TextEditingValue v, String block) {
  final text = v.text;
  final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: text.length);
  final before = text.substring(0, sel.start), after = text.substring(sel.end);
  final lead = before.isEmpty || before.endsWith('\n\n') ? '' : (before.endsWith('\n') ? '\n' : '\n\n');
  final trail = after.startsWith('\n\n') ? '' : (after.startsWith('\n') ? '\n' : '\n\n');
  final inserted = '$lead$block$trail';
  return TextEditingValue(
    text: before + inserted + after,
    selection: TextSelection.collapsed(offset: before.length + lead.length + block.length),
  );
}

/// [v] with a table inserted at the cursor, on lines of its own.
TextEditingValue insertTable(TextEditingValue v, int rows, int columns) => insertBlock(v, emptyTable(rows, columns));

/// How the columns of a table are aligned, from its separator line (`:--` left, `:-:` centre, `--:` right, `---` as usual).
List<String> columnAligns(String separator) => [
      for (final s in cellSpans(separator))
        switch ((separator.substring(s.$1, s.$2).trim().startsWith(':'), separator.substring(s.$1, s.$2).trim().endsWith(':'))) {
          (true, true) => 'center',
          (false, true) => 'right',
          (true, false) => 'left',
          _ => '',
        },
    ];

/// What can be done to the table the caret is in.
enum TableAction { rowAbove, rowBelow, deleteRow, columnLeft, columnRight, deleteColumn, alignLeft, alignCenter, alignRight }

/// Where the table the caret is in is: its lines, the row and column of the caret (the head is row 0; on the separator line, the
/// head). Null: the caret is not in a table.
({int start, int end, List<String> lines, int row, int column})? tableAt(String text, int caret) {
  if (caret > text.length) return null;
  // (only the lines around the caret are looked at: this is asked for at each key)
  int lineStart(int at) => at <= 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1;
  int lineEnd(int from) {
    final e = text.indexOf('\n', from);
    return e < 0 ? text.length : e;
  }

  final offset = lineStart(caret);
  final caretEnd = lineEnd(offset);
  final here = text.substring(offset, caretEnd);
  if (!isTableRow(here)) return null;
  var start = offset;
  final block = [here];
  while (start > 0) {
    final from = lineStart(start - 1);
    final line = text.substring(from, start - 1);
    if (!isTableRow(line)) break;
    block.insert(0, line);
    start = from;
  }
  final above = block.length - 1;
  var end = caretEnd;
  while (end < text.length) {
    final to = lineEnd(end + 1);
    final line = text.substring(end + 1, to);
    if (!isTableRow(line)) break;
    block.add(line);
    end = to;
  }
  if (block.length < 2 || !tableSeparator.hasMatch(block[1])) return null;
  // the column: how many cells start before the caret on its line
  final at = caret - offset;
  final spans = cellSpans(here);
  var column = 0;
  for (var k = 0; k < spans.length; k++) {
    if (at >= spans[k].$1) column = k;
  }
  return (start: start, end: end, lines: block, row: above <= 1 ? 0 : above - 1, column: column);
}

/// [v] with [action] done to the table the caret is in; null when the caret is in no table (or it cannot be done: the head and the
/// last column stay).
TextEditingValue? editTable(TextEditingValue v, TableAction action) {
  final caret = v.selection.isValid ? v.selection.start : v.text.length;
  final t = tableAt(v.text, caret);
  if (t == null) return null;
  final rows = <List<String>>[
    for (var i = 0; i < t.lines.length; i++)
      if (i != 1) [for (final s in cellSpans(t.lines[i])) cellText(t.lines[i], s)],
  ];
  final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
  for (final r in rows) {
    while (r.length < width) {
      r.add('');
    }
  }
  final aligns = columnAligns(t.lines[1]);
  while (aligns.length < width) {
    aligns.add('');
  }
  var row = t.row, column = t.column.clamp(0, width - 1);
  switch (action) {
    case TableAction.rowAbove:
      if (row == 0) return null;
      rows.insert(row, List.filled(width, ''));
    case TableAction.rowBelow:
      rows.insert(row + 1, List.filled(width, ''));
      row++;
    case TableAction.deleteRow:
      if (row == 0 || rows.length < 2) return null;
      rows.removeAt(row);
      row = row.clamp(0, rows.length - 1);
    case TableAction.columnLeft || TableAction.columnRight:
      final at = action == TableAction.columnLeft ? column : column + 1;
      for (final r in rows) {
        r.insert(at, '');
      }
      aligns.insert(at, '');
      column = at;
    case TableAction.deleteColumn:
      if (width < 2) return null;
      for (final r in rows) {
        r.removeAt(column);
      }
      aligns.removeAt(column);
      column = column.clamp(0, width - 2);
    case TableAction.alignLeft || TableAction.alignCenter || TableAction.alignRight:
      final want = switch (action) { TableAction.alignCenter => 'center', TableAction.alignRight => 'right', _ => 'left' };
      aligns[column] = aligns[column] == want ? '' : want;
  }
  String line(List<String> r) => '| ${r.map(_escape).join(' | ')} |';
  final sep = '|${aligns.map((a) => switch (a) { 'center' => ' :-: ', 'right' => ' --: ', 'left' => ' :-- ', _ => ' --- ' }).join('|')}|';
  final out = [line(rows.first), sep, for (final r in rows.skip(1)) line(r)];
  final table = out.join('\n');
  // the caret goes into the cell it is about
  final lineIndex = row == 0 ? 0 : row + 1;
  var at = t.start;
  for (var k = 0; k < lineIndex; k++) {
    at += out[k].length + 1;
  }
  final cells = cellSpans(out[lineIndex]);
  final cell = cells[column.clamp(0, cells.length - 1)];
  at += cell.$1 + 1;
  return TextEditingValue(
    text: v.text.replaceRange(t.start, t.end, table),
    selection: TextSelection.collapsed(offset: at.clamp(0, t.start + table.length)),
  );
}
