part of 'fixed_page_note_editor.dart';

/// Text on a line or a shape: words that run along the line (or round the shape), or are written inside the shape. The text belongs to
/// the drawing (`DrawingStroke.label`), so it is moved, copied, resized, hidden and saved with it.
extension _EditorLabels on _FixedPageNoteEditorState {
  /// Whether the selection is one drawing that can have text.
  bool get _mayLabel => _on(Feature.pathText) && _selection.length == 1 && _groupBoxes.isEmpty && _groupImages.isEmpty;

  Future<void> _editLabel() async {
    if (!_mayLabel) return;
    final stroke = _selection.first;
    final before = stroke.label;
    final edit = await showLabelDialog(context, initial: before, lineColor: stroke.color, fill: stroke.fill, closed: stroke.isClosed);
    if (edit == null || !mounted) return;
    final after = edit.label == null || edit.label!.isEmpty ? null : edit.label;
    if (after == before) return;
    void put(StrokeLabel? label) => setState(() => stroke.label = label);
    put(after);
    _undoStack.push(UndoStep(() => put(before), () => put(after)));
    _scheduleSave();
  }
}
