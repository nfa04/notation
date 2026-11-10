part of 'fixed_page_note_editor.dart';

/// The pen for curves: points are put on the page one by one, a drag at a point pulls its handles and so bends the line through it,
/// and a point or a handle that is already there is pulled to another place. The line is finished by a tap on its last point (open),
/// a tap on its first point (closed) or the buttons beside it; it is then a line like any other (one `DrawingStroke`).
extension _EditorPenTool on _FixedPageNoteEditorState {
  /// Whether a touch of the page works the pen for curves.
  bool get _penToolOn => _mode == CanvasInteractionMode.draw && _shape == ShapeTool.bezier && !_erasing && !_lassoing && _activeDrawTool == null;

  /// How near a touch has to be to a point or a handle to take hold of it.
  static const _penReach = 14.0;

  void _penToolDown(int pageIndex, Offset at, {bool touch = false}) {
    if (_penPath != null && _penPage != pageIndex) _finishPenPath(); // (on another page: the line in hand is finished first)
    setState(() {
      final path = _penPath ??= CurvedPath();
      _penPage = pageIndex;
      _penLast = at;
      final hit = path.hit(at, touch ? _penReach * 1.5 : _penReach);
      if (hit != null) {
        _penGrab = (node: hit.node, part: hit.part, created: false);
        return;
      }
      path.nodes.add(PathNode(at));
      _penGrab = (node: path.nodes.length - 1, part: PathPart.out, created: true); // (a drag from here pulls its handles)
    });
  }

  void _penToolMove(Offset at) {
    final path = _penPath, grab = _penGrab;
    if (path == null || grab == null) return;
    final node = path.nodes[grab.node];
    switch (grab.part) {
      case PathPart.point:
        node.moveBy(at - _penLast);
      case PathPart.out:
        if ((at - node.at).distance > 3) node.pullOut(at); // (a tap with a little shake is a corner, not a curve)
      case PathPart.inn:
        if ((at - node.at).distance > 3) node.pullIn(at);
    }
    _penLast = at;
    _penHover = at;
    _inkTick.value++;
  }

  /// The pen is lifted: a tap on a point that was there finishes the line (on the first point: closed; on the last: open) or, on one
  /// between, makes it a corner.
  void _penToolUp() {
    final path = _penPath, grab = _penGrab;
    _penGrab = null;
    if (path == null || grab == null) return;
    if (!grab.created && grab.part == PathPart.point && _travel < 6) {
      if (path.nodes.length >= 2 && grab.node == 0) return _finishPenPath(close: true);
      if (path.nodes.length >= 2 && grab.node == path.nodes.length - 1) return _finishPenPath();
      path.nodes[grab.node].sharpen();
    }
    setState(() {});
    _inkTick.value++;
  }

  /// Whether the selection is one line of the pen for curves, whose points can be pulled again.
  bool get _mayEditCurve => _on(Feature.shapes) && _selection.length == 1 && _groupBoxes.isEmpty && _groupImages.isEmpty && _selection.first.curve != null;

  /// Shows the points and handles of the selected line, to be pulled again; the pen for curves is the tool then. The line is drawn by
  /// the points while they are shown, and when they are let go of (a tap on the last point, the check, another tool) the line follows them.
  void _editCurve() {
    if (!_mayEditCurve) return;
    final stroke = _selection.first;
    final page = _selectedStrokePage;
    final fitted = stroke.curve!.fittedTo(stroke.points);
    if (fitted == null) {
      // it was changed some other way since the pen made it: there is nothing to pull any more
      setState(() => stroke.curve = null);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr('This line was changed after it was drawn: its points are gone.'))));
      return;
    }
    if (_mode != CanvasInteractionMode.draw) _selectMode(CanvasInteractionMode.draw);
    setState(() {
      _clearSelection();
      _penPath = fitted;
      _penPage = page;
      _penEditing = stroke;
      _penGrab = null;
      _penHover = null;
      _shape = ShapeTool.bezier;
      _chosenDrawTool = null;
      _erasing = false;
      _lassoing = false;
      _lassoPath = null;
    });
  }

  /// Makes the line a stroke of the page, as one step to take back; a line of one point is nothing.
  void _finishPenPath({bool close = false}) {
    final path = _penPath;
    if (path == null) return;
    _penPath = null;
    _penGrab = null;
    _penHover = null;
    final page = _penPage;
    final editing = _penEditing;
    _penEditing = null;
    if (close && path.nodes.length >= 2) path.closed = true;
    final points = path.points();
    if (!path.drawable || points.length < 2) {
      setState(() {});
      return;
    }
    if (editing != null) {
      // the points of a line that was there: the line is bent, and bending it can be taken back
      final oldPoints = List.of(editing.points), oldCurve = editing.curve, oldPressures = editing.pressures;
      void put(List<Offset> pts, CurvedPath? curve, List<int>? pressures) => setState(() {
            editing.points
              ..clear()
              ..addAll(pts);
            editing.pressures = pressures;
            editing.curve = curve;
          });
      put(points, path, null);
      _undoStack.push(UndoStep(() => put(oldPoints, oldCurve, oldPressures), () => put(points, path.copy(), null)));
      return;
    }
    final stroke = DrawingStroke(
      color: _selectedPenColor,
      width: _strokeWidth,
      points: points,
      author: Authorship.current,
      dash: _shapeDash,
      fill: path.closed ? _shapeFill : null,
      gradient: path.closed ? _shapeGradient : null,
      brush: penBrushId,
      layer: _placeLayer,
      curve: path.copy(), // (kept with the line, so that its points can be pulled again)
    );
    setState(() {
      _clearSelection();
      _strokesPerPage.putIfAbsent(page, () => []).add(stroke);
      _undoStack.push(UndoStep(
        () => _strokesPerPage[page]?.remove(stroke),
        () => _strokesPerPage.putIfAbsent(page, () => []).add(stroke),
      ));
    });
  }

  void _cancelPenPath() {
    setState(() {
      _penEditing = null; // (the line that was being bent stays as it was)
      _penPath = null;
      _penGrab = null;
      _penHover = null;
    });
  }

  /// Takes the last point back.
  void _undoPenPoint() {
    final path = _penPath;
    if (path == null) return;
    setState(() {
      if (path.nodes.isNotEmpty) path.nodes.removeLast();
      if (path.nodes.isEmpty) {
        _penPath = null;
        _penEditing = null;
      }
      _penGrab = null;
    });
    _inkTick.value++;
  }

  /// The line as it is so far, with its points and handles: over the page, taking no touches.
  Widget _penToolLayer(int pageIndex, double pageHeight) {
    final path = _penPath;
    if (path == null || _penPage != pageIndex) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          key: const ValueKey('pen-path'),
          painter: _PenPathPainter(path, () => _penGrab == null ? _penHover : null, _penEditing?.color ?? _selectedPenColor, _penEditing?.width ?? _strokeWidth, Theme.of(context).colorScheme.primary, repaint: _inkTick),
          size: Size(_paperWidth, pageHeight),
        ),
      ),
    );
  }

  /// The buttons beside the last point: finish, finish closed, take the last point back, drop the line.
  Widget _penToolBar(int pageIndex, double pageHeight) {
    final path = _penPath;
    if (path == null || _penPage != pageIndex || path.isEmpty) return const SizedBox.shrink();
    final last = path.nodes.last.at;
    final scheme = Theme.of(context).colorScheme;
    Widget button(String key, IconData icon, String tip, VoidCallback? onTap) => IconButton(
          key: ValueKey(key),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          icon: Icon(icon),
          onPressed: onTap,
        );
    return Positioned(
      left: (last.dx - 80).clamp(4.0, math.max(4.0, _paperWidth - 172)),
      top: last.dy > 80 ? last.dy - 60 : math.min(last.dy + 28, math.max(0.0, pageHeight - 48)),
      child: Material(
        elevation: 3,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          button('pen-done', Icons.check, tr('Finish the line'), path.drawable ? _finishPenPath : null),
          button('pen-close', Icons.change_history_outlined, tr('Close the shape'), path.drawable ? () => _finishPenPath(close: true) : null),
          button('pen-undo-point', Icons.undo, tr('Take the last point back'), _undoPenPoint),
          button('pen-cancel', Icons.close, tr('Drop the line'), _cancelPenPath),
        ]),
      ),
    );
  }
}

/// The line the pen for curves is making: the curve in the pen's colour (a stretch on to the pen when it hovers), the handles of the
/// points as thin lines to little circles, the points as squares (the first one as a ring when the line can be closed on it).
class _PenPathPainter extends CustomPainter {
  final CurvedPath path;
  final Offset? Function() hover;
  final Color color;
  final double width;
  final Color accent;

  _PenPathPainter(this.path, this.hover, this.color, this.width, this.accent, {required Listenable repaint}) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (path.isEmpty) return;
    final to = hover();
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Path through(List<Offset> pts) {
      final p = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final q in pts.skip(1)) {
        p.lineTo(q.dx, q.dy);
      }
      return p;
    }

    final drawn = path.points();
    if (drawn.length > 1) canvas.drawPath(through(drawn), line);
    if (to != null && !path.closed) {
      final ahead = path.points(to: to);
      final from = drawn.length - 1;
      if (ahead.length > from + 1) canvas.drawPath(through(ahead.sublist(from)), line..color = color.withValues(alpha: color.a * 0.4));
    }

    final thin = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final fill = Paint()..color = Colors.white;
    for (var i = 0; i < path.nodes.length; i++) {
      final n = path.nodes[i];
      for (final h in [n.out, n.inn]) {
        if (h == null) continue;
        canvas.drawLine(n.at, h, thin);
        canvas.drawCircle(h, 4, fill);
        canvas.drawCircle(h, 4, thin);
      }
    }
    for (var i = 0; i < path.nodes.length; i++) {
      final at = path.nodes[i].at;
      final closable = i == 0 && path.nodes.length >= 2;
      final r = closable ? 7.0 : 5.0;
      final box = Rect.fromCenter(center: at, width: r * 2, height: r * 2);
      if (closable) {
        canvas.drawCircle(at, r, fill);
        canvas.drawCircle(at, r, thin..strokeWidth = 2);
      } else {
        canvas.drawRect(box, fill);
        canvas.drawRect(box, thin..strokeWidth = 1.5);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PenPathPainter old) => true;
}
