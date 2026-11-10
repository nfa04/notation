import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

import '../markdown/markdown_table.dart';
import '../l10n/language.dart';
import '../style/platform_dialog.dart';

/// Asks how big a table is to be: rows (the head included) and columns.
Future<(int rows, int columns)?> askTableSize(BuildContext context) => showDialog<(int, int)>(
      context: context,
      builder: (_) => const _TableSizeDialog(),
    );

class _TableSizeDialog extends StatefulWidget {
  const _TableSizeDialog();

  @override
  State<_TableSizeDialog> createState() => _TableSizeDialogState();
}

class _TableSizeDialogState extends State<_TableSizeDialog> {
  int _rows = 3, _columns = 3;

  Widget _stepper(String label, String key, int value, int max, ValueChanged<int> set) => Row(children: [
        SizedBox(width: 80, child: Text(label)),
        IconButton(
          key: ValueKey('$key-less'),
          tooltip: tr('Fewer'),
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value > 1 ? () => set(value - 1) : null,
        ),
        SizedBox(key: ValueKey(key), width: 28, child: Text.verbatim('$value', textAlign: TextAlign.center)),
        IconButton(
          key: ValueKey('$key-more'),
          tooltip: tr('More'),
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value < max ? () => set(value + 1) : null,
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: const Text('Insert a table'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepper('Rows', 'table-rows', _rows, 50, (v) => setState(() => _rows = v)),
        _stepper('Columns', 'table-columns', _columns, 12, (v) => setState(() => _columns = v)),
        const SizedBox(height: 12),
        // what it will look like
        SizedBox(
          width: 240,
          child: Table(
            border: TableBorder.all(color: scheme.outline),
            children: [
              for (var r = 0; r < _rows.clamp(1, 6); r++)
                TableRow(
                  decoration: r == 0 ? BoxDecoration(color: scheme.primaryContainer) : null,
                  children: [for (var c = 0; c < _columns.clamp(1, 8); c++) const SizedBox(height: 18)],
                ),
            ],
          ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('table-create'), onPressed: () => Navigator.pop(context, (_rows, _columns)), child: const Text('Insert')),
      ],
    );
  }
}

/// The cells of the table in [source] (Markdown) to type into; every change is written back to it.
/// Tab moves from cell to cell. Rows and columns are added and taken away with the bar above.
class TableEditor extends StatefulWidget {
  final TextEditingController source;
  final double fontSize;
  final Color textColor;

  const TableEditor({super.key, required this.source, required this.fontSize, required this.textColor});

  @override
  State<TableEditor> createState() => _TableEditorState();
}

class _TableEditorState extends State<TableEditor> {
  late List<List<TextEditingController>> _cells;
  late List<List<FocusNode>> _focus;
  String _written = '';
  (int, int) _at = (0, 0);

  @override
  void initState() {
    super.initState();
    _build(parseTableText(widget.source.text) ?? [['']]);
    widget.source.addListener(_sourceChanged);
  }

  @override
  void dispose() {
    widget.source.removeListener(_sourceChanged);
    _free();
    super.dispose();
  }

  void _free() {
    for (final r in _cells) {
      for (final c in r) {
        c.dispose();
      }
    }
    for (final r in _focus) {
      for (final f in r) {
        f.dispose();
      }
    }
  }

  void _build(List<List<String>> rows) {
    _cells = [for (final r in rows) [for (final t in r) TextEditingController(text: t)]];
    _focus = [
      for (var r = 0; r < rows.length; r++)
        [
          for (var c = 0; c < rows[r].length; c++)
            FocusNode()..addListener(() {
              if (_focusOf(r, c).hasFocus) _at = (r, c);
            })
        ],
    ];
    _written = widget.source.text;
  }

  FocusNode _focusOf(int r, int c) => _focus[r][c];

  /// The text was changed from outside (undo, a paste): start from it.
  void _sourceChanged() {
    if (widget.source.text == _written) return;
    final rows = parseTableText(widget.source.text);
    if (rows == null) return;
    setState(() {
      _free();
      _build(rows);
    });
  }

  List<List<String>> get _rows => [for (final r in _cells) [for (final c in r) c.text]];

  void _write() {
    _written = tableText(_rows);
    widget.source.value = TextEditingValue(text: _written, selection: TextSelection.collapsed(offset: _written.length));
  }

  void _restructure(List<List<String>> rows, {(int, int)? focus}) {
    setState(() {
      _free();
      _build(rows);
    });
    _write();
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && focus.$1 < _focus.length && focus.$2 < _focus[focus.$1].length) _focus[focus.$1][focus.$2].requestFocus();
      });
    }
  }

  void _addRow() {
    final rows = _rows, at = _at.$1 + 1;
    rows.insert(at, List.filled(rows.first.length, ''));
    _restructure(rows, focus: (at, _at.$2));
  }

  void _removeRow() {
    final rows = _rows;
    if (rows.length <= 1) return;
    rows.removeAt(_at.$1);
    _restructure(rows, focus: (_at.$1.clamp(0, rows.length - 1), _at.$2));
  }

  void _addColumn() {
    final rows = _rows, at = _at.$2 + 1;
    for (final r in rows) {
      r.insert(at, '');
    }
    _restructure(rows, focus: (_at.$1, at));
  }

  void _removeColumn() {
    final rows = _rows;
    if (rows.first.length <= 1) return;
    for (final r in rows) {
      r.removeAt(_at.$2);
    }
    _restructure(rows, focus: (_at.$1, _at.$2.clamp(0, rows.first.length - 1)));
  }

  Widget _tool(String key, IconData icon, String tip, VoidCallback onTap, {bool enabled = true}) => IconButton(
        key: ValueKey(key),
        tooltip: tr(tip),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        icon: Icon(icon),
        onPressed: enabled ? onTap : null,
      );

  @override
  Widget build(BuildContext context) {
    final line = BorderSide(color: widget.textColor.withValues(alpha: 0.4), width: 0.8);
    final style = TextStyle(fontSize: widget.fontSize, height: 1.3, color: widget.textColor);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Wrap(children: [
        _tool('table-add-row', Icons.table_rows_outlined, 'Add a row below', _addRow),
        _tool('table-remove-row', Icons.playlist_remove, 'Delete this row', _removeRow, enabled: _cells.length > 1),
        _tool('table-add-column', Icons.view_column_outlined, 'Add a column to the right', _addColumn),
        _tool('table-remove-column', Icons.remove_road_outlined, 'Delete this column', _removeColumn, enabled: _cells.first.length > 1),
      ]),
      Table(
        border: TableBorder(top: line, bottom: line, left: line, right: line, horizontalInside: line, verticalInside: line),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          for (var r = 0; r < _cells.length; r++)
            TableRow(
              decoration: r == 0 ? BoxDecoration(color: widget.textColor.withValues(alpha: 0.08)) : null,
              children: [
                for (var c = 0; c < _cells[r].length; c++)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: widget.fontSize * 0.4, vertical: widget.fontSize * 0.2),
                    child: TextField(
                      key: ValueKey('table-cell-$r-$c'),
                      controller: _cells[r][c],
                      focusNode: _focus[r][c],
                      maxLines: null,
                      style: r == 0 ? style.copyWith(fontWeight: FontWeight.bold) : style,
                      cursorColor: widget.textColor,
                      decoration: const InputDecoration(filled: false, border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
                      onChanged: (_) => _write(),
                    ),
                  ),
              ],
            ),
        ],
      ),
    ]);
  }
}
