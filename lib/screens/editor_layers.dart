part of 'fixed_page_note_editor.dart';

/// Drawing on layers: the panel, and what the pen does when the layer it draws on cannot be drawn on.
extension _EditorLayers on _FixedPageNoteEditorState {
  /// The layer new lines go on: the one chosen, or the base layer if that one is gone.
  NoteLayer get _drawingLayer => _layers.byId(_activeLayer);

  /// The layer something placed by the app (a picture, a plot, a diagram) goes on: the one being drawn on, or the base layer if that
  /// one is hidden or locked (it would be out of reach at once).
  String get _placeLayer => _drawingLayer.editable ? _drawingLayer.id : baseLayerId;

  /// Whether the text box or the picture can be worked on: its layer is shown and not locked.
  bool _boxEditable(TextBoxWidgetModel b) => _layers.byId(b.layer).editable;
  bool _imageEditable(ImageItem m) => _layers.byId(m.layer).editable;

  /// How the pictures, lines and boxes of the page lie over each other, if the layers need that done (a picture of a higher layer over
  /// the lines of a lower one, or the other way round); null if the usual order - pictures, lines, boxes - is the right one.
  PageStacking? _stackingOf(int pageIndex) {
    if (_layers.isPlain) return null;
    final stacking = PageStacking(
      _layers,
      pictures: {for (final m in _imagesPerPage[pageIndex] ?? const <ImageItem>[]) _layers.indexOf(m.layer)},
      ink: {for (final s in _strokesPerPage[pageIndex] ?? const <DrawingStroke>[]) _layers.indexOf(s.layer)},
      boxes: {for (final b in _textBoxesPerPage[pageIndex] ?? const <TextBoxWidgetModel>[]) if (!_inGutter(b)) _layers.indexOf(b.layer)},
    );
    return stacking.isUsual ? null : stacking;
  }

  /// Whether the picture / the box is where a page puts it without any ordering.
  bool _imageUsual(PageStacking? s, ImageItem m) => s == null || s.isUsualFor(StackKind.picture, _layers.indexOf(m.layer));
  bool _boxUsual(PageStacking? s, TextBoxWidgetModel b) => s == null || s.isUsualFor(StackKind.box, _layers.indexOf(b.layer));

  /// The lines of the usual place: those of the layers that are not put in order one by one (all, with no ordering).
  Set<int>? _usualInk(PageStacking? s) => s?.usualLayers(StackKind.ink);

  /// Whether the line being drawn is drawn over the lines of the usual place (else among the ordered parts, over its own layer).
  bool _activeInUsualPlace(PageStacking? s) => s == null || _currentActiveStroke == null || s.isUsualFor(StackKind.ink, _layers.indexOf(_currentActiveStroke!.layer));

  /// What the page shows over everything in its usual places: the parts of [stacking] that are over others, one after the other -
  /// each layer's pictures, lines (the line being drawn among them) and boxes. They take no touches (the pen and the fingers go to
  /// what is under them, the boxes excepted).
  List<Widget> _stackedAbove(PageStacking stacking, int pageIndex) {
    final strokes = _strokesPerPage[pageIndex] ?? const <DrawingStroke>[];
    final active = _currentActiveStroke != null && strokes.isNotEmpty && identical(strokes.last, _currentActiveStroke) ? _currentActiveStroke : null;
    final sensitivity = widget.stylus?.effectiveSensitivity ?? 0.6;
    return [
      for (final part in stacking.above) ...switch (part.kind) {
        StackKind.picture => [
            for (final m in _imagesPerPage[pageIndex] ?? const <ImageItem>[])
              if (_layers.indexOf(m.layer) == part.layer) _imageWidget(pageIndex, m),
          ],
        StackKind.ink => [
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: InkLayerPainter(strokes: strokes, skip: active ?? _penEditing, layers: _layers, pressureSensitivity: sensitivity, only: {part.layer}, pixelScale: _inkPixelScale),
                    isComplex: true,
                  ),
                ),
              ),
            ),
            if (active != null && _layers.indexOf(active.layer) == part.layer)
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: ActiveInkPainter(() => _currentActiveStroke, repaint: _inkTick, pressureSensitivity: sensitivity, alongside: () => _symmetryCopies),
                    ),
                  ),
                ),
              ),
          ],
        StackKind.box => [
            for (final b in _textBoxesPerPage[pageIndex] ?? const <TextBoxWidgetModel>[])
              if (!_inGutter(b) && _layers.indexOf(b.layer) == part.layer) _buildFloatingTextBox(b),
          ],
      },
    ];
  }

  /// The layer of the pictures to trace.
  static const referenceLayerId = 'reference';

  /// Puts the picture on a layer of its own at the very bottom - faded, and locked so that it stays where it is and the pen draws
  /// over it - to draw over (the layer is made once; later reference pictures join it). It is one step to take back, as a change of the
  /// layers. The layers' panel unlocks it, or moves a picture off it.
  void _useAsReference(ImageItem item) {
    setState(() {
      if (!_layers.layers.any((l) => l.id == referenceLayerId)) {
        _layers = LayerStack([NoteLayer(referenceLayerId, 'Reference', locked: true, opacity: 0.4), ..._layers.layers]);
      }
      item.layer = referenceLayerId;
      _selectedImage = null;
      _dropClosedFromSelection();
    });
  }

  /// Lets go of what is selected on a layer that was hidden or locked just now.
  void _dropClosedFromSelection() {
    _selection.removeWhere((s) => !_layers.editable(s));
    _groupBoxes.removeWhere((b) => !_boxEditable(b));
    _groupImages.removeWhere((m) => !_imageEditable(m));
    if (_activeSelectedBox != null && !_boxEditable(_activeSelectedBox!)) {
      _activeSelectedBox!.focusNode.unfocus();
      _activeSelectedBox = null;
    }
    if (_selectedImage != null && !_imageEditable(_selectedImage!)) _selectedImage = null;
  }

  /// The layers beside the note on a wide screen (the button opens and shuts them), else in a dialog.
  Future<void> _openLayers({bool toggle = false}) async {
    if (_roomForSidePanel) {
      if (toggle || !_layersOpen) _toggleSidePanel(_layersOpen, () => _layersOpen = true);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => LayersDialog(layers: _layers, active: _drawingLayer.id, selectedCount: _selectedCount, onChanged: _setLayers, onMoveSelection: _moveSelectionToLayer),
    );
  }

  /// How many drawings, boxes and pictures are selected.
  int get _selectedCount => _selection.length + _groupBoxes.length + _groupImages.length + (_activeSelectedBox != null ? 1 : 0) + (_selectedImage != null ? 1 : 0);

  void _setLayers(LayerStack layers, String active) => setState(() {
        _layers = layers;
        _activeLayer = active;
        _dropClosedFromSelection();
      });

  Widget _layersPanel({required VoidCallback onClose}) => LayersPanel(
        key: const ValueKey('layers-panel'),
        layers: _layers,
        active: _drawingLayer.id,
        selectedCount: _selectedCount,
        onChanged: _setLayers,
        onMoveSelection: _moveSelectionToLayer,
        onClose: onClose,
      );

  /// Puts what is selected (drawings, text boxes, pictures) on the layer [id], as one step to take back.
  void _moveSelectionToLayer(String id) {
    bool elsewhere(String layer) => _layers.byId(layer).id != id;
    final boxes = {..._groupBoxes, ?_activeSelectedBox};
    final images = {..._groupImages, ?_selectedImage};
    final moved = <({String from, void Function(String) set})>[
      for (final s in _selection)
        if (elsewhere(s.layer)) (from: s.layer, set: (v) => s.layer = v),
      for (final b in boxes)
        if (elsewhere(b.layer)) (from: b.layer, set: (v) => b.layer = v),
      for (final m in images)
        if (elsewhere(m.layer)) (from: m.layer, set: (v) => m.layer = v),
    ];
    if (moved.isEmpty) return;
    setState(() {
      for (final m in moved) {
        m.set(id);
      }
    });
    _absorbMeta(); // (the boxes and pictures are part of this step, not another one a moment later)
    _undoStack.push(UndoStep(
      () {
        for (final m in moved) {
          m.set(m.from);
        }
      },
      () {
        for (final m in moved) {
          m.set(id);
        }
      },
    ));
    _scheduleSave();
  }

  /// Says why the pen drew nothing: the layer is hidden or locked.
  void _layerBlocked() {
    final layer = _drawingLayer;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(
        key: const ValueKey('layer-blocked'),
        content: Text(tr(layer.visible ? 'The layer "{layer}" is locked: unlock it, or choose another layer, to draw.' : 'The layer "{layer}" is hidden: show it, or choose another layer, to draw.', {'layer': tr(layer.name)})),
        action: SnackBarAction(label: tr('Layers'), onPressed: _openLayers),
      ));
  }

  Widget _layersButton() {
    final scheme = Theme.of(context).colorScheme;
    final on = !_layers.isPlain || _layersOpen;
    return IconButton(
      key: const ValueKey('layers-button'),
      tooltip: tr('Layers: {layer}', {'layer': tr(_drawingLayer.name)}),
      style: on ? IconButton.styleFrom(backgroundColor: scheme.secondaryContainer, foregroundColor: scheme.onSecondaryContainer) : null,
      icon: const Icon(Icons.layers_outlined, size: 20),
      onPressed: () => _openLayers(toggle: true),
    );
  }
}
