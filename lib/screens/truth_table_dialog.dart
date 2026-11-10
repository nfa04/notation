import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../algebra/logic.dart';
import '../algebra/truth_table.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// What a person chose to do with the table: put it on the page as these cells (the head first).
typedef TruthTablePut = List<List<String>>;

/// The most rows a table is put on a page with (more would not fit a page; the dialog shows up to 1024).
const _largestOnPage = 64;

/// A dialog for truth tables: type a formula (or two to compare, with `=`), see its table with a column for every part, what kind of
/// formula it is, and its shortest forms. The answer is the cells of the table when it is to be put on the page, else null.
Future<TruthTablePut?> showTruthTable(BuildContext context, {String initial = '', bool canPut = true}) => showDialog<TruthTablePut>(
      context: context,
      builder: (context) => _TruthTableDialog(initial: initial, canPut: canPut),
    );

class _TruthTableDialog extends StatefulWidget {
  final String initial;
  final bool canPut;

  const _TruthTableDialog({required this.initial, required this.canPut});

  @override
  State<_TruthTableDialog> createState() => _TruthTableDialogState();
}

class _TruthTableDialogState extends State<_TruthTableDialog> {
  late final _text = TextEditingController(text: widget.initial);
  bool _letters = false;
  bool _onesFirst = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _insert(String s) {
    final v = _text.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final text = v.text.replaceRange(sel.start, sel.end, s);
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: sel.start + s.length));
    setState(() {});
  }

  LogicLine? get _line => parseFormulaText(_text.text);

  TruthTable? _table(LogicLine line) => buildTruthTable(line.formulas, onesFirst: _onesFirst);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = _line;
    final table = line == null ? null : _table(line);
    final blank = _text.text.trim().isEmpty;
    return PlatformAlertDialog(
      title: const Text('Truth table'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Type a formula: p -> q, !p | q, (p and q) or not r, or in LaTeX. Put = between two formulas to see whether they are the same.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('truth-table-formula'),
              controller: _text,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 0, children: [
              for (final (sign, key) in const [('¬', 'not'), ('∧', 'and'), ('∨', 'or'), ('→', 'implies'), ('↔', 'iff'), ('⊕', 'xor'), ('(', 'open'), (')', 'close'), ('=', 'same')])
                ActionChip(
                  key: ValueKey('truth-table-sign-$key'),
                  visualDensity: VisualDensity.compact,
                  label: Text.verbatim(sign, style: const TextStyle(fontSize: 16)),
                  onPressed: () => _insert(key == 'same' ? ' = ' : sign),
                ),
            ]),
            const SizedBox(height: 8),
            if (blank)
              Wrap(spacing: 8, children: [
                for (final example in const ['p -> q', 'p and (q or r)', '!(p & q) = !p | !q', 'p xor q xor r'])
                  ActionChip(label: Text.verbatim(example), onPressed: () => setState(() => _text.text = example)),
              ])
            else if (line == null)
              Text('I cannot read that as a formula. Use single letters for the statements.', key: const ValueKey('truth-table-problem'), style: TextStyle(color: scheme.error))
            else if (table == null)
              Text('That has too many letters (at most 10).', key: const ValueKey('truth-table-problem'), style: TextStyle(color: scheme.error))
            else ...[
              _summary(context, line, table),
              const SizedBox(height: 8),
              Row(children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [ButtonSegment(value: false, label: Text.verbatim('1 0')), ButtonSegment(value: true, label: Text.verbatim('T F'))],
                  selected: {_letters},
                  onSelectionChanged: (s) => setState(() => _letters = s.first),
                ),
                const SizedBox(width: 12),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: [ButtonSegment(value: false, label: Text('0 first')), ButtonSegment(value: true, label: Text('1 first'))],
                  selected: {_onesFirst},
                  onSelectionChanged: (s) => setState(() => _onesFirst = s.first),
                ),
              ]),
              const SizedBox(height: 8),
              _TableView(table: table, letters: _letters, compare: line.formulas.length > 1),
              const SizedBox(height: 8),
              _forms(context, table),
            ],
          ]),
        ),
      ),
      actions: [
        if (table != null) ...[
          TextButton(
            key: const ValueKey('truth-table-copy-markdown'),
            onPressed: () => _copy(table.markdown(letters: _letters)),
            child: const Text('Copy as Markdown'),
          ),
          TextButton(
            key: const ValueKey('truth-table-copy-latex'),
            onPressed: () => _copy(table.latex(letters: _letters)),
            child: const Text('Copy as LaTeX'),
          ),
        ],
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (widget.canPut)
          FilledButton(
            key: const ValueKey('truth-table-put'),
            onPressed: table == null || table.rows.length > _largestOnPage ? null : () => Navigator.pop(context, table.cells(letters: _letters)),
            child: const Text('Put on the page'),
          ),
      ],
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied'), duration: const Duration(seconds: 2)));
  }

  /// What kind of formula it is, or whether the formulas are the same.
  Widget _summary(BuildContext context, LogicLine line, TruthTable table) {
    final scheme = Theme.of(context).colorScheme;
    Widget chip(String key, String label, Color color, {IconData? icon}) => Chip(
          key: ValueKey(key),
          visualDensity: VisualDensity.compact,
          avatar: icon == null ? null : Icon(icon, size: 16, color: color),
          label: Text.verbatim(label),
          side: BorderSide(color: color.withValues(alpha: 0.6)),
        );
    final n = table.rows.length;
    final chips = <Widget>[];
    if (line.formulas.length == 1) {
      switch (table.kind()) {
        case LogicKind.tautology:
          chips.add(chip('truth-table-kind', tr('Always true (a tautology)'), Colors.green, icon: Icons.check_circle_outline));
        case LogicKind.contradiction:
          chips.add(chip('truth-table-kind', tr('Never true (a contradiction)'), Colors.red, icon: Icons.block));
        case LogicKind.contingent:
          chips.add(chip('truth-table-kind', tr('Sometimes true'), scheme.primary, icon: Icons.tune));
      }
      chips.add(Text.verbatim(' ${table.trueRows()} / $n', style: TextStyle(color: scheme.onSurfaceVariant)));
    } else {
      for (var k = 0; k + 1 < line.formulas.length; k++) {
        if (line.relations[k] == LogicRelation.equivalent) {
          final differ = table.differing(k, k + 1);
          chips.add(differ.isEmpty
              ? chip('truth-table-same', tr('The same in every row'), Colors.green, icon: Icons.check_circle_outline)
              : chip('truth-table-differ', tr('Not the same: they differ in {n} of {total} rows', {'n': differ.length, 'total': n}), Colors.red, icon: Icons.cancel_outlined));
        } else {
          chips.add(table.implies(k, k + 1)
              ? chip('truth-table-follows', tr('The second follows from the first'), Colors.green, icon: Icons.check_circle_outline)
              : chip('truth-table-follows-not', tr('The second does not follow from the first'), Colors.red, icon: Icons.cancel_outlined));
        }
      }
    }
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: chips);
  }

  /// The rows that make the formula true, and its shortest forms.
  Widget _forms(BuildContext context, TruthTable table) {
    final scheme = Theme.of(context).colorScheme;
    String show(Logic? f, String none) => f == null ? none : logicText(f);
    final rows = <(String, String)>[
      (tr('True in rows'), table.minterms().isEmpty ? tr('none') : table.minterms().join(', ')),
      (tr('False in rows'), table.maxterms().isEmpty ? tr('none') : table.maxterms().join(', ')),
      (tr('Shortest sum of products'), show(table.minimalSumOfProducts(), tr('none (it is never true)'))),
      (tr('Shortest product of sums'), show(table.minimalProductOfSums(), tr('none (it is always true)'))),
      (tr('Every true row as a product'), show(table.canonicalSumOfProducts(), tr('none (it is never true)'))),
      (tr('Every false row as a sum'), show(table.canonicalProductOfSums(), tr('none (it is always true)'))),
    ];
    return ExpansionTile(
      key: const ValueKey('truth-table-forms'),
      tilePadding: EdgeInsets.zero,
      title: const Text('Other forms of the formula'),
      subtitle: table.results.length > 1 ? const Text('Of the first formula') : null,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 190, child: Text.verbatim(label, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12))),
              // (the rows and the formulas are signs and numbers; "none ..." is a sentence)
              Expanded(child: value.startsWith(tr('none')) ? Text.verbatim(value, style: const TextStyle(fontSize: 13)) : SelectableText(value, style: const TextStyle(fontSize: 14))),
            ]),
          ),
      ],
    );
  }
}

/// The table: the headers stay above the rows when they scroll; the formulas that were asked about are shaded, and rows in which two
/// formulas differ are marked.
class _TableView extends StatelessWidget {
  final TruthTable table;
  final bool letters;
  final bool compare;

  const _TableView({required this.table, required this.letters, required this.compare});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final headers = [for (var c = 0; c < table.columns.length; c++) table.header(c)];
    final widths = [for (final h in headers) (h.length * 9.0 + 24).clamp(44.0, 320.0)];
    final total = widths.fold(0.0, (a, b) => a + b);
    final results = table.results.toSet();
    final differing = compare ? table.differing(0, 1).toSet() : const <int>{};
    final border = BorderSide(color: scheme.outlineVariant);
    Widget cell(int c, Widget child, {Color? color, bool header = false}) => Container(
          width: widths[c],
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
          decoration: BoxDecoration(
            color: color,
            border: Border(
              right: c == table.variableCount - 1 ? BorderSide(color: scheme.outline, width: 2) : border,
              bottom: header ? BorderSide(color: scheme.outline, width: 2) : border,
            ),
          ),
          child: child,
        );
    final rowCount = table.rows.length;
    return Container(
      key: const ValueKey('truth-table-view'),
      decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(6)),
      height: (rowCount * 30.0 + 36).clamp(96.0, 320.0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: total,
          child: Column(children: [
            Row(children: [
              for (var c = 0; c < headers.length; c++)
                cell(c, Text.verbatim(headers[c], style: TextStyle(fontWeight: results.contains(c) ? FontWeight.bold : FontWeight.w500, fontSize: 14)),
                    color: results.contains(c) ? scheme.primaryContainer.withValues(alpha: 0.5) : scheme.surfaceContainerHighest, header: true),
            ]),
            Expanded(
              child: ListView.builder(
                itemCount: rowCount,
                itemExtent: 30,
                itemBuilder: (context, r) {
                  final row = table.rows[r];
                  return Container(
                    color: differing.contains(r) ? Colors.red.withValues(alpha: 0.12) : null,
                    child: Row(children: [
                      for (var c = 0; c < headers.length; c++)
                        cell(
                          c,
                          Text.verbatim(row[c] ? (letters ? 'T' : '1') : (letters ? 'F' : '0'),
                              style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 14,
                                  fontWeight: results.contains(c) ? FontWeight.bold : FontWeight.normal,
                                  color: c >= table.variableCount && !row[c] ? scheme.onSurfaceVariant : null)),
                          color: results.contains(c) && !differing.contains(r) ? (row[c] ? Colors.green.withValues(alpha: 0.14) : Colors.red.withValues(alpha: 0.08)) : null,
                        ),
                    ]),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
