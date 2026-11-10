part of 'fixed_page_note_editor.dart';

/// How the selected drawings are being bent (see [_TransformSession]).
enum TransformKind { distort, perspective, skew, rotate, warp }

/// One go at transforming the selected drawings, from the button until "done" or "cancel". Every change is made from the lines as
/// they were when the kind was chosen ([base]); the whole go is one step to take back, to the lines as they were at [start].
class _TransformSession {
  final int page;
  final List<DrawingStroke> strokes;
  final List<List<Offset>> startPoints;
  final List<List<int>?> startPressures;
  List<List<Offset>> basePoints;
  List<List<int>?> basePressures;
  Rect bounds;
  List<Offset> quad;
  WarpGrid? grid;
  TransformKind kind = TransformKind.distort;

  /// While a handle is held: what the quad / net was when it was taken, and how far it has been pulled (page units).
  List<Offset>? dragQuad;
  WarpGrid? dragGrid;
  Offset pulled = Offset.zero;

  _TransformSession(this.page, this.strokes)
      : startPoints = [for (final s in strokes) List.of(s.points)],
        startPressures = [for (final s in strokes) s.pressures == null ? null : List.of(s.pressures!)],
        basePoints = [for (final s in strokes) List.of(s.points)],
        basePressures = [for (final s in strokes) s.pressures == null ? null : List.of(s.pressures!)],
        bounds = Rect.zero,
        quad = const [] {
    _measure();
  }

  void _measure() {
    var r = boundsOfPoints(basePoints.expand((p) => p));
    if (r.width < 1) r = Rect.fromCenter(center: r.center, width: 1, height: r.height);
    if (r.height < 1) r = Rect.fromCenter(center: r.center, width: r.width, height: 1);
    bounds = r;
    quad = quadOf(r);
    grid = null;
  }

  /// Makes what the lines are now the start of the next kind of change.
  void rebase() {
    basePoints = [for (final s in strokes) List.of(s.points)];
    basePressures = [for (final s in strokes) s.pressures == null ? null : List.of(s.pressures!)];
    _measure();
  }

  /// The place of all that is moved, for the tools to sit above.
  Rect get area => kind == TransformKind.warp && grid != null ? boundsOfPoints(grid!.points) : boundsOfPoints(quad);
}

extension _EditorFreeTransform on _FixedPageNoteEditorState {
  /// The drawings the transform works on: the selected lines (a connector follows what it joins, so it is left out; text boxes and
  /// pictures cannot be bent and stay where they are).
  List<DrawingStroke> get _transformable => [for (final s in _selection) if (s.link == null && s.points.length >= 2) s];

  bool get _mayTransform => _on(Feature.freeTransform) && _transformable.isNotEmpty && _xform == null;

  void _beginTransform() {
    if (!_mayTransform) return;
    final page = _selectedStrokePage;
    setState(() => _xform = _TransformSession(page, _transformable));
  }

  void _setTransformKind(TransformKind kind) {
    final x = _xform;
    if (x == null || x.kind == kind) return;
    setState(() {
      x.rebase();
      x.kind = kind;
      if (kind == TransformKind.warp) {
        // the lines get points to bend (a long straight step cannot become a curve)
        final step = math.max(4.0, x.bounds.shortestSide / 24).clamp(4.0, 40.0).toDouble();
        for (var i = 0; i < x.strokes.length; i++) {
          final fine = refinedLine(x.basePoints[i], x.basePressures[i], step);
          x.strokes[i].points
            ..clear()
            ..addAll(fine.points);
          x.strokes[i].pressures = fine.pressures;
        }
        x.rebase();
        x.grid = WarpGrid.identity(x.bounds);
      }
    });
  }

  /// Puts the lines where the quad / net says, from [_TransformSession.basePoints].
  void _applyTransform() {
    final x = _xform;
    if (x == null) return;
    final PointMap map;
    if (x.kind == TransformKind.warp) {
      final g = x.grid;
      if (g == null) return;
      map = g.apply;
    } else {
      final h = Homography.rectToQuad(x.bounds, x.quad);
      if (h == null) return;
      map = h.apply;
    }
    for (var i = 0; i < x.strokes.length; i++) {
      final from = x.basePoints[i];
      final to = x.strokes[i].points;
      if (to.length != from.length) {
        to
          ..clear()
          ..addAll(from);
      }
      for (var k = 0; k < from.length; k++) {
        to[k] = map(from[k]);
      }
      x.strokes[i].pressures = x.basePressures[i] == null ? null : List.of(x.basePressures[i]!);
    }
  }

  void _resetTransform() {
    final x = _xform;
    if (x == null) return;
    setState(() {
      _restoreStart(x);
      x.rebase();
      if (x.kind == TransformKind.warp) x.grid = WarpGrid.identity(x.bounds);
    });
  }

  void _restoreStart(_TransformSession x) {
    for (var i = 0; i < x.strokes.length; i++) {
      x.strokes[i].points
        ..clear()
        ..addAll(x.startPoints[i]);
      x.strokes[i].pressures = x.startPressures[i] == null ? null : List.of(x.startPressures[i]!);
    }
  }

  void _cancelTransform() {
    final x = _xform;
    if (x == null) return;
    setState(() {
      _restoreStart(x);
      _xform = null;
      _penDown = false;
    });
  }

  /// Keeps the new shape: one step to take back, and the note is saved.
  void _finishTransform() {
    final x = _xform;
    if (x == null) return;
    final endPoints = [for (final s in x.strokes) List.of(s.points)];
    final endPressures = [for (final s in x.strokes) s.pressures == null ? null : List.of(s.pressures!)];
    var changed = false;
    for (var i = 0; i < endPoints.length && !changed; i++) {
      final a = endPoints[i], b = x.startPoints[i];
      changed = a.length != b.length;
      for (var k = 0; k < a.length && !changed; k++) {
        changed = a[k] != b[k];
      }
    }
    setState(() {
      _xform = null;
      _penDown = false;
    });
    if (!changed) return;
    void put(List<List<Offset>> points, List<List<int>?> pressures) => setState(() {
          for (var i = 0; i < x.strokes.length; i++) {
            x.strokes[i].points
              ..clear()
              ..addAll(points[i]);
            x.strokes[i].pressures = pressures[i] == null ? null : List.of(pressures[i]!);
          }
        });
    _undoStack.push(UndoStep(() => put(x.startPoints, x.startPressures), () => put(endPoints, endPressures)));
    _scheduleSave();
  }

  // ---- handles ---------------------------------------------------------------

  void _holdHandle() {
    final x = _xform;
    if (x == null) return;
    x.dragQuad = List.of(x.quad);
    x.dragGrid = x.grid?.copy();
    x.pulled = Offset.zero;
    setState(() => _penDown = true); // (the page does not scroll along with a finger that pulls a handle)
  }

  void _dropHandle() {
    final x = _xform;
    if (x == null) return;
    x.dragQuad = null;
    x.dragGrid = null;
    setState(() => _penDown = false);
  }

  /// A handle moved by [screenDelta]: [change] makes the new quad from the one at the start of the pull and the whole pull so far.
  void _pullHandle(Offset screenDelta, {List<Offset> Function(List<Offset> base, Offset pulled)? quad, WarpGrid Function(WarpGrid base, Offset pulled)? net}) {
    final x = _xform;
    if (x == null || x.dragQuad == null) return;
    x.pulled += turnedBy(screenDelta, -_viewTurn) / _pageScale;
    setState(() {
      if (net != null && x.dragGrid != null) {
        x.grid = net(x.dragGrid!, x.pulled);
      } else if (quad != null) {
        final next = quad(x.dragQuad!, x.pulled);
        if (Homography.rectToQuad(x.bounds, next) == null) return; // (a shape that folds is not followed)
        x.quad = next;
      }
      _applyTransform();
    });
  }

  Widget _handleDot(Offset at, String key, {required void Function(Offset delta) onPull, bool square = false, Color? fill}) {
    final k = _uiScale;
    final grab = 34.0 * k;
    final primary = Theme.of(context).colorScheme.primary;
    return Positioned(
      key: ValueKey(key),
      left: at.dx - grab / 2,
      top: at.dy - grab / 2,
      width: grab,
      height: grab,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          _penPointer = e.pointer;
          _holdHandle();
        },
        onPointerMove: (e) => onPull(e.delta),
        onPointerUp: (_) => _dropHandle(),
        onPointerCancel: (_) => _dropHandle(),
        child: Center(
          child: Container(
            width: 14 * k,
            height: 14 * k,
            decoration: BoxDecoration(
              color: fill ?? Colors.white,
              shape: square ? BoxShape.rectangle : BoxShape.circle,
              border: Border.all(color: primary, width: 2 * k),
            ),
          ),
        ),
      ),
    );
  }

  /// The frame / net and the handles of the transform, over the page it is on.
  Widget _transformOverlay(int pageIndex) {
    final x = _xform!;
    if (x.page != pageIndex) return const SizedBox.shrink();
    final pageStrokes = _strokesPerPage[pageIndex];
    if (pageStrokes == null || x.strokes.any((s) => !pageStrokes.contains(s))) {
      _xform = null; // (something was undone or erased under it)
      return const SizedBox.shrink();
    }
    final k = _uiScale;
    final primary = Theme.of(context).colorScheme.primary;
    final children = <Widget>[
      // (takes the touches on the page, so that nothing is drawn or selected while this goes on)
      const Positioned.fill(child: Listener(behavior: HitTestBehavior.opaque, child: SizedBox.expand())),
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            key: const ValueKey('transform-frame'),
            painter: _TransformPainter(x.kind, List.of(x.quad), x.grid?.copy(), _rotateHandleAt(x), primary, k),
          ),
        ),
      ),
    ];
    switch (x.kind) {
      case TransformKind.distort:
      case TransformKind.perspective:
        for (var i = 0; i < 4; i++) {
          final perspective = x.kind == TransformKind.perspective;
          children.add(_handleDot(
            x.quad[i],
            'transform-corner-$i',
            onPull: (d) => _pullHandle(d, quad: (base, pulled) {
              if (perspective) return quadPerspective(base, i, pulled);
              return [for (var j = 0; j < 4; j++) j == i ? base[j] + pulled : base[j]];
            }),
          ));
        }
      case TransformKind.skew:
        for (var i = 0; i < 4; i++) {
          final mid = Offset.lerp(x.quad[i], x.quad[(i + 1) % 4], 0.5)!;
          children.add(_handleDot(mid, 'transform-edge-$i', square: true, onPull: (d) => _pullHandle(d, quad: (base, pulled) => quadSkewed(base, i, pulled))));
        }
      case TransformKind.rotate:
        final stick = _rotateHandleAt(x);
        if (stick != null) {
          children.add(_handleDot(
            stick,
            'transform-rotate-handle',
            fill: primary,
            onPull: (d) => _pullHandle(d, quad: (base, pulled) {
              final from = _rotateHandleOf(base)!;
              final c = boundsOfPoints(base).center;
              var angle = math.atan2(from.dy + pulled.dy - c.dy, from.dx + pulled.dx - c.dx) - math.atan2(from.dy - c.dy, from.dx - c.dx);
              if (HardwareKeyboard.instance.isShiftPressed) {
                const step = math.pi / 12;
                angle = (angle / step).round() * step;
              }
              return quadRotated(base, c, angle);
            }),
          ));
        }
      case TransformKind.warp:
        final g = x.grid;
        if (g != null) {
          for (var i = 0; i < g.points.length; i++) {
            children.add(_handleDot(g.points[i], 'transform-net-$i', onPull: (d) => _pullHandle(d, net: (base, pulled) {
                  final next = base.copy();
                  next.points[i] = base.points[i] + pulled;
                  return next;
                })));
          }
        }
    }
    return Positioned.fill(child: Stack(clipBehavior: Clip.none, children: children));
  }

  /// Where the handle for turning is: below the middle of the bottom edge of [q] (the tools are above the frame).
  Offset? _rotateHandleOf(List<Offset> q) {
    if (q.length != 4) return null;
    final mid = Offset.lerp(q[3], q[2], 0.5)!;
    final edge = q[2] - q[3];
    if (edge.distance < 1e-9) return null;
    final normal = Offset(-edge.dy, edge.dx) / edge.distance; // (out of the bottom edge, whichever way the shape is turned)
    return mid + normal * 36 * _uiScale;
  }

  Offset? _rotateHandleAt(_TransformSession x) => x.kind == TransformKind.rotate ? _rotateHandleOf(x.quad) : null;

  /// The buttons of the transform, over the frame: the kinds, start again, cancel and done.
  Widget _transformBar(int pageIndex) {
    final x = _xform;
    if (x == null || x.page != pageIndex) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    Widget kind(TransformKind k, IconData icon, String tip) => IconButton(
          key: ValueKey('transform-${k.name}'),
          icon: Icon(icon, size: 20),
          isSelected: x.kind == k,
          tooltip: tr(tip),
          visualDensity: VisualDensity.compact,
          onPressed: () => _setTransformKind(k),
        );
    return _aboveSelection(
      pageIndex,
      x.area,
      child: Material(
        elevation: 3,
        shape: const StadiumBorder(),
        color: scheme.surface,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            kind(TransformKind.distort, Icons.crop_free, 'Distort: pull the corners anywhere'),
            kind(TransformKind.perspective, Icons.view_in_ar_outlined, 'Perspective: pull a corner, the next one follows'),
            kind(TransformKind.skew, Icons.format_italic, 'Skew: slide the edges'),
            kind(TransformKind.rotate, Icons.rotate_right, 'Rotate (Shift: in steps of 15°)'),
            kind(TransformKind.warp, Icons.grid_on, 'Warp: bend the drawing with a net'),
            const SizedBox(height: 24, child: VerticalDivider(width: 12)),
            IconButton(
              key: const ValueKey('transform-reset'),
              icon: const Icon(Icons.restart_alt, size: 20),
              tooltip: tr('Start again'),
              visualDensity: VisualDensity.compact,
              onPressed: _resetTransform,
            ),
            IconButton(
              key: const ValueKey('transform-cancel'),
              icon: Icon(Icons.close, size: 20, color: scheme.error),
              tooltip: tr('Cancel'),
              visualDensity: VisualDensity.compact,
              onPressed: _cancelTransform,
            ),
            IconButton(
              key: const ValueKey('transform-done'),
              icon: Icon(Icons.check, size: 20, color: scheme.primary),
              tooltip: tr('Done'),
              visualDensity: VisualDensity.compact,
              onPressed: _finishTransform,
            ),
          ],
        ),
      ),
    );
  }
}

/// The frame (or the net of a warp) with its stick for turning.
class _TransformPainter extends CustomPainter {
  final TransformKind kind;
  final List<Offset> quad;
  final WarpGrid? grid;
  final Offset? stick;
  final Color color;
  final double scale;

  _TransformPainter(this.kind, this.quad, this.grid, this.stick, this.color, this.scale);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * scale
      ..color = color;
    if (kind == TransformKind.warp && grid != null) {
      final thin = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 * scale
        ..color = color.withValues(alpha: 0.7);
      const steps = 24;
      for (var i = 0; i < WarpGrid.side; i++) {
        final t = i / (WarpGrid.side - 1);
        final across = Path()..moveTo(grid!.at(0, t).dx, grid!.at(0, t).dy);
        final down = Path()..moveTo(grid!.at(t, 0).dx, grid!.at(t, 0).dy);
        for (var s = 1; s <= steps; s++) {
          final u = s / steps;
          final a = grid!.at(u, t), d = grid!.at(t, u);
          across.lineTo(a.dx, a.dy);
          down.lineTo(d.dx, d.dy);
        }
        final edge = i == 0 || i == WarpGrid.side - 1;
        canvas.drawPath(across, edge ? line : thin);
        canvas.drawPath(down, edge ? line : thin);
      }
      return;
    }
    if (quad.length == 4) {
      final path = Path()..addPolygon(quad, true);
      canvas.drawPath(path, line);
      if (stick != null) canvas.drawLine(Offset.lerp(quad[3], quad[2], 0.5)!, stick!, line);
    }
  }

  @override
  bool shouldRepaint(_TransformPainter old) => true;
}
