part of 'fixed_page_note_editor.dart';

const double _minCanvasZoom = 0.05, _maxCanvasZoom = 8.0;

/// A note that is an infinite canvas: one surface to draw and write on, seen through a window that is moved (a finger, the wheel,
/// two fingers on a trackpad, the middle mouse button) and zoomed. The strokes, text boxes and pictures are on page 0 as on any
/// page; only how that page is shown differs, so everything that works on a page works here.
extension _EditorCanvas on _FixedPageNoteEditorState {
  /// The part of the surface that is on the screen (all of it, when the canvas is turned), and how many screen pixels a unit of it is.
  ({Rect rect, double scale}) _viewWindow() {
    final scale = _pageScale;
    if (_viewTurn == 0) return (rect: _viewTopLeft & Size(_viewportW / scale, _viewportH / scale), scale: scale);
    final corners = [for (final a in [Offset.zero, Offset(_viewportW, 0), Offset(0, _viewportH), Offset(_viewportW, _viewportH)]) _areaToCanvas(a)];
    final xs = corners.map((c) => c.dx), ys = corners.map((c) => c.dy);
    return (rect: Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max)), scale: scale);
  }

  /// The middle of the window, in the area: what the canvas turns about.
  Offset get _viewMiddle => Offset(_viewportW / 2, _viewportH / 2);

  /// The point of the canvas under [area] (a point of the page area), the canvas turned or not.
  Offset _areaToCanvas(Offset area) => _viewTopLeft + (turnedBy(area - _viewMiddle, -_viewTurn) + _viewMiddle) / _pageScale;

  /// The point of the canvas at the top left of the area: where things put "at the top of what is in view" go.
  Offset get _viewCorner => _areaToCanvas(Offset.zero);

  /// Moves the window so that the point [canvas] of the canvas is under [area].
  void _placeUnder(Offset canvas, Offset area) {
    _viewTopLeft = _clampView(canvas - (turnedBy(area - _viewMiddle, -_viewTurn) + _viewMiddle) / _pageScale);
    _viewTick.value++;
  }

  /// Turns the canvas to [turn] (radians), the point under [focal] staying where it is. Near a quarter turn it settles on it, so that
  /// the canvas is easily put straight again.
  void _turnCanvas(double turn, Offset focal) {
    final settled = settledTurn(turn);
    if (settled == _viewTurn) return;
    final under = _areaToCanvas(focal);
    setState(() => _viewTurn = settled);
    _placeUnder(under, focal);
  }

  /// [at] moved so that the window stays on the surface.
  Offset _clampView(Offset at) {
    final scale = _pageScale;
    final room = Offset(math.max(0.0, canvasExtent - _viewportW / scale), math.max(0.0, canvasExtent - _viewportH / scale));
    return Offset(at.dx.clamp(0.0, room.dx), at.dy.clamp(0.0, room.dy));
  }

  /// Everything placed on the canvas, or null if it is empty.
  Rect? _canvasBounds() => canvasContentBounds(
        strokes: _strokesPerPage.values.expand((e) => e),
        boxes: _textBoxesPerPage.values.expand((e) => e),
        images: _imagesPerPage.values.expand((e) => e),
      );

  /// The window on the canvas moves by [screenDelta] (the content follows the finger).
  void _panCanvas(Offset screenDelta) {
    final moved = _clampView(_viewTopLeft - turnedBy(screenDelta, -_viewTurn) / _pageScale);
    if (moved == _viewTopLeft) return;
    _viewTopLeft = moved;
    _viewTick.value++;
  }

  /// Zooms to [target], keeping the point of the canvas that is under [focal] (in the area) where it is.
  void _zoomCanvas(double target, Offset focal) {
    final under = _areaToCanvas(focal);
    setState(() => _zoom = target);
    _placeUnder(under, focal);
  }

  /// Puts [point] of the canvas in the middle of the window.
  void _centerCanvasOn(Offset point) {
    _viewTopLeft = _clampView(point - Offset(_viewportW, _viewportH) / (2 * _pageScale));
    _viewTick.value++;
  }

  /// Zooms and moves so that everything on the canvas is in view (an empty canvas: back to where it starts).
  void _fitCanvas() {
    final bounds = _canvasBounds();
    if (bounds == null) {
      setState(() => _zoom = 1.0);
      _viewTopLeft = _clampView(canvasOrigin - const Offset(40, 40));
      _viewTick.value++;
      return;
    }
    final base = math.min(basePageWidth, _viewportW) / basePageWidth;
    const room = 120.0; // (round it, in screen pixels)
    final fit = math.min((_viewportW - room) / bounds.width, (_viewportH - room) / bounds.height) / base;
    setState(() => _zoom = fit.isFinite ? math.min(fit, 1.0).clamp(_minCanvasZoom, _maxCanvasZoom) : 1.0);
    _centerCanvasOn(bounds.center);
  }

  /// The two fingers (or one) that touch the canvas: the content follows them, and two of them zoom.
  void _canvasScaleStart(ScaleStartDetails d) {
    _scaleGo = _canPanCanvas;
    _scaleBaseZoom = _zoom;
    _scaleBaseTurn = _viewTurn;
    _scaleCount = d.pointerCount;
  }

  void _canvasScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount != _scaleCount) {
      if (!_scaleGo) _scaleGo = _canPanCanvas; // (a second finger: the two move the canvas whatever the tool)
      // (a finger came or went: the scale starts from 1 again)
      _scaleCount = d.pointerCount;
      _scaleBaseZoom = _zoom;
      _scaleBaseTurn = _viewTurn - d.rotation; // (the turn too goes on from here)
    }
    if (!_scaleGo) return;
    _panCanvas(d.focalPointDelta);
    if (d.pointerCount > 1 && _canZoom) {
      _setZoom(_scaleBaseZoom * d.scale, _localInArea(d.focalPoint));
      _turnCanvas(_scaleBaseTurn + d.rotation, _localInArea(d.focalPoint));
    }
  }

  /// A finger (or the pen, when the tool is not the pen) moves the canvas; not while something is being drawn or dragged.
  /// A pointer ended: if it was the one that froze the page (a stroke, a handle), the page is let go, wherever its own handler is.
  void _releasePen(int pointer) {
    if (pointer != _penPointer) return;
    _penPointer = -1;
    if (_penDown) setState(() => _penDown = false);
  }

  bool get _canPanCanvas => _drag == null && (_touchGesture || !_penDown && (_mode != CanvasInteractionMode.draw || _fingersScroll));

  /// The wheel moves the canvas (Shift: sideways), with Ctrl it zooms.
  void _canvasSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final scroll = event as PointerScrollEvent;
      if (HardwareKeyboard.instance.isControlPressed) {
        if (!_zoomLocked) _setZoom(_zoom * math.exp(-scroll.scrollDelta.dy / 400), _localInArea(scroll.position));
        return;
      }
      var delta = scroll.scrollDelta;
      if (HardwareKeyboard.instance.isShiftPressed && delta.dx == 0) delta = Offset(delta.dy, 0);
      _panCanvas(-delta);
    });
  }

  /// Near an edge of the area the canvas moves on while something is held there.
  void _scrollCanvasWhileDragging() {
    final at = _localInArea(_dragGlobal);
    final size = _areaKey.currentContext?.size ?? Size(_viewportW, _viewportH);
    const edge = 70.0;
    double speed(double v, double length) => v < edge ? -(edge - v) / edge * 18 : (v > length - edge ? (v - (length - edge)) / edge * 18 : 0.0);
    final by = Offset(speed(at.dx, size.width), speed(at.dy, size.height));
    if (by == Offset.zero) return;
    final before = _viewTopLeft;
    _panCanvas(-by);
    if (_viewTopLeft == before) return;
    _dragTo(_dragGlobal); // it stays under the pointer while the canvas moves under it
  }

  /// The canvas, filling the area: the surface under a transform that is the window, with what the fingers and the pen do on it.
  Widget _canvasArea(BoxConstraints box) {
    _viewportW = box.maxWidth;
    _viewportH = box.maxHeight;
    if (!_viewPlaced) {
      _viewPlaced = true;
      _viewTopLeft = _clampView((_canvasBounds()?.topLeft ?? canvasOrigin) - const Offset(40, 40));
    }
    return Listener(
      onPointerDown: (e) {
        _lastPointerDown = e.pointer;
        _areaDownAt = e.position;
        _areaDownTime = DateTime.now();
        _areaTravel = 0;
        if (e.kind == PointerDeviceKind.mouse && (e.buttons & kMiddleMouseButton) != 0) _middlePan = e.pointer;
        _onTouchDown(e);
      },
      onPointerMove: (e) {
        _areaTravel = math.max(_areaTravel, (e.position - _areaDownAt).distance);
        if (e.pointer == _middlePan) _panCanvas(e.delta);
        if (_drag != null && e.pointer == _drag!.pointer) _dragTo(e.position);
      },
      onPointerUp: (e) {
        _releasePen(e.pointer);
        _onTouchEnd(e);
        if (e.pointer == _middlePan) _middlePan = -1;
        _tapOnNothing(e);
        if (_drag != null && e.pointer == _drag!.pointer) _endDrag();
      },
      onPointerCancel: (e) {
        _releasePen(e.pointer);
        _onTouchEnd(e);
        if (e.pointer == _middlePan) _middlePan = -1;
        if (_drag != null && e.pointer == _drag!.pointer) _endDrag();
      },
      onPointerSignal: _canvasSignal,
      // a trackpad: pinching zooms (two fingers moving arrive as scrolling, with the wheel, below)
      onPointerPanZoomStart: (_) {
        _panZoomStartZoom = _zoom;
        _panZoomStartTurn = _viewTurn;
        _panZoomLastScale = 1;
      },
      onPointerPanZoomUpdate: (e) {
        if (e.scale != _panZoomLastScale && !_zoomLocked) {
          _panZoomLastScale = e.scale;
          _setZoom(_panZoomStartZoom * e.scale, _localInArea(e.position));
        }
        if (e.rotation != 0 && !_zoomLocked) _turnCanvas(_panZoomStartTurn + e.rotation, _localInArea(e.position));
      },
      child: GestureDetector(
        // (the mouse drags the canvas too while it selects; with the pen tool it draws, and the wheel or the middle button move it)
        supportedDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          if (_mode == CanvasInteractionMode.selectText) PointerDeviceKind.mouse,
        },
        onScaleStart: _canvasScaleStart,
        onScaleUpdate: _canvasScaleUpdate,
        child: ClipRect(
          child: Stack(
            children: [
              // (as big as the surface: what is outside a box is not hit, and the surface is far bigger than the screen)
              Positioned(
                left: 0,
                top: 0,
                width: canvasExtent,
                height: canvasExtent,
                child: AnimatedBuilder(
                  animation: _viewTick,
                  child: RepaintBoundary(child: _pageContent(0)),
                  builder: (context, page) {
                    final s = _pageScale, at = _viewTopLeft;
                    final window = Matrix4(s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, -at.dx * s, -at.dy * s, 0, 1);
                    if (_viewTurn == 0) return Transform(transform: window, child: page);
                    // (turned about the middle of the window)
                    final m = _viewMiddle;
                    final turn = Matrix4.translationValues(m.dx, m.dy, 0)..rotateZ(_viewTurn)..translateByDouble(-m.dx, -m.dy, 0, 1);
                    return Transform(transform: turn..multiply(window), child: page);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The notebook becomes an infinite canvas (the choice in the list of page sizes). What is on its first page moves to the middle
  /// of the surface; there is no way back, so the person is asked when there is something on it.
  Future<void> _makeCanvas() async {
    final onOtherPages = [_strokesPerPage, _textBoxesPerPage, _imagesPerPage, _highlightsPerPage].any((m) => m.entries.any((e) => e.key > 0 && e.value.isNotEmpty));
    if (onOtherPages || _documentController.text.trim().isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('Only a note with one page and no written document can become an infinite canvas'))));
      return;
    }
    if (_blankPageHasContent(0)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: Text(tr('Make this an infinite canvas?')),
          content: Text(tr('The note has no pages any more then, cannot be exported as a PDF and cannot be turned back into pages.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            FilledButton(key: const ValueKey('make-canvas'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Make a canvas'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      for (final s in _strokesPerPage[0] ?? const <DrawingStroke>[]) {
        for (var i = 0; i < s.points.length; i++) {
          s.points[i] += canvasOrigin;
        }
      }
      for (final b in _textBoxesPerPage[0] ?? const <TextBoxWidgetModel>[]) {
        b.position += canvasOrigin;
      }
      for (final m in _imagesPerPage[0] ?? const <ImageItem>[]) {
        m.position += canvasOrigin;
      }
      _clearSelection();
      _activeSelectedBox = null;
      _selectedImage = null;
      _mode = _mode == CanvasInteractionMode.document ? CanvasInteractionMode.selectText : _mode;
      _themeImage = null;
      _pageFormat = PageFormat.infinite;
      _zoom = 1.0;
      _viewPlaced = false; // (it starts at what is on it)
      _undoStack.clear(); // (the move above cannot be taken back)
      _metaBase = _captureMeta(); // (nor the change of look, alone)
    });
  }
}
