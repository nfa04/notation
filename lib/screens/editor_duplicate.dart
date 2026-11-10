part of 'fixed_page_note_editor.dart';

/// Making a copy of what is selected: drawings, text boxes and pictures. The copy lands a little down and to the
/// side of the original (the other way if there is no room), is selected, so that it can be dragged away at once,
/// and is one step to take back.
extension _EditorDuplicate on _FixedPageNoteEditorState {
  /// How far a copy is from the original.
  static const _copyShift = 24.0;

  /// Where a copy of something that takes [bounds] on [page] goes, as a shift: down and right, or up and left
  /// where that would be off the page.
  Offset _shiftFor(int page, Rect bounds) {
    final dx = bounds.right + _copyShift <= _paperWidth ? _copyShift : (bounds.left - _copyShift >= 0 ? -_copyShift : 0.0);
    final dy = bounds.bottom + _copyShift <= _heightOf(page) ? _copyShift : (bounds.top - _copyShift >= 0 ? -_copyShift : 0.0);
    return Offset(dx, dy);
  }

  /// A copy of [m] with a file of its own (so that nothing that happens to the one touches the other).
  ImageItem _copyOfImage(ImageItem m, Offset shift) {
    final id = NoteRepository.newId();
    var path = m.path;
    try {
      final dot = m.path.lastIndexOf('.');
      final copy = '${dot < 0 ? m.path : m.path.substring(0, dot)}-copy-$id${dot < 0 ? '' : m.path.substring(dot)}';
      File(m.path).copySync(copy);
      path = copy;
    } on FileSystemException {
      // the file is gone (the picture shows as broken): the copy is as broken
    }
    return ImageItem(id: id, path: path, position: m.position + shift, size: m.size, author: Authorship.current, layer: m.layer);
  }

  TextBoxWidgetModel _copyOfBox(TextBoxWidgetModel b, Offset shift) {
    final copy = TextBoxWidgetModel(
      id: newElementId(),
      position: b.position + shift,
      size: b.size,
      initialText: b.controller.text,
      fontSize: b.fontSize,
      style: b.style,
      author: Authorship.current,
      layer: b.layer,
    );
    copy.controller.attributes.addAll([for (final a in b.controller.attributes) a.copy()]);
    _attachBox(copy);
    return copy;
  }

  /// Puts copies of [strokes], [boxes] and [images] (all on [page]) on the page, and makes them the selection.
  /// Returns what was made.
  ({List<DrawingStroke> strokes, List<TextBoxWidgetModel> boxes, List<ImageItem> images}) _duplicate(
    int page, {
    List<DrawingStroke> strokes = const [],
    List<TextBoxWidgetModel> boxes = const [],
    List<ImageItem> images = const [],
  }) {
    Rect? bounds;
    void add(Rect r) => bounds = bounds == null ? r : bounds!.expandToInclude(r);
    for (final s in strokes) {
      if (s.points.isNotEmpty) add(_boundsOf(s));
    }
    for (final b in boxes) {
      add(_boxRect(b));
    }
    for (final m in images) {
      add(m.position & m.size);
    }
    final shift = bounds == null ? const Offset(_copyShift, _copyShift) : _shiftFor(page, bounds!);

    final newStrokes = [
      for (final s in strokes)
        s.copyAt(shift, author: Authorship.current),
    ];
    final newBoxes = [for (final b in boxes) _copyOfBox(b, shift)];
    final newImages = [for (final m in images) _copyOfImage(m, shift)];
    // a group that is copied whole is a new group of the copies (one member alone is in none)
    final members = <String, int>{
      for (final g in [...strokes.map((s) => s.group), ...boxes.map((b) => b.group), ...images.map((m) => m.group)])
        if (g != noGroup) g: 0,
    };
    for (final g in [...strokes.map((s) => s.group), ...boxes.map((b) => b.group), ...images.map((m) => m.group)]) {
      if (g != noGroup) members[g] = members[g]! + 1;
    }
    final fresh = {for (final e in members.entries) if (e.value > 1) e.key: newElementId()};
    for (var i = 0; i < strokes.length; i++) {
      newStrokes[i].group = fresh[strokes[i].group] ?? noGroup;
    }
    for (var i = 0; i < boxes.length; i++) {
      newBoxes[i].group = fresh[boxes[i].group] ?? noGroup;
    }
    for (var i = 0; i < images.length; i++) {
      newImages[i].group = fresh[images[i].group] ?? noGroup;
    }
    _strokesPerPage.putIfAbsent(page, () => []).addAll(newStrokes);
    _textBoxesPerPage.putIfAbsent(page, () => []).addAll(newBoxes);
    _imagesPerPage.putIfAbsent(page, () => []).addAll(newImages);

    // one step to take back (and to do again)
    _undoStack.push(UndoStep(
      () {
        for (final s in newStrokes) {
          _strokesPerPage[page]?.remove(s);
        }
        for (final b in newBoxes) {
          _textBoxesPerPage[page]?.remove(b);
        }
        for (final m in newImages) {
          _imagesPerPage[page]?.remove(m);
        }
      },
      () {
        _strokesPerPage.putIfAbsent(page, () => []).addAll(newStrokes);
        _textBoxesPerPage.putIfAbsent(page, () => []).addAll(newBoxes);
        _imagesPerPage.putIfAbsent(page, () => []).addAll(newImages);
      },
    ));
    _scheduleSave();
    return (strokes: newStrokes, boxes: newBoxes, images: newImages);
  }

  /// Copies what the lasso (or a tap) selected; the copies are selected afterwards.
  void _duplicateSelection() {
    if (!_hasSelection) return;
    final page = _selectedStrokePage;
    setState(() {
      final made = _duplicate(page, strokes: List.of(_selection), boxes: List.of(_groupBoxes), images: List.of(_groupImages));
      _selection = made.strokes;
      _groupBoxes = made.boxes;
      _groupImages = made.images;
      _activeSelectedBox = null;
      _selectedImage = null;
    });
  }

  /// Copies the selected picture; the copy is the selected one.
  void _duplicateImage(int page, ImageItem item) {
    setState(() {
      final made = _duplicate(page, images: [item]);
      _selectedImage = made.images.single;
    });
  }

  /// Copies a text box; the copy is the selected one.
  void _duplicateTextBox(TextBoxWidgetModel box) {
    final page = _pageOfBox(box);
    if (page == null) return;
    setState(() {
      final made = _duplicate(page, boxes: [box]);
      _activeSelectedBox = made.boxes.single;
    });
  }
}
