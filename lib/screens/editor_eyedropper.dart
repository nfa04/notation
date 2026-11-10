part of 'fixed_page_note_editor.dart';

/// The eyedropper: the pen takes the colour of whatever is under the pointer, as it is on the screen (a line, a brush, a gradient, a
/// picture, a PDF). The area is taken as a picture once when the pointer goes down; moving reads that picture again (cheap, so a
/// slow device keeps up), and letting go chooses the colour. It is chosen once and then the pen draws again, as in drawing apps.
extension _EditorEyedropper on _FixedPageNoteEditorState {
  /// Whether the eyedropper takes the pointers now (the button, or the I key).
  bool get _pickingOn => _picking && _mode == CanvasInteractionMode.draw;

  /// The pen's side button is held and is set to pick a colour.
  bool _picksWith(PointerEvent e) => _barrelHeld(e) && _barrelAction == BarrelAction.pickColor;

  /// Switches the eyedropper on or off (from the button or the key); the draw mode is gone to if needed.
  void _toggleEyedropper() {
    if (_mode != CanvasInteractionMode.draw) _selectMode(CanvasInteractionMode.draw);
    setState(() {
      _picking = !_picking;
      if (_picking) {
        _lassoPath = null;
        _bucket = false;
      }
    });
  }

  /// Over the whole area while the eyedropper is on: every pointer picks (none draws, scrolls or selects).
  Widget _eyedropperLayer() => Positioned.fill(
        child: Listener(
          key: const ValueKey('eyedropper-layer'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _pickDown(e.position, e.pointer),
          onPointerMove: (e) {
            if (e.pointer == _pickPointer) _pickMove(e.position);
          },
          onPointerUp: (e) {
            if (e.pointer == _pickPointer) unawaited(_pickUp());
          },
          onPointerCancel: (e) {
            if (e.pointer == _pickPointer) _pickCancel();
          },
          child: const MouseRegion(cursor: SystemMouseCursors.precise, child: SizedBox.expand()),
        ),
      );

  /// The ring that shows the colour under the pointer (outside: what would be picked; inside, below: the pen's colour now), drawn
  /// above the pointer so that a finger does not hide it.
  Widget _eyedropperLoupe() => Positioned.fill(
        child: IgnorePointer(
          child: LayoutBuilder(
            builder: (context, box) => ValueListenableBuilder(
              valueListenable: _pickLoupe,
              builder: (context, loupe, _) => loupe == null ? const SizedBox.shrink() : Stack(children: [_loupeAt(loupe, box.biggest)]),
            ),
          ),
        ),
      );

  Widget _loupeAt(({Offset at, Color? color}) loupe, Size room) {
    const size = 76.0;
    // (above the point, or below it near the top edge)
    final top = loupe.at.dy - size - 28 < 0 ? loupe.at.dy + 28 : loupe.at.dy - size - 28;
    final left = (loupe.at.dx - size / 2).clamp(0.0, math.max(0.0, room.width - size)).toDouble();
    return Positioned(
      left: left,
      top: top,
      child: CustomPaint(
        key: const ValueKey('eyedropper-loupe'),
        size: const Size.square(size),
        painter: _LoupePainter(loupe.color, _selectedPenColor, Theme.of(context).colorScheme.outline),
      ),
    );
  }

  void _pickDown(Offset global, int pointer) {
    _pickPointer = pointer;
    _pickShot = null;
    final shooting = _shootSurface();
    _pickShooting = shooting;
    unawaited(shooting.then((_) {
      if (mounted && _pickPointer == pointer) _pickMove(global);
    }));
    _pickMove(global);
  }

  void _pickMove(Offset global) {
    final at = _localInArea(global);
    _pickAt = global;
    _pickLoupe.value = (at: at, color: _sampleAt(global));
  }

  Future<void> _pickUp() async {
    final pointer = _pickPointer;
    await _pickShooting; // (a quick tap can be let go of before the picture is there)
    if (!mounted || pointer != _pickPointer) return;
    final picked = _sampleAt(_pickAt);
    _pickCancel();
    if (picked != null) _usePickedColor(picked);
  }

  void _pickCancel() {
    _pickPointer = -1;
    _pickShot = null;
    _pickShooting = null;
    _pickLoupe.value = null;
  }

  /// Takes the area as a picture at the screen's sharpness (thin lines are read as they are shown, not blurred into the paper).
  Future<void> _shootSurface() async {
    final boundary = _surfaceKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return;
    if (kDebugMode && boundary.debugNeedsPaint) await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !boundary.attached) return;
    final ratio = _devicePixelRatio <= 0 ? 1.0 : _devicePixelRatio;
    final image = await boundary.toImage(pixelRatio: ratio);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (bytes != null) _pickShot = (bytes: bytes, width: image.width, height: image.height, ratio: ratio, box: boundary);
    } finally {
      image.dispose();
    }
  }

  /// The colour shown at [global], or null (nothing there, or the picture is not taken yet).
  Color? _sampleAt(Offset global) {
    final shot = _pickShot;
    if (shot == null || !shot.box.attached) return null;
    final local = shot.box.globalToLocal(global) * shot.ratio;
    return colorAtPixel(shot.bytes, shot.width, shot.height, local.dx.floor(), local.dy.floor(), ground: Theme.of(context).scaffoldBackgroundColor);
  }

  /// The pen draws in [color] from now on. A colour that is not on the bar yet joins the added colours (so it can be chosen again),
  /// and the pen is back to drawing.
  void _usePickedColor(Color color) {
    final known = [...drawColors, ..._customColors].any((c) => c.toARGB32() == color.toARGB32());
    setState(() {
      _selectedPenColor = color;
      _picking = false;
      _erasing = false;
      _lassoing = false;
      if (!known) {
        _customColors.add(color);
        if (_customColors.length > _maxCustomColors) _customColors.removeAt(0);
      }
    });
    if (!known) unawaited(widget.repository.settings.setPenColors(_customColors));
  }
}

/// A ring in the colour that would be picked, its lower inner half the colour the pen has now (to compare them).
class _LoupePainter extends CustomPainter {
  final Color? picked, current, edge;

  _LoupePainter(this.picked, this.current, this.edge);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero), r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = const Color(0x40000000));
    canvas.drawCircle(c, r - 1, Paint()..color = picked ?? const Color(0xFFBDBDBD));
    final inner = Rect.fromCircle(center: c, radius: r - 14);
    canvas.drawArc(inner, math.pi, math.pi, true, Paint()..color = picked ?? const Color(0xFFBDBDBD));
    canvas.drawArc(inner, 0, math.pi, true, Paint()..color = current ?? const Color(0xFF000000));
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = edge ?? const Color(0xFF757575);
    canvas.drawCircle(c, r - 14, line);
    canvas.drawCircle(c, r - 1, line);
  }

  @override
  bool shouldRepaint(_LoupePainter old) => old.picked != picked || old.current != current || old.edge != edge;
}
