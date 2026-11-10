part of 'fixed_page_note_editor.dart';

/// Putting closed shapes together: join, overlap, cut out.
extension _EditorShapeOps on _FixedPageNoteEditorState {
  /// The selected lines that are closed shapes, lowest on the page first.
  List<DrawingStroke> _selectedShapes() {
    final list = _strokesPerPage[_selectedStrokePage] ?? const <DrawingStroke>[];
    return [for (final s in list) if (_selection.contains(s) && s.isClosed && s.link == null) s];
  }

  bool get _mayCombine => _on(Feature.shapes) && _selectedShapes().length >= 2;

  /// Replaces the selected closed shapes with the result of [op], in the look of the lowest one, as one step to take back.
  void _combineSelected(ShapeOp op) {
    final shapes = _selectedShapes();
    if (shapes.length < 2) return;
    final page = _selectedStrokePage;
    final outlines = combineShapes([for (final s in shapes) s.points], op);
    final base = shapes.first;
    // (a hole is an outline inside another: it is not filled)
    bool hole(int i, List<Offset> o) => i > 0 && outlines.take(i).any((big) => insideOutline(big, o.first));
    final made = <DrawingStroke>[
      for (final (i, o) in outlines.indexed)
        DrawingStroke(
          color: base.color,
          width: base.width,
          points: o,
          author: Authorship.current,
          dash: base.dash,
          fill: hole(i, o) ? null : base.fill,
          gradient: hole(i, o) ? null : base.gradient,
          brush: base.brush,
          layer: base.layer,
        ),
    ];
    final list = _strokesPerPage.putIfAbsent(page, () => []);
    final at = list.indexOf(base);
    final removed = [for (final s in shapes) (index: list.indexOf(s), stroke: s)];
    void apply() {
      setState(() {
        list.removeWhere(shapes.contains);
        list.insertAll(at.clamp(0, list.length), made);
        _selection = List.of(made);
      });
    }

    apply();
    _undoStack.push(UndoStep(
      () {
        list.removeWhere(made.contains);
        for (final r in removed..sort((a, b) => a.index.compareTo(b.index))) {
          list.insert(r.index.clamp(0, list.length), r.stroke);
        }
        _selection = List.of(shapes);
      },
      apply,
    ));
  }

  /// The button that opens the menu of ways to put the selected shapes together.
  Widget _combineButton() => PopupMenuButton<ShapeOp>(
        key: const ValueKey('combine-shapes'),
        tooltip: tr('Put the shapes together'),
        icon: const Icon(Icons.join_full_outlined),
        padding: EdgeInsets.zero,
        iconSize: 24,
        onSelected: _combineSelected,
        itemBuilder: (_) => [
          for (final op in ShapeOp.values)
            PopupMenuItem(key: ValueKey('combine-${op.name}'), value: op, child: Text(tr(op.label))),
        ],
      );
}
