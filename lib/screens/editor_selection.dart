part of 'fixed_page_note_editor.dart';

/// Selecting, lassoing, moving and deleting the things on a page, and the controls drawn over them.
extension _EditorSelection on _FixedPageNoteEditorState {
  bool get _hasSelection => _selection.isNotEmpty || _groupBoxes.isNotEmpty || _groupImages.isNotEmpty;

  /// Lets go of everything the lasso or a tap had selected.
  void _clearSelection() {
    _selection = [];
    _groupBoxes = [];
    _groupImages = [];
  }

  /// Shift is held: a tap or a lasso adds to what is selected (a tap on something selected takes it out again) instead of replacing it.
  bool get _addingToSelection => HardwareKeyboard.instance.isShiftPressed;

  /// Everything of [a] and then what [b] has more, once each.
  List<T> _union<T>(List<T> a, List<T> b) => [...a, for (final x in b) if (!a.contains(x)) x];

  /// Makes the text box and the picture that were picked on their own (with their own frame and tools) part of the group that is
  /// moved, resized and deleted together, so that more can join them. The group is on one page: one on another page is let go.
  void _gatherSelection(int page) {
    if (_selectedStrokePage != page) _clearSelection();
    final box = _activeSelectedBox;
    if (box != null && (_textBoxesPerPage[page]?.contains(box) ?? false) && !_groupBoxes.contains(box)) _groupBoxes = [..._groupBoxes, box];
    final image = _selectedImage;
    if (image != null && (_imagesPerPage[page]?.contains(image) ?? false) && !_groupImages.contains(image)) _groupImages = [..._groupImages, image];
    _activeSelectedBox = null;
    _selectedImage = null;
    _selectedStrokePage = page;
    FocusManager.instance.primaryFocus?.unfocus(); // (a text box that was being edited is not any more)
  }

  /// A tap with Shift held on a drawing, a text box or a picture of [page]: it joins the selection, or leaves it when it is in.
  /// Call it inside setState.
  void _toggleInSelection(int page, {DrawingStroke? stroke, TextBoxWidgetModel? box, ImageItem? image}) {
    _gatherSelection(page);
    List<T> flip<T>(List<T> list, T item) => list.contains(item) ? [for (final x in list) if (x != item) x] : [...list, item];
    if (stroke != null) _selection = flip(_selection, stroke);
    if (box != null) _groupBoxes = flip(_groupBoxes, box);
    if (image != null) _groupImages = flip(_groupImages, image);
  }

  /// The last of [items] (the top-most) that [test] accepts.
  T? _lastWhere<T>(Iterable<T> items, bool Function(T) test) {
    T? found;
    for (final x in items) {
      if (test(x)) found = x;
    }
    return found;
  }

  /// A tap with Shift held at [at] on [page], inside the frame of the selection (which covers what is under it): the top-most
  /// text box, drawing or picture there joins the selection or leaves it.
  void _shiftTapAt(int page, Offset at) {
    final box = _lastWhere(_textBoxesPerPage[page] ?? const <TextBoxWidgetModel>[], (b) => !_inGutter(b) && _boxEditable(b) && _boxRect(b).contains(at));
    final stroke = box != null ? null : _lastWhere(_strokesPerPage[page] ?? const <DrawingStroke>[], (st) => _layers.editable(st) && st.isNear(at, 10));
    final image = box != null || stroke != null ? null : _lastWhere(_imagesPerPage[page] ?? const <ImageItem>[], (m) => _imageEditable(m) && (m.position & m.size).contains(at));
    if (box == null && stroke == null && image == null) return;
    setState(() => _toggleInSelection(page, stroke: stroke, box: box, image: image));
  }

  /// Where [box] is on the page and how big it is (its height is its text's, or what it was pulled to).
  Rect _boxRect(TextBoxWidgetModel box) {
    final shown = _laidOutHeight(box);
    return (box.position & Size(box.size.width, math.max(shown ?? box.size.height, 30.0)));
  }

  /// The height [box] was last laid out with, or null when it is not on screen. (Safe to ask
  /// while building, unlike the size of a context.)
  double? _laidOutHeight(TextBoxWidgetModel box) {
    final object = _boxKeys[box.id]?.currentContext?.findRenderObject();
    return object is RenderBox && object.hasSize ? object.size.height : null;
  }

  Rect _boundsOf(DrawingStroke st) {
    var r = Rect.fromPoints(st.points.first, st.points.first);
    for (final pt in st.points) {
      r = r.expandToInclude(Rect.fromPoints(pt, pt));
    }
    return r.inflate(st.width / 2 + 6);
  }

  Rect? _selectionBounds() {
    Rect? r;
    void add(Rect other) => r = r == null ? other : r!.expandToInclude(other);
    for (final st in _selection) {
      if (st.points.isEmpty) continue;
      add(_boundsOf(st));
    }
    for (final b in _groupBoxes) {
      add(_boxRect(b).inflate(4));
    }
    for (final m in _groupImages) {
      add((m.position & m.size).inflate(4));
    }
    return r;
  }

  /// What the selection covers, without the margin the frame leaves around it: resizing keeps the corner opposite to the
  /// handle where it is, and it is this corner that must not move.
  Rect? _tightSelectionBounds() {
    Rect? r;
    void add(Rect other) => r = r == null ? other : r!.expandToInclude(other);
    for (final st in _selection) {
      if (st.points.isEmpty) continue;
      var b = Rect.fromPoints(st.points.first, st.points.first);
      for (final pt in st.points) {
        b = b.expandToInclude(Rect.fromPoints(pt, pt));
      }
      add(b);
    }
    for (final b in _groupBoxes) {
      add(_boxRect(b));
    }
    for (final m in _groupImages) {
      add(m.position & m.size);
    }
    return r;
  }

  // ---- dragging things from one page to another -----------------------------

  int? _pageOfBox(TextBoxWidgetModel box) {
    for (final e in _textBoxesPerPage.entries) {
      if (e.value.contains(box)) return e.key;
    }
    return null;
  }

  int? _pageOfImage(ImageItem item) {
    for (final e in _imagesPerPage.entries) {
      if (e.value.contains(item)) return e.key;
    }
    return null;
  }

  /// Starts moving [element] (a text box, a picture or a list of drawings) that
  /// has its top left at [topLeft]; it follows the pointer from here on, from
  /// the page area, so that it can leave the page it is on.
  void _startDrag(
    Object element,
    Offset topLeft,
    Offset global, {
    int? pointer,
  }) {
    final hit = _pageAt(global);
    if (hit == null) return;
    _drag = _ElementDrag(
      pointer ?? _lastPointerDown,
      element,
      hit.local - topLeft,
    );
    _dragGlobal = global;
    _dragScroll?.cancel();
    _dragScroll = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _scrollWhileDragging(),
    );
  }

  void _startStrokeDrag(Offset global, {int? pointer}) {
    final bounds = _selectionBounds();
    if (bounds == null) return;
    _strokeDragStart = (
      strokes: List.of(_selection),
      points: [for (final st in _selection) List.of(st.points)],
      boxes: List.of(_groupBoxes),
      boxAt: [for (final b in _groupBoxes) b.position],
      images: List.of(_groupImages),
      imageAt: [for (final m in _groupImages) m.position],
      page: _selectedStrokePage,
    );
    _startDrag(List.of(_selection), bounds.topLeft, global, pointer: pointer);
  }

  void _dragTo(Offset global) {
    final drag = _drag;
    final hit = drag == null ? null : _pageAt(global);
    if (drag == null || hit == null) return;
    _dragGlobal = global;
    final target = hit.local - drag.grab;
    // keep it on its page, where it can be found again
    Offset onPage(Size size) => Offset(
      target.dx.clamp(0.0, math.max(0.0, _paperWidth - size.width)),
      target.dy.clamp(0.0, math.max(0.0, _heightOf(hit.page) - 40)),
    );
    setState(() {
      final e = drag.element;
      if (e is TextBoxWidgetModel) {
        final from = _pageOfBox(e);
        if (from != null && from != hit.page) {
          _textBoxesPerPage[from]!.remove(e);
          _textBoxesPerPage.putIfAbsent(hit.page, () => []).add(e);
        }
        e.position = onPage(e.size);
        e.position += _alignMoved(hit.page, _boxRect(e), exclude: {e});
      } else if (e is ImageItem) {
        final from = _pageOfImage(e);
        if (from != null && from != hit.page) {
          _imagesPerPage[from]!.remove(e);
          _imagesPerPage.putIfAbsent(hit.page, () => []).add(e);
        }
        e.position = onPage(e.size);
        e.position += _alignMoved(hit.page, e.position & e.size, exclude: {e});
      } else if (e is List<DrawingStroke>) {
        if (_selectedStrokePage != hit.page) {
          _strokesPerPage[_selectedStrokePage]?.removeWhere(e.contains);
          _strokesPerPage.putIfAbsent(hit.page, () => []).addAll(e);
          _textBoxesPerPage[_selectedStrokePage]?.removeWhere(_groupBoxes.contains);
          _textBoxesPerPage.putIfAbsent(hit.page, () => []).addAll(_groupBoxes);
          _imagesPerPage[_selectedStrokePage]?.removeWhere(_groupImages.contains);
          _imagesPerPage.putIfAbsent(hit.page, () => []).addAll(_groupImages);
          _selectedStrokePage = hit.page;
        }
        final bounds = _selectionBounds();
        if (bounds != null) {
          var delta = target - bounds.topLeft;
          final tight = _tightSelectionBounds();
          if (tight != null) delta += _alignMoved(hit.page, tight.shift(delta), exclude: {...e, ..._groupBoxes, ..._groupImages});
          _moveSelection(delta);
        }
      }
    });
  }

  /// Near the top or bottom edge the pages scroll on while something is held there.
  void _scrollWhileDragging() {
    if (_infinite) {
      if (_drag != null) _scrollCanvasWhileDragging();
      return;
    }
    if (_drag == null || !_pageScroll.hasClients) return;
    final y = _localInArea(_dragGlobal).dy;
    final height = (_areaKey.currentContext?.size?.height) ?? 600.0;
    const edge = 70.0;
    final speed = y < edge
        ? -(edge - y) / edge * 18
        : y > height - edge
        ? (y - (height - edge)) / edge * 18
        : 0.0;
    if (speed == 0) return;
    final position = _pageScroll.position;
    final target = (position.pixels + speed).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    _pageScroll.jumpTo(target);
    _dragTo(
      _dragGlobal,
    ); // it stays under the pointer while the page moves under it
  }

  void _endDrag() {
    _dragScroll?.cancel();
    _dragScroll = null;
    if (_drag == null) return;
    _drag = null;
    if (_alignLines.isNotEmpty) setState(() => _alignLines = const []);
    _commitStrokeMove();
    _scheduleSave();
  }

  // ---- resizing what is selected ------------------------------------------

  /// A handle at [corner] of the selection was taken; the corner opposite to it stays where it is.
  void _startResize(Offset corner, Offset anchor, [int pointer = -1]) {
    _penPointer = pointer;
    if (!_hasSelection) return;
    _resizeStart = (
      strokes: List.of(_selection),
      points: [for (final st in _selection) List.of(st.points)],
      boxes: List.of(_groupBoxes),
      boxGeometry: [for (final b in _groupBoxes) (b.position, b.size)],
      images: List.of(_groupImages),
      imageGeometry: [for (final m in _groupImages) (m.position, m.size)],
      corner: corner,
      anchor: anchor,
      page: _selectedStrokePage,
    );
    _resizePulled = Offset.zero;
    setState(() => _penDown = true); // the page does not scroll along with a finger that pulls the handle
  }

  /// The handle moved by [screenDelta]. The selection keeps its proportions (the drawing is only made bigger or smaller),
  /// unless [free] is set (Shift), which pulls the width and the height on their own.
  void _resizeBy(Offset screenDelta, {bool free = false}) {
    final start = _resizeStart;
    if (start == null) return;
    _resizePulled += screenDelta / _pageScale;
    final v = start.corner - start.anchor;
    final to = start.corner + _resizePulled - start.anchor;
    double clampScale(double s) => s.isFinite ? s.clamp(0.05, 20.0) : 1.0;
    final double sx, sy;
    if (free) {
      sx = clampScale(v.dx.abs() < 1 ? 1 : to.dx / v.dx);
      sy = clampScale(v.dy.abs() < 1 ? 1 : to.dy / v.dy);
    } else {
      // along the diagonal, so the shape stays what it is
      final s = clampScale((to.dx * v.dx + to.dy * v.dy) / (v.dx * v.dx + v.dy * v.dy));
      sx = sy = s;
    }
    Offset scaled(Offset p) => start.anchor + Offset((p.dx - start.anchor.dx) * sx, (p.dy - start.anchor.dy) * sy);
    setState(() {
      for (var i = 0; i < start.strokes.length; i++) {
        final points = start.strokes[i].points;
        for (var k = 0; k < points.length; k++) {
          points[k] = scaled(start.points[i][k]);
        }
      }
      for (var i = 0; i < start.boxes.length; i++) {
        final (position, size) = start.boxGeometry[i];
        start.boxes[i]
          ..position = scaled(position)
          ..size = Size(math.max(40.0, size.width * sx), size.height * sy);
      }
      for (var i = 0; i < start.images.length; i++) {
        final (position, size) = start.imageGeometry[i];
        start.images[i]
          ..position = scaled(position)
          ..size = Size(math.max(16.0, size.width * sx), math.max(16.0, size.height * sy));
      }
    });
  }

  /// The handle was let go: one step to take back, and the note is saved.
  void _endResize() {
    final start = _resizeStart;
    _resizeStart = null;
    if (start == null) return;
    setState(() => _penDown = false);
    final endPoints = [for (final st in start.strokes) List.of(st.points)];
    final endBoxes = [for (final b in start.boxes) (b.position, b.size)];
    final endImages = [for (final m in start.images) (m.position, m.size)];
    var changed = false;
    for (var i = 0; i < endPoints.length && !changed; i++) {
      for (var k = 0; k < endPoints[i].length && !changed; k++) {
        changed = endPoints[i][k] != start.points[i][k];
      }
    }
    for (var i = 0; i < endBoxes.length && !changed; i++) {
      changed = endBoxes[i] != start.boxGeometry[i];
    }
    for (var i = 0; i < endImages.length && !changed; i++) {
      changed = endImages[i] != start.imageGeometry[i];
    }
    if (!changed) return;
    void place(List<List<Offset>> points, List<(Offset, Size)> boxes, List<(Offset, Size)> images) {
      for (var i = 0; i < start.strokes.length; i++) {
        start.strokes[i].points
          ..clear()
          ..addAll(points[i]);
      }
      for (var i = 0; i < start.boxes.length; i++) {
        start.boxes[i]
          ..position = boxes[i].$1
          ..size = boxes[i].$2;
      }
      for (var i = 0; i < start.images.length; i++) {
        start.images[i]
          ..position = images[i].$1
          ..size = images[i].$2;
      }
    }

    _undoStack.push(UndoStep(
      () => place(start.points, start.boxGeometry, start.imageGeometry),
      () => place(endPoints, endBoxes, endImages),
    ));
    _scheduleSave();
  }

  /// The four corner handles of the selection [r] on page [pageIndex]. They sit above the pen's layer, so that the pen (or a
  /// finger, or the mouse) takes them instead of writing.
  /// What keeps its size on the screen on a canvas, however far it is zoomed: the factor to draw it with.
  double get _uiScale => _infinite ? 1 / _pageScale : 1.0;

  List<Widget> _resizeHandles(Rect r, int pageIndex) {
    final k = _uiScale; // (on a canvas the handles keep their size on the screen however far it is zoomed)
    final grab = 34.0 * k;
    final primary = Theme.of(context).colorScheme.primary;
    final t = _tightSelectionBounds() ?? r;
    // (name, where the handle is, the corner of what is selected it pulls, the corner that stays)
    final corners = <(String, Offset, Offset, Offset)>[
      ('tl', r.topLeft, t.topLeft, t.bottomRight),
      ('tr', r.topRight, t.topRight, t.bottomLeft),
      ('bl', r.bottomLeft, t.bottomLeft, t.topRight),
      ('br', r.bottomRight, t.bottomRight, t.topLeft),
    ];
    return [
      for (final (name, at, corner, anchor) in corners)
        Positioned(
          key: ValueKey('resize-$name'),
          left: at.dx - grab / 2,
          top: at.dy - grab / 2,
          width: grab,
          height: grab,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _startResize(corner, anchor, e.pointer),
            onPointerMove: (e) => _resizeBy(e.delta, free: HardwareKeyboard.instance.isShiftPressed),
            onPointerUp: (_) => _endResize(),
            onPointerCancel: (_) => _endResize(),
            child: Center(
              child: Container(
                width: 14 * k,
                height: 14 * k,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: primary, width: 2 * k),
                ),
              ),
            ),
          ),
        ),
    ];
  }

  void _moveSelection(Offset delta) {
    // (a connector goes with the items it is fixed to; on its own it stays between them)
    final ids = {for (final b in _groupBoxes) b.id, for (final m in _groupImages) m.id, for (final s in _selection) s.id};
    for (final st in _selection) {
      if (st.link != null && !st.link!.items.every(ids.contains)) continue;
      for (var i = 0; i < st.points.length; i++) {
        st.points[i] += delta;
      }
    }
    for (final b in _groupBoxes) {
      b.position += delta;
    }
    for (final m in _groupImages) {
      m.position += delta;
    }
  }

  /// Deletes what is selected: drawings, and the text boxes and pictures the lasso took.
  /// One step to take back.
  void _deleteSelectedStroke() {
    if (!_hasSelection) return;
    final page = _selectedStrokePage;
    setState(() {
      final list = _strokesPerPage[page];
      final removed = [
        for (var i = 0; list != null && i < list.length; i++)
          if (_selection.contains(list[i])) (page: page, index: i, stroke: list[i]),
      ];
      list?.removeWhere(_selection.contains);
      final boxes = _textBoxesPerPage[page];
      final removedBoxes = [
        for (var i = 0; boxes != null && i < boxes.length; i++)
          if (_groupBoxes.contains(boxes[i])) (page: page, index: i, box: boxes[i]),
      ];
      boxes?.removeWhere(_groupBoxes.contains);
      final images = _imagesPerPage[page];
      final removedImages = [
        for (var i = 0; images != null && i < images.length; i++)
          if (_groupImages.contains(images[i])) (page: page, index: i, image: images[i]),
      ];
      images?.removeWhere(_groupImages.contains);
      _pushRemoval(removed, boxes: removedBoxes, images: removedImages);
      if (_groupBoxes.contains(_activeSelectedBox)) _activeSelectedBox = null;
      _clearSelection();
    });
    _scheduleSave();
  }

  /// The selection box and its delete button, above the drawing layer.
  /// Takes [box] off the note.
  void _deleteTextBox(TextBoxWidgetModel box) {
    setState(() {
      for (final boxes in _textBoxesPerPage.values) {
        boxes.remove(box);
      }
      if (_activeSelectedBox == box) _activeSelectedBox = null;
    });
    _scheduleSave();
  }

  /// The tools above the selected text box (bold, italic, underline, style, delete), like the ones over selected drawings.
  /// It lives in a layer over the whole page so that it can be pressed where it sticks out.
  /// The tools over the selection and over the selected text box. They are outside the page's clip, so that they are whole where
  /// they reach over the page's edge.
  /// Puts [child] (the tools) just above [sel], the selection on page [page], at their size on the screen however the page is
  /// scaled. They live over the whole work surface, not on the page: they are whole where they reach over the page's edge, and
  /// pushed in from the surface's own edges instead of cut off by them.
  Widget _aboveSelection(int page, Rect sel, {required Widget child}) {
    return _ToolsLayer(
      areaKey: _areaKey,
      tileKey: _tileKeys.putIfAbsent(page, () => GlobalKey()),
      selection: sel,
      moves: Listenable.merge([_pageScroll, _hScroll, _viewTick, _textChanges]),
      rightInset: _infinite ? 0 : 44, // (the scrollbar)
      child: child,
    );
  }

  /// The tools of what is selected on pages [pages], for the work surface.
  List<Widget> _toolsOverSurface() {
    final box = _activeSelectedBox;
    final pages = <int>{
      if (box != null) ?_pageOfBox(box),
      if (_selectedStrokePage >= 0) _selectedStrokePage,
    };
    return [for (final p in pages) _toolbarsOverPage(p)];
  }

  Widget _toolbarsOverPage(int pageIndex) {
    final box = _activeSelectedBox;
    final b = box != null && (_textBoxesPerPage[pageIndex]?.contains(box) ?? false) && !_inGutter(box) ? box : null;
    final r = _selectedStrokePage == pageIndex ? _selectionBounds() : null;
    if (b == null && r == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (b != null) ...[
            // (showBox says that box is there)
          _aboveSelection(
            pageIndex,
            b.position & b.size,
            child: Material(
              elevation: 3,
              shape: const StadiumBorder(),
              color: Theme.of(context).colorScheme.surface,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (icon, tooltip, attribute) in [
                    (Icons.format_bold_rounded, 'Bold', AttributeType.bold),
                    (Icons.format_italic_rounded, 'Italic', AttributeType.italic),
                    (Icons.format_underlined_rounded, 'Underline', AttributeType.underline),
                  ])
                    IconButton(
                      icon: Icon(icon, size: 20),
                      tooltip: tr(tooltip),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => b.controller.toggleAttributeForSelection(attribute)),
                    ),
                  IconButton(
                    key: const ValueKey('box-style'),
                    icon: const Icon(Icons.palette_outlined, size: 20),
                    tooltip: tr('Style: background, border, opacity'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => showDialog<void>(
                      context: context,
                      barrierColor: Colors.transparent, // the box behind changes as you go
                      builder: (context) => TextBoxStyleDialog(
                        initial: b.style,
                        onChanged: (style) {
                          setState(() => b.style = style);
                          _scheduleSave();
                        },
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('duplicate-text-box'),
                    icon: const Icon(Icons.copy_all_outlined, size: 20),
                    tooltip: tr('Duplicate text box'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _duplicateTextBox(b),
                  ),
                  IconButton(
                    key: const ValueKey('delete-text-box'),
                    icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                    tooltip: tr('Delete text box'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _deleteTextBox(b),
                  ),
                ],
              ),
            ),
          ),
          ],
          if (r != null) ...[
          _aboveSelection(
            pageIndex,
            r,
            child: Material(
              elevation: 3,
              shape: const StadiumBorder(),
              color: Theme.of(context).colorScheme.surface,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.handwriting != null && _selection.isNotEmpty)
                    IconButton(
                      key: const ValueKey('convert-to-text'),
                      icon: _readyDot(Icons.abc, math: false),
                      tooltip: tr('Convert handwriting to text'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _convertSelection(widget.handwriting!),
                    ),
                  if (widget.math != null && _selection.isNotEmpty)
                    IconButton(
                      key: const ValueKey('convert-to-math'),
                      icon: _readyDot(Icons.functions, math: true),
                      tooltip: tr('Convert a handwritten formula to LaTeX'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          _convertSelection(widget.math!, math: true),
                    ),
                  if (_selection.length >= 3 && _on(Feature.diagrams))
                    IconButton(
                      key: const ValueKey('diagram-from-drawing'),
                      icon: const Icon(Icons.account_tree_outlined),
                      tooltip: tr('Make a state diagram, tree or graph of this drawing'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(_diagramFromDrawing()),
                    ),
                  if (widget.math != null && _selection.isNotEmpty && _on(Feature.checkMaths))
                    IconButton(
                      key: const ValueKey('check-selected-maths'),
                      icon: const Icon(Icons.rule),
                      tooltip: tr('Check the maths in the selection'),
                      visualDensity: VisualDensity.compact,
                      onPressed: _checkSelectedMaths,
                    ),
                  if (_soundPointOfSelection() != null) _playFromHereButton(),
                  if (_selection.any((s) => s.link != null)) _routeButton(forSelection: true),
                  if (_selection.isNotEmpty)
                    IconButton(
                      key: const ValueKey('style-selection'),
                      icon: const Icon(Icons.palette_outlined),
                      tooltip: tr('Style: colour, width, dashes and fill'),
                      visualDensity: VisualDensity.compact,
                      onPressed: _styleSelection,
                    ),
                  if (_mayLabel)
                    IconButton(
                      key: const ValueKey('label-selection'),
                      icon: Icon(Icons.text_rotation_angleup, color: _selection.first.label == null ? null : Theme.of(context).colorScheme.primary),
                      tooltip: tr('Text on the line or in the shape'),
                      visualDensity: VisualDensity.compact,
                      onPressed: _editLabel,
                    ),
                  if (_mayArrange) _arrangeButton(),
                  ..._groupButtons(),
                  if (_mayEditCurve)
                    IconButton(
                      key: const ValueKey('edit-points'),
                      icon: const Icon(Icons.polyline_outlined),
                      tooltip: tr('Edit the points of this line'),
                      visualDensity: VisualDensity.compact,
                      onPressed: _editCurve,
                    ),
                  if (_mayCombine) _combineButton(),
                  if (_selection.isNotEmpty && _on(Feature.stamps))
                    IconButton(
                      key: const ValueKey('save-stamp'),
                      icon: const Icon(Icons.bookmark_add_outlined),
                      tooltip: tr('Save as a stamp'),
                      visualDensity: VisualDensity.compact,
                      onPressed: _saveAsStamp,
                    ),
                  IconButton(
                    key: const ValueKey('duplicate-selection'),
                    icon: const Icon(Icons.copy_all_outlined),
                    tooltip: tr(_groupBoxes.isEmpty && _groupImages.isEmpty ? 'Duplicate drawing' : 'Duplicate the selection'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _duplicateSelection,
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    tooltip: tr(_groupBoxes.isEmpty && _groupImages.isEmpty ? 'Delete drawing' : 'Delete the selection'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _deleteSelectedStroke,
                  ),
                ],
              ),
            ),
          ),
          ],
        ],
      ),
    );
  }

  Widget _selectionOverlay(int pageIndex) {
    if (_selectedStrokePage == pageIndex) {
      _selection.removeWhere(
        (st) => !(_strokesPerPage[pageIndex]?.contains(st) ?? false),
      ); // erased or undone
      _groupBoxes.removeWhere((b) => !(_textBoxesPerPage[pageIndex]?.contains(b) ?? false));
      _groupImages.removeWhere((m) => !(_imagesPerPage[pageIndex]?.contains(m) ?? false));
    }
    _takeWholeGroups(pageIndex); // (what is in a group with something selected is selected too)
    final r = _selectedStrokePage == pageIndex ? _selectionBounds() : null;
    if (r == null) return const SizedBox.shrink();
    final primary = Theme.of(context).colorScheme.primary;
    final box = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: primary, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fromRect(
            rect: r,
            child: _mode == CanvasInteractionMode.draw
                // the pen listener of the draw mode moves it
                ? IgnorePointer(child: box)
                : ElementDragDetector(
                    onDragStart: _startStrokeDrag,
                    // (the frame covers what is under it: Shift picks that, to add it or take it out)
                    onTapUp: (d) {
                      if (_addingToSelection) _shiftTapAt(pageIndex, r.topLeft + d.localPosition);
                    },
                    child: box,
                  ),
          ),
          ..._resizeHandles(r, pageIndex),
        ],
      ),
    );
  }

  /// Asks for a new look for the selected drawings and gives it to all of them (one step to take back).
  Future<void> _styleSelection() async {
    final strokes = List.of(_selection);
    if (strokes.isEmpty) return;
    final style = await showShapeStyleDialog(context, ShapeStyle.of(strokes.first));
    if (style == null || !mounted) return;
    final before = [for (final s in strokes) ShapeStyle.of(s)];
    void apply(Iterable<ShapeStyle> styles) {
      var i = 0;
      for (final st in styles) {
        final s = strokes[i++];
        s.color = st.color;
        s.width = st.width;
        s.dash = st.dash;
        s.fill = st.fill;
        s.gradient = st.gradient;
      }
    }

    setState(() {
      apply(List.filled(strokes.length, style));
      _undoStack.push(UndoStep(() => apply(before), () => apply(List.filled(strokes.length, style))));
    });
    _scheduleSave();
  }

  /// Reads the selected drawings with [hw] (as text, or as a formula when
  /// [math]) and offers the result.
  Future<void> _convertSelection(InkRecognizer hw, {bool math = false}) async {
    final what = math ? 'formula' : 'handwriting';
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final strokes = List.of(_selection);
    final page = _selectedStrokePage;
    final bounds = _selectionBounds();
    if (strokes.isEmpty || bounds == null) return;

    // read ahead of time (see the automation "Read the writing and formulas ahead of time"): it is there at once
    final ready = math ? _ink?.lookupMath(strokes) : _ink?.lookupText(strokes);

    if (ready == null && hw.status != HandwritingStatus.installed) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: Text.verbatim(tr('Download the {what} model?', {'what': tr(what)})),
          content: Text.verbatim(
            tr('Reading a {what} works on this device, without sending anything away. It needs a model of about {size} MB, downloaded once.',
                {'what': tr(what), 'size': hw.sizeMb}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: ListenableBuilder(
            listenable: hw,
            builder: (context, _) => PlatformAlertDialog(
              title: const Text('Downloading the model'),
              content: LinearProgressIndicator(
                value: hw.progress > 0 ? hw.progress : null,
              ),
            ),
          ),
        ),
      );
      await hw.install();
      navigator.pop();
      if (hw.status != HandwritingStatus.installed) {
        messenger.showSnackBar(
          SnackBar(content: Text.verbatim(tr('Could not download the model: {error}', {'error': hw.error}))),
        );
        return;
      }
    }
    if (!mounted) return;

    // the route is pushed now, so it can be closed even before it has built
    var busyClosed = ready != null; // (nothing to close when the text was there already)
    void closeBusy() {
      if (busyClosed) return;
      busyClosed = true;
      if (navigator.mounted) navigator.pop();
    }

    if (ready == null) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      pageBuilder: (_, _, _) => PopScope(
        canPop: false,
        child: Center(
          child: PlatformAlertDialog(
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Text.verbatim(tr('Reading the {what}...', {'what': tr(what)})),
              ],
            ),
          ),
        ),
      ),
    );
    }
    String text;
    try {
      // (one job at a time with what is being read in the background)
      text = ready ?? await (_ink?.exclusive(() => hw.recognize(strokes)) ?? hw.recognize(strokes));
      if (ready == null) _ink?.remember(strokes, text, math: math);
    } catch (e) {
      closeBusy();
      messenger.showSnackBar(
        SnackBar(content: Text.verbatim(tr('Could not read the {what}: {error}', {'what': tr(what), 'error': e}))),
      );
      return;
    }
    closeBusy();
    if (!mounted) return;

    final controller = TextEditingController(text: text);
    final choice =
        await showDialog<({String text, bool replace, String? solution})>(
          context: context,
          builder: (context) => PlatformAlertDialog(
            title: Text(
              math ? 'Recognized formula (LaTeX)' : 'Recognized text',
            ),
            content: SizedBox(
              width: 420,
              child: TextField(
                key: const ValueKey('recognized-text'),
                controller: controller,
                autofocus: true,
                minLines: 2,
                maxLines: 8,
                decoration: InputDecoration(
                  helperText: tr('Check it and fix what was misread.'),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              if (math)
                TextButton(
                  key: const ValueKey('solve-equation'),
                  onPressed: () async {
                    final solved = await _solveDialog(context, controller.text);
                    if (solved != null && context.mounted) {
                      Navigator.pop(context, (
                        text: controller.text,
                        replace: false,
                        solution: solved,
                      ));
                    }
                  },
                  child: const Text('Calculate...'),
                ),
              OutlinedButton(
                onPressed: () => Navigator.pop(context, (
                  text: controller.text,
                  replace: false,
                  solution: null,
                )),
                child: const Text('Add text box'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, (
                  text: controller.text,
                  replace: true,
                  solution: null,
                )),
                child: const Text('Replace drawing'),
              ),
            ],
          ),
        );
    // the dialog is still animating out; its text field must not lose the controller yet
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (choice == null || choice.text.trim().isEmpty || !mounted) return;

    final result = choice.text.trim();
    final shown = math && !result.startsWith(r'$') ? '\$$result\$' : result;
    _addTextBoxAt(
      page,
      bounds.topLeft,
      initialText: choice.solution == null
          ? shown
          : '$shown\n\n\$${choice.solution}\$',
    );
    if (choice.replace) {
      setState(() {
        _strokesPerPage[page]?.removeWhere(strokes.contains);
        _clearSelection();
      });
    }
  }
}

/// Tools drawn over the work surface at the screen position of a rectangle on a page (found through the page's own render box, so
/// zoom, scrolling and the page's scale are all in it), at their own size. They follow the page when it scrolls or zooms.
class _ToolsLayer extends StatefulWidget {
  const _ToolsLayer({
    required this.areaKey,
    required this.tileKey,
    required this.selection,
    required this.moves,
    required this.rightInset,
    required this.child,
  });
  final GlobalKey areaKey, tileKey;
  final Rect selection;
  final Listenable moves;
  final double rightInset;
  final Widget child;

  @override
  State<_ToolsLayer> createState() => _ToolsLayerState();
}

class _ToolsLayerState extends State<_ToolsLayer> {
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    widget.moves.addListener(_later);
  }

  @override
  void didUpdateWidget(_ToolsLayer old) {
    super.didUpdateWidget(old);
    if (old.moves != widget.moves) {
      old.moves.removeListener(_later);
      widget.moves.addListener(_later);
    }
  }

  @override
  void dispose() {
    widget.moves.removeListener(_later);
    super.dispose();
  }

  /// The page has moved: once it is laid out again, the tools go where it is.
  void _later() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final tile = widget.tileKey.currentContext?.findRenderObject();
    final area = widget.areaKey.currentContext?.findRenderObject();
    if (tile is! RenderBox || area is! RenderBox || !tile.attached || !area.attached || !tile.hasSize || !area.hasSize) {
      // (not laid out yet: the next frame has it)
      _later();
      return const SizedBox.shrink();
    }
    final rect = MatrixUtils.transformRect(tile.getTransformTo(area), widget.selection);
    if (!(Offset.zero & area.size).overlaps(rect)) return const SizedBox.shrink(); // (scrolled out of sight)
    return Positioned.fill(
      child: CustomSingleChildLayout(delegate: _ToolsLayout(rect, widget.rightInset), child: widget.child),
    );
  }
}

class _ToolsLayout extends SingleChildLayoutDelegate {
  _ToolsLayout(this.rect, this.rightInset);
  final Rect rect;
  final double rightInset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = rect.left.clamp(0.0, math.max(0.0, size.width - rightInset - childSize.width)).toDouble();
    final y = (rect.top - 40).clamp(0.0, math.max(0.0, size.height - childSize.height)).toDouble();
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_ToolsLayout o) => o.rect != rect || o.rightInset != rightInset;
}
