import 'package:flutter/services.dart';

import 'table_formulas.dart';

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

/// The separator line of a table: `|---|:-:|`, with the alignment [aligns] says for each column ('left', 'center', 'right', else none).
String tableSeparatorLine(int width, [List<String> aligns = const []]) =>
    '|${[for (var c = 0; c < width; c++) switch (c < aligns.length ? aligns[c] : '') { 'center' => ' :-: ', 'right' => ' --: ', 'left' => ' :-- ', _ => ' --- ' }].join('|')}|';

/// Markdown for [rows] (the first is the head), the columns aligned as [aligns] says (see [columnAligns]).
String tableText(List<List<String>> rows, {List<String> aligns = const []}) {
  final width = rows.isEmpty ? 1 : rows.first.length;
  String line(List<String> r) => '| ${r.map(_escape).join(' | ')} |';
  return [
    line(rows.first),
    tableSeparatorLine(width, aligns),
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
enum TableAction { rowAbove, rowBelow, deleteRow, columnLeft, columnRight, deleteColumn, alignLeft, alignCenter, alignRight, sortAscending, sortDescending, totals }

/// [rows] (the head first) with the rows under the head put in order of column [column] (zero-based): numbers by value, other text
/// alphabetically without regard to case, empty cells last. Rows of equal key stay in their order. Rows at the end that add up a
/// range (a row of totals) stay at the end. A formula that names a cell of its own row (`=B3*C3`) follows its row to the new place.
List<List<String>> sortedTable(List<List<String>> rows, int column, {bool descending = false}) {
  if (rows.length < 3) return rows;
  var end = rows.length;
  while (end > 2 && _addsUp(rows[end - 1])) {
    end--;
  }
  final shown = worked(rows);
  final order = [for (var r = 1; r < end; r++) r];
  String text(int r) => column < shown[r].length ? shown[r][column] : '';
  int compare(int a, int b) {
    final ta = text(a).trim(), tb = text(b).trim();
    // (empty cells are last whichever way it goes)
    if (ta.isEmpty || tb.isEmpty) return ta.isEmpty && tb.isEmpty ? 0 : (ta.isEmpty ? 1 : -1);
    final na = parseCellNumber(ta), nb = parseCellNumber(tb);
    int c;
    if (na != null && nb != null) {
      c = na.compareTo(nb);
    } else if (na != null || nb != null) {
      c = na != null ? -1 : 1; // numbers before words
    } else {
      c = ta.toLowerCase().compareTo(tb.toLowerCase());
    }
    return descending ? -c : c;
  }

  order.sort((a, b) {
    final c = compare(a, b);
    return c != 0 ? c : a.compareTo(b);
  });
  final out = <List<String>>[rows.first];
  for (var i = 0; i < order.length; i++) {
    final from = order[i], to = i + 1;
    out.add(from == to ? rows[from] : [for (final cell in rows[from]) isFormula(cell) ? _moveRow(cell, from + 1, to + 1) : cell]);
  }
  out.addAll(rows.sublist(end));
  return out;
}

/// Whether [row] is a row of totals: a formula in it works on a range of cells (`=SUM(B2:B9)`).
bool _addsUp(List<String> row) => row.any((c) => isFormula(c) && c.contains(':'));

/// The formula [cell] with the cells named in row [from] named in row [to] instead (rows counted as the cell names count them).
String _moveRow(String cell, int from, int to) => cell.replaceAllMapped(RegExp(r'\b([A-Za-z]{1,3})(\d{1,5})\b'), (m) {
      final n = int.parse(m.group(2)!);
      if (n != from) return m.group(0)!;
      // (not a cell of a range: the range keeps its ends)
      final after = cell.substring(m.end);
      final before = cell.substring(0, m.start);
      if (after.trimLeft().startsWith(':') || before.trimRight().endsWith(':')) return m.group(0)!;
      return '${m.group(1)}$to';
    });

/// [rows] with a row of totals added: "Total" in the first column and the sum of every column that holds numbers only (a row of
/// totals already there is not added again).
List<List<String>> withTotals(List<List<String>> rows) {
  if (rows.length < 2) return rows;
  final width = rows.first.length;
  if (_addsUp(rows.last)) return rows;
  final shown = worked(rows);
  final last = rows.length; // the spreadsheet number of the last row
  bool numbers(int c) {
    final cells = [for (var r = 1; r < rows.length; r++) if (c < shown[r].length && shown[r][c].trim().isNotEmpty) shown[r][c]];
    return cells.isNotEmpty && cells.every((t) => parseCellNumber(t) != null);
  }

  final total = <String>[
    for (var c = 0; c < width; c++)
      if (c == 0) 'Total' else if (numbers(c)) '=SUM(${columnName(c)}2:${columnName(c)}$last)' else '',
  ];
  return [...rows, total];
}

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
    case TableAction.sortAscending || TableAction.sortDescending:
      if (rows.length < 3) return null;
      final sorted = sortedTable(rows, column, descending: action == TableAction.sortDescending);
      rows
        ..clear()
        ..addAll(sorted);
      row = 0;
    case TableAction.totals:
      final more = withTotals(rows);
      if (more.length == rows.length) return null;
      rows.add(more.last);
      row = rows.length - 1;
    case TableAction.alignLeft || TableAction.alignCenter || TableAction.alignRight:
      final want = switch (action) { TableAction.alignCenter => 'center', TableAction.alignRight => 'right', _ => 'left' };
      aligns[column] = aligns[column] == want ? '' : want;
  }
  String line(List<String> r) => '| ${r.map(_escape).join(' | ')} |';
  final sep = tableSeparatorLine(rows.first.length, aligns);
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
