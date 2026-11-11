part of 'fixed_page_note_editor.dart';

/// A ring where the pen hovers over the page, as big as the line it would draw.
class _HoverRing extends CustomPainter {
  final Offset at;
  final double radius;
  final Color color;
  const _HoverRing(this.at, this.radius, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final r = radius < 2 ? 2.0 : radius;
    canvas.drawCircle(at, r, Paint()..color = Colors.white.withValues(alpha: 0.5)..style = PaintingStyle.stroke..strokeWidth = 2.5);
    canvas.drawCircle(at, r, Paint()..color = color.withValues(alpha: 0.9)..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_HoverRing old) => old.at != at || old.radius != radius || old.color != color;
}

/// White paper with a spinner: a page that is being read or drawn.
/// What is on screen of a page, rendered as sharp as the zoom needs: [rect] is where it goes, in units of the page, and [fullWidth]
/// the width in pixels the whole page would have at that sharpness.
class _SharpPatch {
  final ui.Image image;
  final Rect rect;
  final int fullWidth;
  _SharpPatch(this.image, this.rect, this.fullWidth);

  void dispose() => image.dispose();
}

/// Tells the editor while a page is built (on screen or about to be): the work for a page that is shown is never dropped.
class _BuiltPage extends StatefulWidget {
  final int index;
  final void Function(int index, bool shown) onShown;
  final Widget child;
  const _BuiltPage({required this.index, required this.onShown, required this.child});

  @override
  State<_BuiltPage> createState() => _BuiltPageState();
}

class _BuiltPageState extends State<_BuiltPage> {
  @override
  void initState() {
    super.initState();
    widget.onShown(widget.index, true);
  }

  @override
  void didUpdateWidget(_BuiltPage old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      old.onShown(old.index, false);
      widget.onShown(widget.index, true);
    }
  }

  @override
  void dispose() {
    widget.onShown(widget.index, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The picture of a PDF page. It keeps a handle of the image of its own, so that the page being let go of by the editor (it is far from
/// the one in view) or read again (the PDF changed) does not take the picture from under it; until the new picture is there the old
/// one stays.
class _PageImage extends StatefulWidget {
  final PdfPageData data;
  final double? width;
  final double? height;
  final FilterQuality quality;

  const _PageImage({required this.data, this.width, this.height, this.quality = FilterQuality.low});

  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _image = widget.data.alive ? widget.data.image.clone() : null; // (data that was let go of before it got here: wait for the new)
  }

  @override
  void didUpdateWidget(_PageImage old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data) && widget.data.alive) {
      _image?.dispose();
      _image = widget.data.image.clone();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const _PageSpinner();
    return RawImage(image: image, width: widget.width, height: widget.height, fit: BoxFit.fill, filterQuality: widget.quality);
  }
}

class _PageSpinner extends StatelessWidget {
  final String? label;
  const _PageSpinner({this.label});

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.white,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator.adaptive(strokeWidth: 3)),
            if (label != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text.verbatim(label!, style: const TextStyle(color: Colors.black54))),
          ]),
        ),
      );
}

/// The paper of each sheet of a written document, with nothing of the gaps between them.
class _SheetsClipper extends CustomClipper<Path> {
  final int sheets;
  final double height;
  final double gap;
  const _SheetsClipper({required this.sheets, required this.height, required this.gap});

  @override
  Path getClip(Size size) {
    final path = Path();
    if (sheets <= 1) return path..addRect(Offset.zero & size,); // (one sheet: the paper is as tall as the page, which may grow with its content)
    for (var k = 0; k < sheets; k++) {
      path.addRect(Rect.fromLTWH(0, k * (height + gap), size.width, height));
    }
    return path;
  }

  @override
  bool shouldReclip(_SheetsClipper old) => old.sheets != sheets || old.height != height || old.gap != gap;
}

/// One page as it is laid out on screen: the text layer, the drawing layer and what is on it.
extension _EditorPageTile on _FixedPageNoteEditorState {
  /// First page in document mode: the editable sheet with the page's drawings
  /// and text boxes drawn over it, not reacting to input.
  Widget _buildDocumentEditorPage() {
    final stacking = _stackingOf(0);
    return Stack(
      children: [
        DocumentSheet(
          controller: _documentController,
          width: _paperWidth,
          minHeight: basePageHeight,
          background: _background,
          marginLeft: _marginLeft,
          marginRight: _marginRight,
          marginTop: _marginTop,
          marginBottom: _marginBottom,
          menuBuilder: (context, menu) => _calculateMenu(_MenuOn.blocks(menu), _documentController),
          selectionControls: selectionControlsAtZoom(() => _pageScale),
          onLink: _openLink,
          onCitation: (run) => _editCitation(_documentController, run),
          spell: widget.spell,
          pageHeight: basePageHeight,
          sheetGap: _FixedPageNoteEditorState._sheetGap,
          blocksKey: _documentEditor,
          onContent: _insertKeyboardPicture,
          onSheets: (sheets) => setState(() {
            _writtenSheets = sheets;
            _documentContentHeight = sheets * (basePageHeight - _marginTop - _marginBottom);
          }),
        ),
        Positioned.fill(
          child: IgnorePointer(
            // (drawings, pictures and boxes are cut at the paper's edge, as on every other page: not drawn over its borders or in the gap between sheets)
            child: ClipPath(
              clipper: _SheetsClipper(sheets: _sheetsOfDocument, height: basePageHeight, gap: _FixedPageNoteEditorState._sheetGap),
              child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (final m in _imagesPerPage[0] ?? const <ImageItem>[])
                  if (_imageUsual(stacking, m)) _imageWidget(0, m),
                Positioned.fill(
                  child: CustomPaint(
                    painter: HighlightsPainter(
                      highlights: _highlightsPerPage[0] ?? [],
                    ),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: UnifiedInkPainter(
                      strokes: _strokesPerPage[0] ?? [],
                      layers: _layers,
                      pressureSensitivity: widget.stylus?.effectiveSensitivity ?? 0.6,
                      only: _usualInk(stacking),
                    ),
                  ),
                ),
                ...(_textBoxesPerPage[0] ?? []).where((b) => !_inGutter(b) && _boxUsual(stacking, b)).map(_buildFloatingTextBox),
                if (stacking != null) ..._stackedAbove(stacking, 0),
              ],
            ),
            ),
          ),
        ),
      ],
    );
  }

  // ---- taking back drawing (undo and redo)

  /// [page] is null for a page of the blank notebook (white, no text layer).
  Widget _buildPageTile(int pageIndex, PdfPageData? page) {
    final pageHeight = page == null
        ? _shownPageHeight(pageIndex)
        : _paperWidth * page.pageHeight / page.pageWidth;
    // a written document that is longer than a page: each sheet is a page of its own, with the space between them
    final split = page == null && _isDocumentPage(pageIndex) && _documentSheets > 1;
    _syncConnectors(pageIndex); // (before the lines are painted: the connectors follow their items)
    final pageStrokes = _strokesPerPage[pageIndex] ?? [];
    final pageBoxes = _textBoxesPerPage[pageIndex] ?? [];
    final stacking = _stackingOf(pageIndex);
    final pageHighlights = _highlightsPerPage[pageIndex] ?? [];

    final tile = Container(
      key: _tileKeys.putIfAbsent(pageIndex, () => GlobalKey()),
      width: _paperWidth,
      height: pageHeight,
      // (none for the sheets of a document, which have their own: and nothing of the tile takes a tap that is for what is on them, below it)
      decoration: split
          ? null
          : BoxDecoration(
        color: Colors.white, // (paper: the dark theme does not darken a page, and a page still being drawn must not show as a black sheet)
        boxShadow: _infinite
            ? null // (a canvas has no edge to cast one)
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
        Positioned.fill(child: ClipRect(
        child: Stack(
          children: [
            // Z-INDEX 0: Original Document Render / blank paper / written document
            if (page == null && _isDocumentPage(pageIndex) && !split)
              CustomPaint(
                painter: PageBackgroundPainter(_background),
                size: Size(_paperWidth, pageHeight),
              ),
            if (split)
              const SizedBox.shrink()
            else if (page == null && _isDocumentPage(pageIndex))
              Builder(
                builder: (_) {
                  _measureDocument();
                  return Padding(
                    padding: EdgeInsets.fromLTRB(
                      _marginLeft,
                      _marginTop,
                      _marginRight,
                      _marginBottom,
                    ),
                    // (as tall as the text is: inside the page's own height it would be cut at the page's end, and what is measured
                    // here to make the page that tall would never be more than that)
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: LiveMarkdownView(
                        key: _documentMeasureKey,
                        controller: _documentController,
                        fontSize: DocumentSheet.fontSize,
                        inTurn: _readPieces,
                        actions: LiveMarkdownActions(onHeading: _readHeading),
                      ),
                    ),
                  );
                },
              )
            else if (page == null && _infinite)
              CustomPaint(
                painter: CanvasBackgroundPainter(_background, _viewWindow, repaint: _viewTick),
                size: Size(_paperWidth, pageHeight),
              )
            else if (page == null)
              CustomPaint(
                painter: PageBackgroundPainter(_background),
                size: Size(_paperWidth, pageHeight),
              )
            else
              Builder(
                builder: (context) {
                  // zoomed in: ask for a sharper picture of what is on screen of this page (shown over the normal one)
                  if (_hiResWidth > 0) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _requestHiRes(pageIndex),
                    );
                  }
                  final sharp = _hiRes[pageIndex];
                  return Stack(
                    children: [
                      _PageImage(data: page, width: _paperWidth, height: pageHeight),
                      if (sharp != null)
                        Positioned.fromRect(
                          rect: sharp.rect,
                          child: RawImage(
                            image: sharp.image,
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                    ],
                  );
                },
              ),

            // pictures sit on the page, under the highlights, drawings and text boxes
            // (those of a higher layer than some of the lines or boxes are over these: see [_stackedAbove])
            for (final m in _imagesPerPage[pageIndex] ?? const <ImageItem>[])
              if (_imageUsual(stacking, m)) _imageWidget(pageIndex, m),

            // Z-INDEX 1: Annotations (Highlights)
            // (not in the way of the written document, which is below it: what is on that is tapped through it)
            IgnorePointer(
              ignoring: _isDocumentPage(pageIndex),
              child: CustomPaint(
                painter: HighlightsPainter(highlights: pageHighlights),
                size: Size(_paperWidth, pageHeight),
              ),
            ),

            if (page != null) ValueListenableBuilder<PdfPageWords?>(
              valueListenable: _wordsNotifier(pageIndex),
              builder: (_, words, _) => words == null ? const SizedBox.shrink() : _findOverlay(pageIndex, words),
            ),
            _inkFindOverlay(pageIndex),
            _followOverlay(pageIndex),

            // Z-INDEX 2: Selectable Text Layer with Unrestricted Double-Tap Detection
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) {
                if (_tripleClick(e)) _addTextBoxAt(pageIndex, e.localPosition);
              },
              child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (d) {
                if (_boxJustMade) return;
                if (_mode == CanvasInteractionMode.selectText && _editHighlightAt(pageIndex, d.localPosition, d.globalPosition)) return;
                setState(() {
                  _activeSelectedBox = null;
                  _selectedImage = null;
                });
              },
              // A double tap makes a text box with a finger or a pen. A mouse does not take
              // part at all (it needs three clicks, above): a double click is the text
              // layer's own, which selects the word under it.
              child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus, PointerDeviceKind.unknown},
              onDoubleTapDown: (details) => _addTextBoxAt(pageIndex, details.localPosition),
              // (a canvas has no text to select, and the selection would take the drags that move the canvas)
              child: _infinite ? const SizedBox.expand() : SelectionArea(
                key: _areaKeys.putIfAbsent(pageIndex, () => GlobalKey<SelectionAreaState>()),
                selectionControls: selectionControlsAtZoom(() => _pageScale, stretch: (type) => _handleStretch(pageIndex, type)),
                onSelectionChanged: (content) {
                  setState(() {
                    final text = content?.plainText.trim();
                    if (text != null && text.isNotEmpty) {
                      _currentSelectedText = text;
                      _currentSelectedPageIndex = pageIndex;
                    } else if (_currentSelectedPageIndex == pageIndex) {
                      _currentSelectedText = null;
                      _currentSelectedPageIndex = null;
                    }
                  });
                },
                contextMenuBuilder: (context, selectableRegionState) {
                  final buttonItems = <ContextMenuButtonItem>[
                    ...selectableRegionState.contextMenuButtonItems,
                  ];
                  buttonItems.addAll(
                    _lookupItems(_currentSelectedText, selectableRegionState.hideToolbar),
                  );
                  buttonItems.addAll(_extensionItemsForReading(_currentSelectedText, selectableRegionState.hideToolbar));
                  final picked = _currentSelectedText;
                  buttonItems.addAll(_summarizeItems(
                    picked,
                    selectableRegionState.hideToolbar,
                    () async {
                      final at = await _positionUnderSelection(pageIndex, picked);
                      return (summary) => _addTextBoxAt(pageIndex, at, initialText: summary);
                    },
                  ));
                  buttonItems.add(
                    ContextMenuButtonItem(
                      label: 'Highlight',
                      onPressed: () {
                        selectableRegionState.hideToolbar();
                        _applyHighlightOrCommentToSelection(
                          pageIndex,
                          _currentSelectedText,
                          isComment: false,
                        );
                      },
                    ),
                  );
                  buttonItems.add(
                    ContextMenuButtonItem(
                      label: 'Comment',
                      onPressed: () {
                        selectableRegionState.hideToolbar();
                        _applyHighlightOrCommentToSelection(
                          pageIndex,
                          _currentSelectedText,
                          isComment: true,
                        );
                      },
                    ),
                  );

                  return menuAtScreenSize(
                    selectableRegionState.context,
                    AdaptiveTextSelectionToolbar.buttonItems(
                      anchors: selectableRegionState.contextMenuAnchors,
                      buttonItems: buttonItems,
                    ),
                  );
                },
                // one piece of text per word, stretched over the word's place on the page: where the finger lands is then the word it
                // lands on. The words come after the picture (they are read apart, after the pictures on screen).
                child: page == null
                    ? const Stack()
                    : ValueListenableBuilder<PdfPageWords?>(
                        valueListenable: _wordsNotifier(_requestWords(pageIndex)),
                        builder: (_, words, _) => Stack(children: [
                          if (words != null)
                            for (var li = 0; li < words.lines.length; li++)
                              for (var wi = 0; wi < words.lines[li].words.length; wi++) _selectableWord(pageIndex, words, li, wi, pageHeight),
                        ]),
                      ),
              ),
              ),
              ),
            ),

            // (the faint lines of the pages next to this one, for drawing frames of an animation)
            ..._onionLayers(pageIndex, pageHeight),

            // Z-INDEX 3: Vector Drawing Ink Layer - the finished lines as one kept picture, the line being drawn above it
            // (each in a layer of its own, so that a move of the pen paints only that line)
            IgnorePointer(
              ignoring: true,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: InkLayerPainter(strokes: pageStrokes, skip: _currentActiveStroke ?? _penEditing, layers: _layers, pressureSensitivity: widget.stylus?.effectiveSensitivity ?? 0.6, only: _usualInk(stacking), pixelScale: _inkPixelScale),
                  isComplex: true,
                  size: Size(_paperWidth, pageHeight),
                ),
              ),
            ),
            if (_currentActiveStroke != null && pageStrokes.isNotEmpty && identical(pageStrokes.last, _currentActiveStroke) && _activeInUsualPlace(stacking))
              IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: ActiveInkPainter(() => _currentActiveStroke, repaint: _inkTick, pressureSensitivity: widget.stylus?.effectiveSensitivity ?? 0.6, alongside: () => _symmetryCopies),
                    size: Size(_paperWidth, pageHeight),
                  ),
                ),
              ),

            // the guides: an overlay, the spokes of a perspective drawing, a ruler or a set square
            if (_mode == CanvasInteractionMode.draw && _guidesShown) _guidesLayer(pageIndex, pageHeight),

            // where what is being moved lines up with something else
            if (_alignLines.isNotEmpty && _alignPage == pageIndex) _alignLinesLayer(pageHeight),

            // where symmetry repeats what is drawn: the mirror lines or the spokes, about the middle of the page
            if (_mode == CanvasInteractionMode.draw && _on(Feature.symmetry) && !_symmetry.isOff)
              IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey('symmetry-guide'),
                  painter: SymmetryGuidePainter(_symmetry, _symmetryCentre(pageHeight), Theme.of(context,).colorScheme.primary.withValues(alpha: 0.35)),
                  size: Size(_paperWidth, pageHeight),
                ),
              ),

            // the line the pen for curves is making
            if (_penPath != null) _penToolLayer(pageIndex, pageHeight),

            if (_lassoPath != null && _lassoPage == pageIndex)
              IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: LassoPainter(
                      _lassoPath!,
                      Theme.of(context).colorScheme.primary,
                      repaint: _inkTick,
                    ),
                    size: Size(_paperWidth, pageHeight),
                  ),
                ),
              ),

            // a short tap on a drawing picks it (text selection underneath keeps working)
            if (_mode == CanvasInteractionMode.selectText)
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (e) {
                    _downAt = e.localPosition;
                    _downTime = DateTime.now();
                    _travel = 0;
                  },
                  onPointerMove: (e) => _travel = math.max(
                    _travel,
                    (e.localPosition - _downAt).distance,
                  ),
                  onPointerUp: (e) {
                    // a finger may let go too, even when a pen has been used: only
                    // a pen that is down now means the hand is resting on the page
                    _drawsWith(e);
                    if (_penDown || _travel >= 6 || _boxJustMade) return; // (the tap that made a text box is not one on the page)
                    if (DateTime.now().difference(_downTime) >
                        const Duration(milliseconds: 350)) {
                      return;
                    }
                    final strokes =
                        _strokesPerPage[pageIndex] ?? const <DrawingStroke>[];
                    final i = strokes.lastIndexWhere(
                      (st) => _layers.editable(st) && st.pickedAt(e.localPosition, 10),
                    );
                    if (_addingToSelection) {
                      // Shift: the drawing joins what is selected, or leaves it; a tap on nothing keeps the selection as it is
                      if (i >= 0) setState(() => _toggleInSelection(pageIndex, stroke: strokes[i]));
                      return;
                    }
                    if (i >= 0) unawaited(_jumpSoundTo(strokes[i].id));
                    if (i < 0 &&
                        _selection.isEmpty &&
                        _selectedImage == null &&
                        _activeSelectedBox == null) {
                      return;
                    }
                    // a tap picks what is under it, and lets go of everything else
                    setState(() {
                      _selection = i < 0 ? [] : [strokes[i]];
                      _selectedStrokePage = pageIndex;
                      _selectedImage = null;
                      _activeSelectedBox = null;
                    });
                    FocusManager.instance.primaryFocus?.unfocus();
                  },
                ),
              ),

            // moving and resizing pictures: above the text layer, which would take the touches
            if (_mode == CanvasInteractionMode.selectText)
              for (final m in _imagesPerPage[pageIndex] ?? const <ImageItem>[])
                _imageWidget(pageIndex, m, controls: true),

            // Z-INDEX 4: Drawing Interceptor (Active only in Draw Mode)
            if (_mode == CanvasInteractionMode.draw)
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  if (_xform != null) return; // (a free transform is going on: the pen draws nothing)
                  if (!_drawsWith(event)) return;
                  if (event.kind == PointerDeviceKind.touch && (_touches.isNotEmpty || _touchGesture)) return; // (a second finger: the two scroll)
                  if (event.kind == PointerDeviceKind.mouse && (event.buttons & kMiddleMouseButton) != 0) return; // (it moves the canvas)
                  // the side button of the pen, set to run a trigger: it does that and does not draw
                  final trigger = _barrelHeld(event) ? _barrelAction.trigger : null;
                  if (trigger != null) {
                    widget.onTrigger?.call(trigger);
                    return;
                  }
                  if (!_erasesWith(event) && _tripleClick(event)) {
                    _addTextBoxAt(pageIndex, event.localPosition); // three quick clicks of the mouse
                    return;
                  }
                  _stylusDown =
                      event.kind == PointerDeviceKind.stylus ||
                      event.kind == PointerDeviceKind.invertedStylus;
                  _penPointer = event.pointer;
                  if (!_penDown) {
                    setState(() => _penDown = true); // freezes the page list
                  }
                  if (_picksWith(event)) return _pickDown(event.position, event.pointer); // (the pen's side button, set to pick a colour)
                  if (_erasesWith(event)) {
                    return _eraseAt(pageIndex, event.localPosition);
                  }
                  if (_bucketOn && !_lassosWith(event)) return _fillAt(pageIndex, event.localPosition, Size(_paperWidth, pageHeight)); // (the bucket: a touch fills, nothing is drawn)
                  _downAt = event.localPosition;
                  _downTime = DateTime.now();
                  _travel = 0;
                  // pressing on the selected drawing drags it instead of writing
                  final selBounds = _selectedStrokePage == pageIndex
                      ? _selectionBounds()
                      : null;
                  _draggingStroke =
                      selBounds != null &&
                      selBounds.contains(event.localPosition) &&
                      !_addingToSelection; // (Shift: a tap there picks what is under it, for the selection)
                  if (_draggingStroke) {
                    _startStrokeDrag(
                      event.position,
                      pointer: event.pointer,
                    ); // followed by the page area
                    return;
                  }
                  if (_lassosWith(event)) {
                    setState(() {
                      if (!_addingToSelection) _clearSelection(); // (Shift: what the lasso takes is added to it)
                      _lassoPath = [event.localPosition];
                      _lassoPage = pageIndex;
                    });
                    return;
                  }
                  if (!_drawingLayer.editable) {
                    _layerBlocked(); // (the layer is hidden or locked: nothing would show)
                    return;
                  }
                  if (_penToolOn) {
                    _penToolDown(pageIndex, event.localPosition, touch: event.kind == PointerDeviceKind.touch);
                    return;
                  }
                  final brush = _highlighter || _shape != ShapeTool.freehand && _activeDrawTool == null ? null : Brushes.byId(_brush);
                  final brushWidth = brush?.widthScale ?? 1.0;
                  setState(() {
                    _currentActiveStroke = DrawingStroke(
                      color: _highlighter
                          ? _selectedPenColor.withValues(
                              alpha: _highlighterOpacity,
                            )
                          : _selectedPenColor,
                      width: _highlighter ? _highlighterWidth : _strokeWidth * brushWidth,
                      points: [event.localPosition],
                      author: Authorship.current,
                      dash: _shape == ShapeTool.freehand ? StrokeDash.solid : _shapeDash,
                      fill: _shape == ShapeTool.freehand ? null : _shapeFill,
                      gradient: _shape == ShapeTool.freehand ? null : _shapeGradient,
                      brush: brush?.id ?? penBrushId,
                      layer: _drawingLayer.id,
                    );
                    // a pen that can tell how hard it presses: the line is thicker where it pressed harder
                    final pressure = _shape == ShapeTool.freehand && !_highlighter && (brush?.usesPressure ?? true) && (widget.stylus?.pressure ?? true) ? _pressureOf(event, first: true) : null;
                    if (pressure != null) _currentActiveStroke!.pressures = [(pressure * 255).round()];
                    _stabiliser = _shape == ShapeTool.freehand && _on(Feature.stabiliser) && _stabiliserStrength > 0 ? (LineStabiliser(_stabiliserStrength)..start(event.localPosition)) : null;
                    _snapper = _startSnapper(pageIndex, event.localPosition, Size(_paperWidth, pageHeight));
                    // (a line begun beside the edge of a ruler begins on it)
                    if (_snapper != null && _snapper!.following) _currentActiveStroke!.points[0] = _snapper!.apply(event.localPosition).point;
                    _startSymmetry(_currentActiveStroke!, _symmetryCentre(pageHeight));
                    _shapeStart = event.localPosition;
                    _connectFrom = _connecting ? _connectHitAt(pageIndex, event.localPosition) : null;
                    _connectOver = null;
                    _strokesPerPage
                        .putIfAbsent(pageIndex, () => [])
                        .add(_currentActiveStroke!);
                  });
                },
                onPointerHover: (event) {
                  if (_penPath != null && _penPage == pageIndex) {
                    _penHover = event.localPosition; // (the line follows the pen to where the next point would be)
                    _inkTick.value++;
                  }
                  if (!(widget.stylus?.hoverRing ?? true) || _lassoing || (event.kind != PointerDeviceKind.stylus && event.kind != PointerDeviceKind.mouse)) return;
                  final erasing = _erasesWith(event);
                  _hover.value = (page: pageIndex, at: event.localPosition, radius: erasing ? _eraserRadius : (_highlighter ? _highlighterWidth : _strokeWidth) / 2, erasing: erasing);
                },
                onPointerMove: (event) {
                  if (!_drawsWith(event)) return;
                  if (event.kind == PointerDeviceKind.touch && _touchGesture) return;
                  if (event.pointer == _pickPointer) return _pickMove(event.position);
                  if (_erasesWith(event)) {
                    _currentActiveStroke = null;
                    return _eraseAt(pageIndex, event.localPosition);
                  }
                  _travel = math.max(
                    _travel,
                    (event.localPosition - _downAt).distance,
                  );
                  if (_draggingStroke) {
                    return; // the page area moves it, also onto other pages
                  }
                  if (_penGrab != null) return _penToolMove(event.localPosition);
                  // (no setState while the pen moves: the tick paints the line or the lasso again, and nothing is built)
                  if (_lassoPath != null) {
                    _lassoPath!.add(event.localPosition);
                    _inkTick.value++;
                    return;
                  }
                  if (_currentActiveStroke != null) {
                    final stroke = _currentActiveStroke!;
                    if (_shape == ShapeTool.freehand) {
                      // (with the stabiliser the line trails the pen on a string, and a wobble of the pen inside it shows nothing)
                      final at = _stabiliser == null ? event.localPosition : _stabiliser!.follow(event.localPosition);
                      // a point closer than about half a pixel to the last one shows nothing new
                      if (at == null) return;
                      final guided = _guided(stroke, at,); // (along the edge of a ruler, or the way of a perspective drawing)
                      if (stroke.points.isNotEmpty && (guided - stroke.points.last).distance < _inkTolerance) return;
                      stroke.points.add(guided);
                      final pr = stroke.pressures;
                      if (pr != null) pr.add(((_pressureOf(event) ?? pr.last / 255) * 255).round());
                      _extendSymmetry(stroke);
                    } else if (_shape == ShapeTool.connector) {
                      _previewConnector(pageIndex, stroke, event.localPosition); // (it snaps to the item it is over)
                    } else {
                      // a shape between where the pen went down and where it is now (Shift: even sides, 45 degrees)
                      stroke.points
                        ..clear()
                        ..addAll(shapePoints(_shape, _shapeStart, event.localPosition,
                            constrain: HardwareKeyboard.instance.isShiftPressed));
                      _remakeSymmetry(stroke);
                    }
                    _inkTick.value++;
                  }
                },
                onPointerUp: (event) {
                  if (event.kind == PointerDeviceKind.touch && _touchGesture) return;
                  if (event.pointer == _pickPointer) {
                    _stylusDown = false;
                    unawaited(_pickUp());
                    return;
                  }
                  _commitErase();
                  if (_penGrab != null) {
                    _stylusDown = false;
                    if (_penDown && event.pointer == _penPointer) setState(() => _penDown = false);
                    return _penToolUp();
                  }
                  final stroke = _currentActiveStroke;
                  _currentActiveStroke = null;
                  final copies = _symmetryCopies; // (the repeats of the line join the page with it, or are dropped with it)
                  _symmetryCopies = [];
                  if (stroke != null && _stabiliser != null && _shape == ShapeTool.freehand && _travel >= 6) {
                    // the line trails the pen: it is brought up to where the pen was lifted
                    for (final p in _stabiliser!.finish(event.localPosition)) {
                      stroke.points.add(_guided(stroke, p));
                      final pr = stroke.pressures;
                      if (pr != null && pr.isNotEmpty) pr.add(pr.last);
                    }
                  }
                  _stabiliser = null;
                  _snapper = null;
                  _stylusDown = false;
                  final moved = _draggingStroke && _travel > 4;
                  final tap =
                      _travel < 6 &&
                      DateTime.now().difference(_downTime) <
                          const Duration(milliseconds: 350) &&
                      !_erasesWith(event);
                  setState(() {
                    if (_penDown && event.pointer == _penPointer) _penDown = false;
                    if (_draggingStroke) {
                      // a tap on the selection keeps it; a drag moved it
                    } else if (_lassoPath != null) {
                      final shape = _lassoPath!;
                      _lassoPath = null;
                      final adding = _addingToSelection && _hasSelection;
                      if (adding) _gatherSelection(pageIndex,); // (the lasso is on the page of the group: it can be added to)
                      // everything that can be placed on the page: drawings, text boxes, pictures
                      final strokes = [
                        for (final st
                            in _strokesPerPage[pageIndex] ??
                                const <DrawingStroke>[])
                          if (_layers.editable(st) && st.mostlyInside(shape)) st,
                      ];
                      final boxes = [
                        for (final b in _textBoxesPerPage[pageIndex] ?? const <TextBoxWidgetModel>[])
                          if (!_inGutter(b) && _boxEditable(b) && _rectMostlyInside(_boxRect(b), shape)) b,
                      ];
                      final images = [
                        for (final m in _imagesPerPage[pageIndex] ?? const <ImageItem>[])
                          if (_imageEditable(m) && _rectMostlyInside(m.position & m.size, shape)) m,
                      ];
                      _selection = adding ? _union(_selection, strokes) : strokes;
                      _groupBoxes = adding ? _union(_groupBoxes, boxes) : boxes;
                      _groupImages = adding ? _union(_groupImages, images) : images;
                      if (_groupBoxes.isNotEmpty || _groupImages.isNotEmpty) {
                        _activeSelectedBox = null; // one selection at a time
                        _selectedImage = null;
                      }
                      _selectedStrokePage = pageIndex;
                    } else if (stroke != null && _travel < 6 && _shape == ShapeTool.freehand && !_erasesWith(event) && !_addingToSelection && _selection.isEmpty && _groupBoxes.isEmpty && _groupImages.isEmpty && event.kind != PointerDeviceKind.mouse) {
                      // a dot (of an i, a full stop): a short tap with a pen or finger writes one while nothing is selected
                      _clearSelection();
                      if (stroke.points.length < 2 || stroke.points.every((p) => p == stroke.points.first)) {
                        stroke.points
                          ..clear()
                          ..addAll([_downAt, _downAt + const Offset(0.1, 0)]);
                      }
                      stroke.pressures = null;
                      _undoStack.push(UndoStep(
                        () => _strokesPerPage[pageIndex]?.remove(stroke),
                        () => _strokesPerPage.putIfAbsent(pageIndex, () => []).add(stroke),
                      ));
                    } else if (stroke != null && tap && _connecting && _connectFrom != null && _connectFrom!.anchor != Anchor.auto) {
                      // a tap on the dot of a side of an item: a new box grows out of it
                      _strokesPerPage[pageIndex]?.remove(stroke);
                      final from = _connectFrom!;
                      _connectFrom = null;
                      _clearSelection();
                      _growBoxFrom(pageIndex, from);
                    } else if (stroke != null && tap) {
                      // a short tap is no line: it picks the drawing under the pen
                      _strokesPerPage[pageIndex]?.remove(stroke);
                      final hit =
                          (_strokesPerPage[pageIndex] ??
                                  const <DrawingStroke>[])
                              .lastWhere(
                                (st) => _layers.editable(st) && st.pickedAt(_downAt, 10),
                                orElse: () => DrawingStroke(
                                  color: Colors.black,
                                  width: 0,
                                  points: const [],
                                ),
                              );
                      if (_addingToSelection) {
                        if (hit.points.isNotEmpty) _toggleInSelection(pageIndex, stroke: hit); // Shift: with the others, or out of them
                      } else {
                        _clearSelection();
                        if (hit.points.isNotEmpty) _selection = [hit];
                        _selectedStrokePage = pageIndex;
                      }
                    } else if (stroke != null && _activeDrawTool != null) {
                      // a drag with the tool of an extension: the line is only the preview of what the extension draws
                      _clearSelection();
                      _strokesPerPage[pageIndex]?.remove(stroke);
                      final tool = _activeDrawTool!;
                      final start = _shapeStart, end = event.localPosition;
                      if (_shape == ShapeTool.freehand) stroke.simplify(_inkTolerance);
                      unawaited(_runDrawTool(tool, pageIndex, _shape == ShapeTool.freehand ? stroke.points : [start, end], _shape == ShapeTool.freehand ? stroke.pressures : null, Size(_paperWidth, pageHeight)));
                    } else if (stroke != null) {
                      _clearSelection(); // writing something new
                      final pr = stroke.pressures;
                      if (pr != null) {
                        // a pen that always says the same has no pressure to show
                        final lo = pr.reduce(math.min), hi = pr.reduce(math.max);
                        if (hi - lo < 12 || pr.length != stroke.points.length) stroke.pressures = null;
                      }
                      if (_shape == ShapeTool.freehand) stroke.simplify(_inkTolerance);
                      if (_shape == ShapeTool.connector) _finishConnector(pageIndex, stroke, event.localPosition);
                      if (_straighten && _shape == ShapeTool.freehand) {
                        final line = straightLine(stroke.points);
                        final shape = line == null ? snapToShape(stroke.points) : null; // (a drawing very close to a rectangle, ellipse, ...)
                        final made = line ?? shape?.points;
                        if (made != null) {
                          stroke.points
                            ..clear()
                            ..addAll(made);
                          stroke.pressures = null;
                        }
                      }
                      if (copies.isNotEmpty) {
                        _remakeSymmetry(stroke, copies,); // (as the line came out: simpler, perhaps straight)
                        _strokesPerPage.putIfAbsent(pageIndex, () => []).addAll(copies);
                      }
                      final made = [stroke, ...copies];
                      _undoStack.push(UndoStep(
                        () => _strokesPerPage[pageIndex]?.removeWhere(made.contains),
                        () => _strokesPerPage.putIfAbsent(pageIndex, () => []).addAll(made),
                      ));
                    }
                    _draggingStroke = false;
                  });
                  if (moved) _scheduleSave();
                },
                onPointerCancel: (_) {
                  _commitErase();
                  _penGrab = null;
                  final cut = _currentActiveStroke; // what was being drawn stays, and can be taken back
                  final cutCopies = _symmetryCopies;
                  _symmetryCopies = [];
                  _stabiliser = null;
                  _snapper = null;
                  if (cut != null) {
                    if (cutCopies.isNotEmpty) _strokesPerPage.putIfAbsent(pageIndex, () => []).addAll(cutCopies);
                    final made = [cut, ...cutCopies];
                    _undoStack.push(UndoStep(
                      () => _strokesPerPage[pageIndex]?.removeWhere(made.contains),
                      () => _strokesPerPage.putIfAbsent(pageIndex, () => []).addAll(made),
                    ));
                  }
                  _currentActiveStroke = null;
                  _lassoPath = null;
                  _draggingStroke = false;
                  _stylusDown = false;
                  if (_penDown) setState(() => _penDown = false);
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTapDown: (details) {
                    // a mouse needs three clicks (see _tripleClick)
                    if (details.kind == PointerDeviceKind.mouse) return;
                    // writing with a pen is full of quick taps (dots, lifts between letters),
                    // and a resting palm taps too: with a pen they use the long press below
                    if (_penDown || _fingersScroll) return;
                    _addTextBoxAt(pageIndex, details.localPosition);
                  },
                  onLongPressStart: (details) {
                    if (_stylusDown) {
                      _addTextBoxAt(pageIndex, details.localPosition);
                    }
                  },
                  onTap: () => setState(() {
                    if (!_justGrewBox && !_boxJustMade) _activeSelectedBox = null; // (the tap that grew a box from a side is not one on the page)
                  }),
                  child: Container(
                    width: _paperWidth,
                    height: pageHeight,
                    color: Colors.transparent,
                  ),
                ),
              ),

            // the handle that moves the centre of the symmetry: above the pen's layer, which would take its touches
            if (_mode == CanvasInteractionMode.draw && _on(Feature.symmetry) && !_symmetry.isOff && _currentActiveStroke == null) _symmetryHandle(pageHeight),
            ..._guideHandles(pageIndex, pageHeight),

            // the sides of the items a connector can be fixed to
            if (_connecting || _selectedConnectorOn(pageIndex) != null)
              IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _ConnectorHandles(_connectItems(pageIndex), () => _connectOver?.id, Theme.of(context).colorScheme.primary, repaint: _inkTick, ends: () => _connecting ? null : _selectedConnectorOn(pageIndex)),
                    size: Size(_paperWidth, pageHeight),
                  ),
                ),
              ),

            // where the pen hovers: a ring the size of the line
            ValueListenableBuilder<({int page, Offset at, double radius, bool erasing})?>(
              valueListenable: _hover,
              builder: (context, h, _) => h == null || h.page != pageIndex || _mode != CanvasInteractionMode.draw
                  ? const SizedBox.shrink()
                  : IgnorePointer(
                      child: CustomPaint(
                        painter: _HoverRing(h.at, h.radius, h.erasing ? Colors.grey.shade700 : _selectedPenColor),
                        size: Size(_paperWidth, pageHeight),
                      ),
                    ),
            ),

            _selectionOverlay(pageIndex),

            // Z-INDEX 5: Floating Text Boxes
            ...pageBoxes.where((box) => !_inGutter(box) && _boxUsual(stacking, box)).map((box) => _buildFloatingTextBox(box)),

            // what lies over those by its layer
            if (stacking != null) ..._stackedAbove(stacking, pageIndex),

            ..._connectorEndHandles(pageIndex), // (above the boxes: the ends lie on their edges)

            if (_penPath != null) _penToolBar(pageIndex, pageHeight),

            // what the maths check found, beside the lines
            ..._markWidgets(pageIndex),

            // the words of the handwriting that are not spelled right
            ..._spellWidgets(pageIndex),
          ],
        ),
      )),
        ],
      ),
    );
    if (!split) return tile;
    return SizedBox(
      width: _paperWidth,
      height: pageHeight,
      child: Stack(clipBehavior: Clip.none, children: [..._documentSheetWidgets(), tile]),
    );
  }

  /// The sheets of a written document that is longer than a page: paper with its ruling, and the part of the text that is on it. All of
  /// the text is laid out once, unseen, which is what is measured; each sheet near the screen shows the pieces of it that are on that
  /// sheet (a whole copy of the text on every sheet took seconds to open with a long document).
  List<Widget> _documentSheetWidgets() {
    final width = _paperWidth - _marginLeft - _marginRight;
    final room = basePageHeight - _marginTop - _marginBottom;
    final edges = [0.0, ..._docBreaks];
    _measureDocument();
    return [
      Positioned(
        left: _marginLeft,
        top: _marginTop,
        width: width,
        child: Offstage(
          child: LiveMarkdownView(key: _documentMeasureKey, controller: _documentController, fontSize: DocumentSheet.fontSize, inTurn: _readPieces, actions: LiveMarkdownActions(onHeading: _readHeading)),
        ),
      ),
      for (var k = 0; k < edges.length; k++)
        Positioned(
          key: ValueKey('document-sheet-$k'),
          left: 0,
          top: k * (basePageHeight + _FixedPageNoteEditorState._sheetGap),
          width: _paperWidth,
          height: basePageHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            child: ClipRect(
              child: Stack(children: [
                Positioned.fill(child: CustomPaint(painter: PageBackgroundPainter(_background))),
                Positioned(
                  left: _marginLeft,
                  top: _marginTop,
                  width: width,
                  height: k + 1 < edges.length ? edges[k + 1] - edges[k] : room,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: ListenableBuilder(
                        listenable: _readSheets,
                        builder: (_, _) {
                          final pieces = _readPieces.shown;
                          final tops = _docPieceTops;
                          final (near, nearEnd) = _sheetsNear.value;
                          if (k < near || k > nearEnd || tops.isEmpty) return const SizedBox.shrink();
                          final here = piecesBetween(tops, edges[k], k + 1 < edges.length ? edges[k + 1] : double.infinity);
                          final end = math.min(here.end, pieces.length);
                          if (here.first >= end) return const SizedBox.shrink();
                          return Transform.translate(
                            offset: Offset(0, here.top - edges[k]),
                            child: LiveMarkdownView(
                              controller: _documentController,
                              fontSize: DocumentSheet.fontSize,
                              pieces: pieces.sublist(here.first, end),
                              first: here.first,
                              ended: _readPieces.whole && end == pieces.length,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
    ];
  }
}
