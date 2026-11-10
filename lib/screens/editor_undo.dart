part of 'fixed_page_note_editor.dart';

/// A text box as it was: the box itself (kept, so that older steps still find it) and what can change in it.
class _BoxCopy {
  final TextBoxWidgetModel box;
  final Offset position;
  final Size size;
  final String text;
  final List<TextSpanAttribute> spans;
  final double fontSize;
  final TextBoxStyle style;
  final String layer;
  _BoxCopy(this.box)
      : layer = box.layer,
        position = box.position,
        size = box.size,
        text = box.controller.text,
        spans = [for (final a in box.controller.attributes) a.copy()],
        fontSize = box.fontSize,
        style = box.style;

  void restore() {
    box.layer = layer;
    box.position = position;
    box.size = size;
    if (box.controller.text != text) box.controller.text = text;
    box.controller.attributes
      ..clear()
      ..addAll(spans);
    box.fontSize = fontSize;
    box.style = style;
  }
}

class _ImageCopy {
  final ImageItem image;
  final Offset position;
  final Size size;
  final String layer;
  _ImageCopy(this.image)
      : layer = image.layer,
        position = image.position,
        size = image.size;

  void restore() {
    image.layer = layer;
    image.position = position;
    image.size = size;
  }
}

/// Everything about a note that is not a pen stroke (those are taken back one by one): the title, the look of the pages, the
/// written document, the text boxes, the pictures and the highlights. Two of them are the same note when [fingerprint] is.
class _Meta {
  final String title;
  final PageBackground background;
  final LayerStack layers;
  final PageFormat format;
  final bool landscape;
  final double marginLeft, marginRight, marginTop, marginBottom;
  final String? themeImage;
  final String documentText;
  final List<TextSpanAttribute> documentSpans;
  final Map<int, List<_BoxCopy>> boxes;
  final Map<int, List<_ImageCopy>> images;
  final Map<int, List<PdfHighlight>> highlights;
  final int fingerprint;

  _Meta._(this.title, this.background, this.layers, this.format, this.landscape, this.marginLeft, this.marginRight, this.marginTop, this.marginBottom, this.themeImage, this.documentText, this.documentSpans,
      this.boxes, this.images, this.highlights)
      : fingerprint = Object.hashAll([
          title,
          background,
          layers.fingerprint,
          format,
          landscape,
          marginLeft,
          marginRight,
          marginTop,
          marginBottom,
          themeImage,
          documentText,
          ...documentSpans.map((a) => a.fingerprint),
          for (final e in boxes.entries)
            for (final b in e.value) Object.hash(e.key, b.box.id, b.position, b.size, b.fontSize, b.style, b.text, Object.hashAll(b.spans.map((a) => a.fingerprint)), b.layer),
          for (final e in images.entries)
            for (final m in e.value) Object.hash(e.key, m.image.id, m.position, m.size, m.layer),
          for (final e in highlights.entries)
            for (final h in e.value) Object.hash(e.key, h.id),
        ]);
}

/// Taking back and redoing drawing, erasing and moving, and every other change to the note.
extension _EditorUndo on _FixedPageNoteEditorState {
  /// Puts [removed] (taken out of their pages) back where they were.
  void _putBack(List<({int page, int index, DrawingStroke stroke})> removed) {
    final ordered = [...removed]..sort((a, b) => a.index.compareTo(b.index));
    for (final r in ordered) {
      final list = _strokesPerPage.putIfAbsent(r.page, () => []);
      list.insert(r.index.clamp(0, list.length), r.stroke);
    }
  }

  /// A step that took [removed] (and [boxes] and [images]) away: undone by putting them back.
  void _pushRemoval(
    List<({int page, int index, DrawingStroke stroke})> removed, {
    List<({int page, int index, TextBoxWidgetModel box})> boxes = const [],
    List<({int page, int index, ImageItem image})> images = const [],
  }) {
    if (removed.isEmpty && boxes.isEmpty && images.isEmpty) return;
    final copy = List.of(removed), boxCopy = List.of(boxes), imageCopy = List.of(images);
    _undoStack.push(UndoStep(
      () {
        _putBack(copy);
        for (final r in boxCopy..sort((a, b) => a.index.compareTo(b.index))) {
          final list = _textBoxesPerPage.putIfAbsent(r.page, () => []);
          list.insert(r.index.clamp(0, list.length), r.box);
        }
        for (final r in imageCopy..sort((a, b) => a.index.compareTo(b.index))) {
          final list = _imagesPerPage.putIfAbsent(r.page, () => []);
          list.insert(r.index.clamp(0, list.length), r.image);
        }
      },
      () {
        for (final r in copy) {
          _strokesPerPage[r.page]?.remove(r.stroke);
        }
        for (final r in boxCopy) {
          _textBoxesPerPage[r.page]?.remove(r.box);
        }
        for (final r in imageCopy) {
          _imagesPerPage[r.page]?.remove(r.image);
        }
      },
    ));
  }

  void _commitErase() {
    if (_erased.isEmpty) return;
    _pushRemoval(List.of(_erased));
    _erased.clear();
  }

  void _commitStrokeMove() {
    final start = _strokeDragStart;
    _strokeDragStart = null;
    if (start == null) return;
    final end = [for (final st in start.strokes) List.of(st.points)];
    final boxEnd = [for (final b in start.boxes) b.position];
    final imageEnd = [for (final m in start.images) m.position];
    final endPage = _selectedStrokePage;
    var changed = endPage != start.page;
    for (var i = 0; i < end.length && !changed; i++) {
      changed = end[i].length != start.points[i].length ||
          [for (var k = 0; k < end[i].length; k++) end[i][k] != start.points[i][k]].contains(true);
    }
    for (var i = 0; i < boxEnd.length && !changed; i++) {
      changed = boxEnd[i] != start.boxAt[i];
    }
    for (var i = 0; i < imageEnd.length && !changed; i++) {
      changed = imageEnd[i] != start.imageAt[i];
    }
    if (!changed) return;
    void place(List<List<Offset>> points, List<Offset> boxAt, List<Offset> imageAt, int from, int to) {
      for (var i = 0; i < start.strokes.length; i++) {
        start.strokes[i].points
          ..clear()
          ..addAll(points[i]);
      }
      for (var i = 0; i < start.boxes.length; i++) {
        start.boxes[i].position = boxAt[i];
      }
      for (var i = 0; i < start.images.length; i++) {
        start.images[i].position = imageAt[i];
      }
      if (from != to) {
        _strokesPerPage[from]?.removeWhere(start.strokes.contains);
        _strokesPerPage.putIfAbsent(to, () => []).addAll(start.strokes);
        _textBoxesPerPage[from]?.removeWhere(start.boxes.contains);
        _textBoxesPerPage.putIfAbsent(to, () => []).addAll(start.boxes);
        _imagesPerPage[from]?.removeWhere(start.images.contains);
        _imagesPerPage.putIfAbsent(to, () => []).addAll(start.images);
      }
    }

    _undoStack.push(UndoStep(
      () => place(start.points, start.boxAt, start.imageAt, endPage, start.page),
      () => place(end, boxEnd, imageEnd, start.page, endPage),
    ));
  }

  /// Wipes the drawings and highlights of the page on screen; one step to take back.
  void _clearPage() {
    final page = _visiblePage().$1;
    final strokes = List.of(_strokesPerPage[page] ?? const <DrawingStroke>[]);
    final highlights = List.of(_highlightsPerPage[page] ?? const <PdfHighlight>[]);
    if (strokes.isEmpty && highlights.isEmpty) return;
    setState(() {
      _strokesPerPage[page]?.clear();
      _highlightsPerPage[page]?.clear();
      _clearSelection();
      _undoStack.push(UndoStep(
        () {
          _strokesPerPage.putIfAbsent(page, () => []).addAll(strokes);
          _highlightsPerPage.putIfAbsent(page, () => []).addAll(highlights);
        },
        () {
          _strokesPerPage[page]?.clear();
          _highlightsPerPage[page]?.clear();
        },
      ));
    });
    _scheduleSave();
  }

  void _undoDrawing() {
    if (_currentActiveStroke != null) return; // the pen is on the page
    _flushMeta();
    setState(() {
      _clearSelection();
      _undoStack.undo();
      _metaBase = _captureMeta();
    });
    _scheduleSave();
  }

  void _redoDrawing() {
    if (_currentActiveStroke != null) return;
    _flushMeta();
    setState(() {
      _clearSelection();
      _undoStack.redo();
      _metaBase = _captureMeta();
    });
    _scheduleSave();
  }

  // ---- everything that is not a stroke: noticed a moment after it happened, and taken back as a whole

  _Meta _captureMeta() => _Meta._(
        _titleController.text,
        _background,
        _layers,
        _pageFormat,
        _landscape,
        _marginLeft,
        _marginRight,
        _marginTop,
        _marginBottom,
        _themeImage,
        _documentController.text,
        [for (final a in _documentController.attributes) a.copy()],
        {for (final e in _textBoxesPerPage.entries) e.key: [for (final b in e.value) _BoxCopy(b)]},
        {for (final e in _imagesPerPage.entries) e.key: [for (final m in e.value) _ImageCopy(m)]},
        {for (final e in _highlightsPerPage.entries) e.key: List.of(e.value)},
      );

  void _applyMeta(_Meta m) {
    _titleController.text = m.title;
    _background = m.background;
    _layers = m.layers;
    _pageFormat = m.format;
    _landscape = m.landscape;
    _marginLeft = m.marginLeft;
    _marginRight = m.marginRight;
    _marginTop = m.marginTop;
    _marginBottom = m.marginBottom;
    _themeImage = m.themeImage;
    if (_documentController.text != m.documentText) _documentController.text = m.documentText;
    _documentController.attributes
      ..clear()
      ..addAll(m.documentSpans);
    _textBoxesPerPage
      ..clear()
      ..addAll({
        for (final e in m.boxes.entries)
          e.key: [
            for (final c in e.value)
              () {
                c.restore();
                return c.box;
              }(),
          ],
      });
    _imagesPerPage
      ..clear()
      ..addAll({
        for (final e in m.images.entries)
          e.key: [
            for (final c in e.value)
              () {
                c.restore();
                return c.image;
              }(),
          ],
      });
    _highlightsPerPage
      ..clear()
      ..addAll({for (final e in m.highlights.entries) e.key: List.of(e.value)});
    final present = {for (final l in _textBoxesPerPage.values) for (final b in l) b};
    if (_activeSelectedBox != null && !present.contains(_activeSelectedBox)) _activeSelectedBox = null;
    final images = {for (final l in _imagesPerPage.values) for (final i in l) i};
    if (_selectedImage != null && !images.contains(_selectedImage)) _selectedImage = null;
  }

  /// Notes that something may have changed; a moment after the last change it is looked at ([_recordMeta]).
  void _metaSoon() {
    if (_metaBase == null) return;
    _metaTimer?.cancel();
    _metaTimer = Timer(const Duration(milliseconds: 600), _recordMeta);
  }

  /// Looks at the note now: if something other than strokes changed since the last step, that is a step.
  void _flushMeta() {
    if (_metaTimer?.isActive ?? false) {
      _metaTimer!.cancel();
      _recordMeta();
    }
  }

  void _recordMeta() {
    final before = _metaBase;
    if (!mounted || !_loaded || before == null) return;
    // not in the middle of drawing or of dragging something: the step is the whole movement
    if (_currentActiveStroke != null || _strokeDragStart != null || _drag != null) {
      _metaTimer = Timer(const Duration(milliseconds: 300), _recordMeta);
      return;
    }
    final after = _captureMeta();
    if (after.fingerprint == before.fingerprint) return;
    _recordingMeta = true;
    _undoStack.push(UndoStep(
      () => _applyMeta(before),
      () => _applyMeta(after),
    ));
    _recordingMeta = false;
    _metaBase = after;
    _undoTick.value++; // (the undo button; not a setState, which would put the saving off)
  }

  /// A step of the drawing was made, or the others changed the note: what is different now belongs to it, not to a step of its own.
  void _absorbMeta() {
    if (_recordingMeta || !_loaded) return;
    _metaBase = _captureMeta();
  }

  void _eraseAt(int pageIndex, Offset position) {
    final strokes = _strokesPerPage[pageIndex];
    if (strokes == null ||
        !strokes.any((s) => _layers.editable(s) && s.isNear(position, _eraserRadius))) {
      return;
    }
    setState(() {
      for (var i = strokes.length - 1; i >= 0; i--) {
        if (_layers.editable(strokes[i]) && strokes[i].isNear(position, _eraserRadius)) {
          _erased.add((page: pageIndex, index: i, stroke: strokes[i]));
          strokes.removeAt(i);
        }
      }
    });
  }
}
