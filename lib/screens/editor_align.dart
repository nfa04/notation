part of 'fixed_page_note_editor.dart';

/// Lines that show where a thing being moved lines up with the others on the page, and a pull that makes it fall into place.
extension _EditorAlign on _FixedPageNoteEditorState {
  /// How far [moving] (the box of what is dragged, on [page]) is to be nudged so that it lines up with something, and the lines for the
  /// page to show meanwhile. Holding Alt, or the feature being off, moves it freely. [exclude] is what is being moved (it does not line up with itself).
  Offset _alignMoved(int page, Rect moving, {required Set<Object> exclude}) {
    if (!_on(Feature.alignLines) || HardwareKeyboard.instance.isAltPressed) {
      _alignLines = const [];
      return Offset.zero;
    }
    final snap = alignWhileMoving(moving, _alignTargets(page, exclude), Size(_paperWidth, _heightOf(page)));
    _alignLines = snap.lines;
    _alignPage = page;
    return snap.delta;
  }

  /// The boxes on [page] that a moved thing lines up with: text boxes and pictures, and the drawings that are shapes (a closed or
  /// filled line, a curve of the pen tool, a straight line). Handwriting is left out: every stroke of it would pull.
  List<Rect> _alignTargets(int page, Set<Object> exclude) {
    final out = <Rect>[];
    for (final b in _textBoxesPerPage[page] ?? const <TextBoxWidgetModel>[]) {
      if (!exclude.contains(b) && !_inGutter(b)) out.add(_boxRect(b));
    }
    for (final m in _imagesPerPage[page] ?? const <ImageItem>[]) {
      if (!exclude.contains(m)) out.add(m.position & m.size);
    }
    for (final s in _strokesPerPage[page] ?? const <DrawingStroke>[]) {
      if (exclude.contains(s) || s.points.length < 2 || !_layers.editable(s)) continue;
      final shape = s.isClosed || s.fill != null || s.curve != null || s.points.length <= 8;
      if (!shape) continue;
      var r = Rect.fromPoints(s.points.first, s.points.first);
      for (final p in s.points) {
        r = r.expandToInclude(Rect.fromPoints(p, p));
      }
      if (r.longestSide >= 24) out.add(r); // (a dot or a tick of handwriting is not something to line up with)
    }
    return out;
  }

  Widget _alignLinesLayer(double pageHeight) => IgnorePointer(
        child: CustomPaint(
          key: const ValueKey('align-lines'),
          painter: AlignLinesPainter(_alignLines),
          size: Size(_paperWidth, pageHeight),
        ),
      );
}
