part of 'fixed_page_note_editor.dart';

/// Drawing with a mirror, and with a steady hand: what is made of a point of the pen before it is a point of the line.
extension _EditorSymmetry on _FixedPageNoteEditorState {
  /// Whether the line being started is repeated: not the lines that go between items or that an extension draws.
  bool get _repeatsLines => _on(Feature.symmetry) && !_symmetry.isOff && _activeDrawTool == null && _shape != ShapeTool.connector && !_connecting;

  /// The centre of the symmetry on a page that is [pageHeight] high.
  Offset _symmetryCentre(double pageHeight) => Offset(_symmetryAt.dx * _paperWidth, _symmetryAt.dy * pageHeight);

  /// The handle that moves the centre: a ring with a cross, over the page, dragged with the pen or a finger; a double tap brings the
  /// centre back to the middle.
  Widget _symmetryHandle(double pageHeight) {
    final c = _symmetryCentre(pageHeight);
    const half = 22.0;
    final color = Theme.of(context).colorScheme.primary;
    return Positioned(
      left: c.dx - half,
      top: c.dy - half,
      width: 2 * half,
      height: 2 * half,
      child: ElementDragDetector(
        key: const ValueKey('symmetry-handle'),
        onDragUpdate: (delta) => setState(() {
          final to = c + delta;
          _symmetryAt = Offset((to.dx / _paperWidth).clamp(0.0, 1.0), (to.dy / pageHeight).clamp(0.0, 1.0));
        }),
        onTap: () {
          // two taps close together bring the centre back to the middle
          final now = DateTime.now();
          if (_lastHandleTap != null && now.difference(_lastHandleTap!) < const Duration(milliseconds: 400)) {
            setState(() => _symmetryAt = const Offset(0.5, 0.5));
            _lastHandleTap = null;
          } else {
            _lastHandleTap = now;
          }
        },
        child: Tooltip(
          message: tr('Drag to move the centre of the symmetry'),
          child: CustomPaint(painter: _SymmetryHandlePainter(color)),
        ),
      ),
    );
  }

  /// The repeats of [stroke], which has just gone down, about [centre]: the same look, a first point each. They are drawn with the
  /// stroke, and join the page when the pen is lifted.
  void _startSymmetry(DrawingStroke stroke, Offset centre) {
    _symmetryMaps = _repeatsLines ? _symmetry.transforms(centre) : const [];
    _symmetryCopies = [
      for (final map in _symmetryMaps)
        DrawingStroke(
          color: stroke.color,
          width: stroke.width,
          points: [map(stroke.points.first)],
          author: stroke.author,
          dash: stroke.dash,
          fill: stroke.fill,
          gradient: stroke.gradient,
          pressures: stroke.pressures == null ? null : List.of(stroke.pressures!),
          brush: stroke.brush,
          layer: stroke.layer,
        ),
    ];
  }

  /// Gives the repeats the point [stroke] has just got.
  void _extendSymmetry(DrawingStroke stroke) {
    for (var i = 0; i < _symmetryCopies.length; i++) {
      final copy = _symmetryCopies[i];
      copy.points.add(_symmetryMaps[i](stroke.points.last));
      final pr = stroke.pressures;
      if (pr != null && pr.isNotEmpty) (copy.pressures ??= []).add(pr.last);
    }
  }

  /// Makes the repeats again from all of [stroke] (a shape that was dragged, or a line that was made straight or simpler).
  void _remakeSymmetry(DrawingStroke stroke, [List<DrawingStroke>? copies]) {
    final all = copies ?? _symmetryCopies;
    for (var i = 0; i < all.length; i++) {
      final copy = all[i];
      copy.points
        ..clear()
        ..addAll([for (final p in stroke.points) _symmetryMaps[i](p)]);
      copy.pressures = stroke.pressures == null ? null : List.of(stroke.pressures!);
    }
  }
}

/// A ring with a cross in it: the handle of the symmetry.
class _SymmetryHandlePainter extends CustomPainter {
  final Color color;
  _SymmetryHandlePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, 14, Paint()..color = color.withValues(alpha: 0.12));
    final line = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(c, 14, line);
    canvas.drawLine(c - const Offset(8, 0), c + const Offset(8, 0), line);
    canvas.drawLine(c - const Offset(0, 8), c + const Offset(0, 8), line);
  }

  @override
  bool shouldRepaint(covariant _SymmetryHandlePainter old) => old.color != color;
}
