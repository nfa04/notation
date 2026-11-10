part of 'fixed_page_note_editor.dart';

/// The fill bucket: a touch inside a closed area of a drawing fills it with the pen's color. The area is found from the lines round
/// the touch (see `region_fill.dart`; a small gap in them can be closed), and the fill is a shape of its own, a closed line with a
/// fill and no line of its own, put under the lines of its layer. So it is recolored, moved, hidden with its layer or taken back like
/// any shape, and the lines drawn after it lie over it. Pictures and text boxes are not walls: only lines close an area.
extension _EditorFillBucket on _FixedPageNoteEditorState {
  /// Whether the bucket takes the touches of the pen now.
  bool get _bucketOn => _bucket && _mode == CanvasInteractionMode.draw && !_erasing && !_lassoing && _on(Feature.fillBucket);

  /// Switches the bucket on or off (from the button or the key); the draw mode is gone to if needed.
  void _toggleBucket() {
    if (_mode != CanvasInteractionMode.draw) _selectMode(CanvasInteractionMode.draw);
    setState(() {
      _bucket = !_bucket;
      if (_bucket) {
        _picking = false;
        _erasing = false;
        _lassoing = false;
        _lassoPath = null;
        _highlighter = false;
        _brush = penBrushId;
        _chosenDrawTool = null;
      }
    });
  }

  /// Fills the area round [at] on page [pageIndex] ([paper] is the size of the page; the infinite canvas has no edge to close an area).
  void _fillAt(int pageIndex, Offset at, Size paper) {
    if (!_drawingLayer.editable) return _layerBlocked();
    final list = _strokesPerPage.putIfAbsent(pageIndex, () => []);
    final walls = [for (final s in list) if (_layers.byId(s.layer).visible) s];
    final found = regionAround(at, walls, page: _infinite ? null : Offset.zero & paper, gap: _fillGap.units);
    final outline = found.outline;
    if (outline == null) {
      final text = switch (found.problem!) {
        RegionProblem.noLines => 'There are no lines to close an area yet: draw the outline first.',
        RegionProblem.open => 'That area is not closed. Close the lines, or turn gap closing up (the button beside the bucket).',
        RegionProblem.onLine => 'That is on a line: touch the area beside it.',
      };
      ScaffoldMessenger.maybeOf(context)
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(key: const ValueKey('fill-bucket-message'), content: Text(tr(text))));
      return;
    }
    final layer = _placeLayer;
    final made = DrawingStroke(
      color: const Color(0x00000000),
      width: 1,
      points: outline,
      author: Authorship.current,
      fill: _selectedPenColor,
      layer: layer,
    );
    // (a fill already there for this area is replaced, so that filling again in another color does not pile them up)
    final box = _boundsOfPoints(outline).inflate(3);
    final replaced = [
      for (final (i, s) in list.indexed)
        if (isBucketFill(s) && s.layer == layer && pointInPolygon(at, s.points) && box.contains(_boundsOfPoints(s.points).topLeft) && box.contains(_boundsOfPoints(s.points).bottomRight)) (index: i, stroke: s),
    ];
    // (under the lines: after the fills that are there already)
    int placeAt() {
      final first = list.indexWhere((s) => !isBucketFill(s));
      return first < 0 ? list.length : first;
    }

    void apply() {
      setState(() {
        for (final r in replaced) {
          list.remove(r.stroke);
        }
        list.insert(placeAt(), made);
      });
    }

    apply();
    _undoStack.push(UndoStep(
      () {
        list.remove(made);
        for (final r in replaced) {
          list.insert(r.index.clamp(0, list.length), r.stroke);
        }
      },
      apply,
    ));
  }

  Rect _boundsOfPoints(List<Offset> points) {
    var l = double.infinity, t = double.infinity, r = double.negativeInfinity, b = double.negativeInfinity;
    for (final p in points) {
      l = math.min(l, p.dx);
      r = math.max(r, p.dx);
      t = math.min(t, p.dy);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  /// How big a gap in the lines still closes an area.
  Widget _fillGapButton() => PopupMenuButton<FillGap>(
        key: const ValueKey('fill-gap'),
        tooltip: tr('Gap closing: how big a gap in the lines still closes an area'),
        padding: EdgeInsets.zero,
        iconSize: 20,
        icon: const Icon(Icons.hdr_strong_outlined, size: 20),
        onSelected: (gap) => setState(() => _fillGap = gap),
        itemBuilder: (_) => [
          for (final gap in FillGap.values)
            CheckedPopupMenuItem(key: ValueKey('fill-gap-${gap.name}'), value: gap, checked: gap == _fillGap, child: Text(tr(gap.label))),
        ],
      );
}
