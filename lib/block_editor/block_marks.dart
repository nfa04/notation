part of 'block_editor.dart';

/// What lies over the lines of the document and blinks or follows the caret: the caret itself, and where the handles of a selection are
/// held. On a layer of its own, so that a blink does not draw any line again.
class _BlockMarks extends LeafRenderObjectWidget {
  final BlockEditorState editor;
  const _BlockMarks(this.editor);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBlockMarks(editor, Theme.of(context).colorScheme.primary);

  @override
  void updateRenderObject(BuildContext context, _RenderBlockMarks renderObject) => renderObject.color = Theme.of(context).colorScheme.primary;
}

class _RenderBlockMarks extends RenderBox {
  final BlockEditorState editor;
  Color color;

  _RenderBlockMarks(this.editor, this.color);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    editor._caretTick.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    editor._caretTick.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final e = editor;
    final floating = e._floating;
    if (floating != null) {
      // (a finger is on the space bar: the cursor is where the finger is, the caret where it would be put)
      final snapped = e._rectAt(floating.at.offset, affinity: floating.at.affinity);
      if (snapped != null) context.canvas.drawRect(snapped.shift(offset), Paint()..color = color.withValues(alpha: 0.5));
      context.canvas.drawRect(floating.rect.shift(offset), Paint()..color = color);
    } else if (e._caretShown && e._caretOn) {
      final rect = e._caretRect;
      if (rect != null) context.canvas.drawRect(rect.shift(offset), Paint()..color = color);
    }
    // (the handles follow these)
    final ends = e._selectionEnds();
    if (ends == null) return;
    void leader(LayerLink link, Offset at) => context.pushLayer(LeaderLayer(link: link, offset: at + offset), (_, _) {}, Offset.zero);
    leader(e._startLink, ends.start.bottomLeft);
    leader(e._endLink, ends.end.bottomLeft);
    leader(e._toolbarLink, ends.start.topLeft);
  }
}
