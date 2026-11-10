part of 'fixed_page_note_editor.dart';

/// Scrolling that a zoom can move together with the size of the pages, so that no frame shows one without the other.
class _ZoomScrollController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _ZoomScrollPosition(physics: physics, context: context, initialPixels: initialScrollOffset, keepScrollOffset: keepScrollOffset, oldPosition: oldPosition, debugLabel: debugLabel);

  _ZoomScrollPosition get zoomPosition => position as _ZoomScrollPosition;
}

class _ZoomScrollPosition extends ScrollPositionWithSingleContext {
  _ZoomScrollPosition({required super.physics, required super.context, super.initialPixels, super.keepScrollOffset, super.oldPosition, super.debugLabel});

  /// Goes to [to] with the layout that is coming, for which it was worked out. Nobody is told yet: what they would look at is still laid
  /// out for the old size. (A jump could not do this: until that layout, [to] can be past the end, and the page would be sent back.)
  void moveWithZoom(double to) {
    goIdle();
    correctPixels(to);
  }

  /// That layout was made: those who follow the scrolling can look.
  void movedWithZoom() => notifyListeners();

  /// How fast the list goes by itself (a fling, an animation), in pixels a second; 0 while a finger drags it or it stands.
  double get flingVelocity {
    final now = activity;
    return now == null || now is DragScrollActivity ? 0.0 : now.velocity;
  }
}

/// Zooming and panning with fingers, the wheel and the controls, and the sharper pages shown while zoomed in.
extension _EditorZoom on _FixedPageNoteEditorState {
  FingerMode get _fingerMode => widget.stylus?.fingers ?? FingerMode.auto;

  /// Whether a finger only scrolls and zooms now (a pen has been used, or the setting says so).
  bool get _fingersScroll => _fingerMode == FingerMode.scroll || (_fingerMode == FingerMode.auto && _stylusSeen);

  bool _drawsWith(PointerEvent e) {
    final stylus =
        e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus;
    if (stylus) _stylusSeen = true;
    if (e.kind != PointerDeviceKind.touch) return true;
    return _fingerMode == FingerMode.draw || !_fingersScroll;
  }

  bool _barrelHeld(PointerEvent e) => e.kind == PointerDeviceKind.stylus && (e.buttons & (kPrimaryStylusButton | kSecondaryStylusButton)) != 0;

  BarrelAction get _barrelAction => widget.stylus?.barrel ?? BarrelAction.erase;

  /// The tool button on the toolbar, the pen's eraser end, or its side button (when that is set to erase).
  bool _erasesWith(PointerEvent e) =>
      _erasing || e.kind == PointerDeviceKind.invertedStylus || (_barrelHeld(e) && _barrelAction == BarrelAction.erase);

  /// The pen's side button is held and is set to select.
  bool _lassosWith(PointerEvent e) => _lassoing || (_barrelHeld(e) && _barrelAction == BarrelAction.lasso);

  /// How hard the pen presses, 0 to 1, smoothed a little; null for a finger or a mouse, or a pen that cannot tell.
  double? _pressureOf(PointerEvent e, {bool first = false}) {
    if (e.kind != PointerDeviceKind.stylus) return null;
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return null;
    final p = ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
    _lastPressure = first || _lastPressure == null ? p : _lastPressure! * 0.6 + p * 0.4;
    return _lastPressure;
  }

  Offset _localInArea(Offset global) =>
      (_areaKey.currentContext?.findRenderObject() as RenderBox?)
          ?.globalToLocal(global) ??
      global;

  /// Zooms to [target], keeping the point [focal] (in the page area) where it is.
  void _setZoom(double target, Offset focal) {
    target = _infinite ? target.clamp(_minCanvasZoom, _maxCanvasZoom) : target.clamp(_minZoom, _maxZoom);
    if ((target - _zoom).abs() < 1e-4) return;
    if (_infinite) return _zoomCanvas(target, focal);
    final oldScale = _pageScale, oldMiddle = _pagesLeft + _paperWidth * oldScale / 2;
    final v = _pageScroll.hasClients ? _pageScroll.offset : 0.0, h = _hScroll.hasClients ? _hScroll.offset : 0.0;
    final (page, y) = _placeInPages(v + focal.dy);
    setState(() => _zoom = target);
    _scheduleHiRes();
    if (_pageScroll.hasClients) _pageScroll.zoomPosition.moveWithZoom((_pageTop(page) + _rulerExtent + y * _pageScale - focal.dy).clamp(0.0, _scrollReach()));
    if (_hScroll.hasClients) {
      final ratio = _pageScale / oldScale, newMiddle = _pagesLeft + _paperWidth * _pageScale / 2;
      _hScroll.zoomPosition.moveWithZoom(((h + focal.dx - oldMiddle) * ratio + newMiddle - focal.dx).clamp(0.0, math.max(0.0, _contentWidth - _viewportW)));
    }
    _lookForSheets();
    if (_zoomLaidOutSoon) return;
    _zoomLaidOutSoon = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _zoomLaidOutSoon = false;
      if (!mounted) return;
      _documentEditor.currentState?.pageResized(); // (first: it goes by how the lines are laid out, which it has to know has changed)
      if (_pageScroll.hasClients) _pageScroll.zoomPosition.movedWithZoom();
      if (_hScroll.hasClients) _hScroll.zoomPosition.movedWithZoom();
    });
  }

  /// A short tap outside every page (beside them, between them) lets go of
  /// whatever is selected, like a tap on an empty spot of a page does.
  void _tapOnNothing(PointerUpEvent e) {
    final pdfEdit = _mode == CanvasInteractionMode.document && !_isBlank; // (an imported PDF being edited: the picked object)
    if (_mode != CanvasInteractionMode.selectText && !pdfEdit || _pinching || _drag != null) return;
    if (_areaTravel >= 8) return;
    final hit = _pageAt(e.position);
    // on a page the page's own handlers deal with the tap
    if (hit != null &&
        hit.local.dx >= 0 &&
        hit.local.dx <= _paperWidth &&
        hit.local.dy >= 0 &&
        hit.local.dy <= _shownPageHeight(hit.page)) {
      return;
    }
    if (DateTime.now().difference(_areaDownTime) > const Duration(milliseconds: 350)) return;
    if (pdfEdit) {
      if (_pdfEditSelected != null) setState(() => _pdfEditSelected = null);
      return;
    }
    if (!_hasSelection && _selectedImage == null && _activeSelectedBox == null) return;
    setState(() {
      _clearSelection();
      _selectedImage = null;
      _activeSelectedBox = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _onTouchDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch || _infinite) return; // (a canvas is pinched by its own gesture)
    _touches[e.pointer] = e.position;
    if (_touches.length == 2 && _canZoom) {
      final (a, b) = (_touches.values.first, _touches.values.last);
      _pinchStartDistance = math.max(1.0, (a - b).distance);
      _pinchStartZoom = _zoom;
      setState(() => _pinching = true);
    }
  }

  void _onTouchMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.position;
    if (_pinching && _touches.length == 2 && _canZoom) {
      final (a, b) = (_touches.values.first, _touches.values.last);
      _setZoom(
        _pinchStartZoom * (a - b).distance / _pinchStartDistance,
        _localInArea((a + b) / 2),
      );
    }
  }

  void _onTouchEnd(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_pinching && _touches.length < 2) setState(() => _pinching = false);
  }

  void _onPageSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    // registered here, below the lists, so that this wins and the list does not scroll
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      if (!_canZoom) return;
      final scroll = event as PointerScrollEvent;
      _setZoom(
        _zoom * math.exp(-scroll.scrollDelta.dy / 400),
        _localInArea(scroll.position),
      );
    });
  }

  // ---- sharper pages while zoomed in ------------------------------------------

  /// Looks at the zoom (and the size of the window) a moment after it stopped changing: if the pictures of the pages are no longer sharp,
  /// asks for sharper ones of what is on screen; if the window grew a lot, the pictures are made again as wide as it now shows them.
  void _scheduleHiRes() {
    _zoomSettle?.cancel();
    _zoomSettle = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _isBlank || _pdfDocument == null) return;
      final normal = _pictureWidthOf(_visiblePage().$1);
      if (_pagesRead.values.any((d) => d.alive && d.image.width < normal * 0.8)) {
        setState(_remakePictures); // (the pages on screen ask for theirs again as they are built; the old ones show until then)
      }
      final wanted = hiResPixelWidth(_paperWidth * _pageScale * _devicePixelRatio, normal: normal);
      if (wanted == _hiResWidth) return _sharpenSoon(); // (the same step: what came on screen with the zoom is made sharp)
      setState(() {
        _hiResWidth = wanted;
        _jobs.dropWhere((j) => j.kind == PageJobKind.sharp);
        for (final patch in _hiRes.values) {
          patch.dispose();
        }
        _hiRes.clear();
      });
    });
  }

  /// The part of page [page] that is on the screen, in units of the page; null when none of it is.
  Rect? _visibleRectOf(int page) {
    if (!_pageScroll.hasClients || page >= _pageCount) return null;
    final scale = _pageScale;
    final top = _pageTop(page) + _rulerExtent - _pageScroll.offset;
    final left = _pagesLeft - (_hScroll.hasClients ? _hScroll.offset : 0.0);
    final onScreen = Rect.fromLTWH(left, top, _paperWidth * scale, _shownPageHeight(page) * scale);
    final screen = Rect.fromLTWH(0, 0, _viewportW, _pageScroll.position.viewportDimension);
    if (!onScreen.overlaps(screen)) return null;
    final r = onScreen.intersect(screen);
    return Rect.fromLTRB((r.left - left) / scale, (r.top - top) / scale, (r.right - left) / scale, (r.bottom - top) / scale);
  }

  /// Asks for a sharp picture of what is on screen of page [page], unless the one there is still as sharp and covers it.
  void _requestHiRes(int page) {
    if (_hiResWidth == 0 || _isBlank || _pdfDocument == null || _nativePages.contains(page)) return;
    // (not while the zoom changes: it would be made at the zoom that is being left; [_scheduleHiRes] looks once it settled)
    if (_pinching || (_zoomSettle?.isActive ?? false)) return;
    final visible = _visibleRectOf(page);
    if (visible == null) return;
    final have = _hiRes[page];
    if (have != null && have.fullWidth == _hiResWidth && have.rect.inflate(0.5).contains(visible.topLeft) && have.rect.inflate(0.5).contains(visible.bottomRight)) return;
    if (!_hiResPending.add(page)) return;
    final epoch = _pagesEpoch;
    _jobs.add(PageJob(page, PageJobKind.sharp), (run) async {
      // (what is on screen when it starts, not when it was asked for)
      final width = _hiResWidth;
      final doc = _pdfDocument;
      final region = _visibleRectOf(page);
      if (width == 0 || doc == null || region == null || page >= doc.pages.length) return null;
      final pdfPage = doc.pages[page];
      final h = _shownPageHeight(page);
      // a quarter of what is on screen more on each side, for the scrolling that comes next
      final grown = Rect.fromLTRB(
        math.max(0.0, region.left - region.width / 4),
        math.max(0.0, region.top - region.height / 4),
        math.min(_paperWidth, region.right + region.width / 4),
        math.min(h, region.bottom + region.height / 4),
      );
      final k = width / _paperWidth; // pixels a unit of the page
      final fullHeight = width * pdfPage.height / pdfPage.width;
      final pixels = Rect.fromLTRB((grown.left * k).floorToDouble(), (grown.top * k).floorToDouble(), math.min(width.toDouble(), (grown.right * k).ceilToDouble()),
          math.min(fullHeight.floorToDouble(), (grown.bottom * k).ceilToDouble()));
      if (pixels.width < 1 || pixels.height < 1) return null;
      final image = await renderPageRegion(pdfPage, width, pixels, cancel: _cancelOnDrop(run, pdfPage), priority: PdfPageRenderPriority.high);
      return _SharpPatch(image, Rect.fromLTRB(pixels.left / k, pixels.top / k, pixels.right / k, pixels.bottom / k), width);
    }).then((patch) {
      if (patch == null) return;
      if (!mounted || epoch != _pagesEpoch || patch.fullWidth != _hiResWidth) {
        patch.dispose(); // the zoom or the PDF moved on meanwhile
        return;
      }
      setState(() {
        _hiRes.remove(page)?.dispose();
        _hiRes[page] = patch;
        // pages no longer on screen are not worth the memory
        final (first, last) = _screenPages();
        _hiRes.removeWhere((p, old) {
          final off = p < first - 1 || p > last + 1;
          if (off) old.dispose();
          return off;
        });
      });
    }, onError: (Object e) {
      if (e is! PageJobDropped) debugPrint('sharper page $page failed: $e');
    }).whenComplete(() => _hiResPending.remove(page));
  }

  /// Sharp pictures for what is on screen, a moment after the scrolling stopped.
  void _sharpenSoon() {
    if (_hiResWidth == 0) return;
    _sharpenTimer?.cancel();
    _sharpenTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      final (first, last) = _screenPages();
      for (var p = first; p <= last; p++) {
        _requestHiRes(p);
      }
    });
  }

  /// Top left of the pages: lock the zoom, or go back to the normal size.
  Widget _buildZoomControls() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 2,
      shape: const StadiumBorder(),
      color: scheme.surface.withValues(alpha: 0.92),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('zoom-lock'),
            tooltip: tr(_zoomLocked
                ? 'Zoom is locked (tap to unlock)'
                : 'Lock the zoom'),
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _zoomLocked ? Icons.lock : Icons.lock_open,
              size: 18,
              color: _zoomLocked ? scheme.primary : null,
            ),
            onPressed: () => setState(() => _zoomLocked = !_zoomLocked),
          ),
          // (for a mouse with no Ctrl and wheel to hand, or no pinch)
          if (_infinite) ...[
            IconButton(
              key: const ValueKey('zoom-out'),
              tooltip: tr('Zoom out'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove, size: 18),
              onPressed: _zoomLocked ? null : () => _setZoom(_zoom / 1.25, Offset(_viewportW / 2, _viewportH / 2)),
            ),
            IconButton(
              key: const ValueKey('zoom-in'),
              tooltip: tr('Zoom in'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              onPressed: _zoomLocked ? null : () => _setZoom(_zoom * 1.25, Offset(_viewportW / 2, _viewportH / 2)),
            ),
          ],
          if (_infinite)
            IconButton(
              key: const ValueKey('canvas-fit'),
              tooltip: tr('Show everything on the canvas'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.fit_screen_outlined, size: 18),
              onPressed: _fitCanvas,
            ),
          if (_infinite && _viewTurn != 0)
            Tooltip(
              message: tr('The canvas is turned: tap to put it straight'),
              child: TextButton.icon(
                key: const ValueKey('canvas-straighten'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: Transform.rotate(angle: _viewTurn, child: const Icon(Icons.navigation_outlined, size: 16)),
                label: Text('${(_viewTurn * 180 / math.pi).round()}°'),
                onPressed: _zoomLocked ? null : () => _turnCanvas(0, _viewMiddle),
              ),
            ),
          if ((_zoom - 1).abs() > 0.01)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton(
                key: const ValueKey('zoom-reset'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: _zoomLocked
                    ? null
                    : () => _setZoom(1.0, _infinite ? Offset(_viewportW / 2, _viewportH / 2) : Offset(_viewportW / 2, 200)),
                child: Text('${(_zoom * 100).round()}%'),
              ),
            ),
        ],
      ),
    );
  }
}
