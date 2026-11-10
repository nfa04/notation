part of 'fixed_page_note_editor.dart';

/// Truth tables: the dialog makes the table of a formula, and "Put on the page" makes a table of it (a text box on a page, the text of
/// the written document).
extension _EditorTruthTable on _FixedPageNoteEditorState {
  Future<void> _insertTruthTable({String initial = ''}) async {
    final cells = await showTruthTable(context, initial: initial);
    if (cells == null || !mounted) return;
    _putTable(cells);
  }

  /// A table of [cells] (the head first) where the person is: at the cursor of the written document, else in a text box on the page in view.
  void _putTable(List<List<String>> cells) {
    final text = tableText(cells);
    if (_mode == CanvasInteractionMode.document) {
      _documentController.value = insertBlock(_documentController.value, text);
      setState(() {}); // the preview shows it
      return;
    }
    final (page, scrolled) = _visiblePage();
    final widths = [for (var c = 0; c < cells.first.length; c++) cells.map((r) => r[c].length).reduce(math.max) * 8.5 + 26];
    final width = widths.fold(0.0, (a, b) => a + b).clamp(160.0, math.max(160.0, _paperWidth - 80)).toDouble();
    _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: text, width: width);
  }

  /// The button that opens the truth table of the line [latex] in a sheet about maths, when the line is a formula of logic.
  Widget _truthTableButton(String latex) {
    if (!_on(Feature.tables) || !looksLogical(normalizeLatex(latex)) || parseFormulaText(latex) == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton.icon(
        key: const ValueKey('math-mark-truth-table'),
        icon: const Icon(Icons.grid_on, size: 18),
        label: Text(tr('Truth table')),
        onPressed: () async {
          final cells = await showTruthTable(context, initial: latex);
          if (cells == null || !mounted) return;
          if (Navigator.of(context).canPop()) Navigator.of(context).pop(); // (the sheet)
          _putTable(cells);
        },
      ),
    );
  }
}
