part of 'fixed_page_note_editor.dart';

/// Mind maps and flowcharts: a text becomes boxes (text boxes) and lines (strokes) on the page in view, as one step to take back.
extension _EditorDiagram on _FixedPageNoteEditorState {
  /// The prompt that asks the assistant for an outline of [text], which [parseOutline] reads.
  static AiPrompt _outlinePrompt(String text) => AiPrompt(
        system: 'You turn a document into an outline for a mind map. Answer with a nested bullet list only: "- " for each entry, two '
            'spaces of indentation for each level, at most three levels, at most seven entries at the top level and a few words '
            'for each entry. The first entry is the subject of the document. Write in the language of the document. No introduction.',
        user: text,
      );

  Future<void> _insertDiagram() async {
    final ai = widget.ai;
    final title = _titleController.text.trim();
    final selected = _currentSelectedText?.trim() ?? '';
    final request = await askDiagram(
      context,
      initial: selected.contains('\n') || selected.contains('->') ? selected : '',
      rootTitle: title,
      draft: ai == null || ai.provider?.state != ProviderState.ready
          ? null
          : () async {
              final index = await _documentIndex();
              var all = index.chunks.map((c) => c.text).join('\n').trim();
              if (all.length > ai.contextChars) all = all.substring(0, ai.contextChars);
              if (all.isEmpty) throw StateError(tr('There is nothing in the note to make an outline of yet.'));
              return ai.generate(_outlinePrompt(all), maxTokens: 500);
            },
    );
    if (request == null || !mounted) return;
    final DiagramLayout made;
    if (request.mode == DiagramMode.simple) {
      final diagram = parseDiagram(request.text, rootTitle: title);
      if (diagram.isEmpty) return;
      made = layoutDiagram(diagram);
    } else {
      // (a state diagram, a tree or a graph)
      final advanced = buildAdvanced(request.mode, request.text, options: request.options);
      if (advanced.isEmpty) return;
      made = advanced.layout;
    }
    _placeDiagram(made);
  }

  /// Reads the circles and lines of the selected drawing as a state diagram, a tree or a graph, shows what was made of it in the diagram
  /// dialog (the names are the handwriting model's reading, which can be put right there) and, when it is accepted, puts the clean diagram in
  /// place of the drawing, as one step to take back.
  Future<void> _diagramFromDrawing() async {
    final drawn = List.of(_selection);
    final page = _selectedStrokePage;
    if (drawn.length < 3) return;
    final messenger = ScaffoldMessenger.of(context);
    // (the formula reader: it reads a letter, a digit or a short name far better than the text reader, which takes everything for words)
    final reader = widget.math;
    final canRead = reader != null && reader.status == HandwritingStatus.installed;
    final reading = await readInkDiagram(drawn, (strokes) {
      if (!canRead) throw StateError('no formula model');
      return reader.recognize(strokes);
    });
    if (!mounted) return;
    if (reading.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('No circles joined by lines were found in the selection.'))));
      return;
    }
    final notes = [
      tr('Read from your drawing: {nodes} circles, {edges} lines. Check the names, then put it on the page; your drawing is replaced.', {'nodes': reading.nodes, 'edges': reading.edges}),
      if (!canRead) tr('The formula reader is not installed, so the circles are numbered: rename them here.'),
      for (final (text, params) in reading.notes) tr(text, params),
    ].join('\n');
    final request = await askDiagram(context, initial: reading.text, mode: reading.mode, note: notes, rootTitle: _titleController.text.trim());
    if (request == null || !mounted || request.mode == DiagramMode.simple) return;
    final advanced = buildAdvanced(request.mode, request.text, options: request.options);
    if (advanced.isEmpty) return;
    _placeDiagram(advanced.layout, replacing: drawn, replacingPage: page);
  }

  /// Puts [made] on the page in view (or, with [replacing], where the drawing it was read from was, which it takes the place of), all of
  /// it selected, as one step to take back.
  void _placeDiagram(DiagramLayout made, {List<DrawingStroke>? replacing, int? replacingPage}) {
    final (visiblePage, visibleScrolled) = _visiblePage();
    final page = replacing == null ? visiblePage : replacingPage!;
    final scrolled = replacing == null ? visibleScrolled : 0.0;
    final gone = <(int, DrawingStroke)>[];
    Rect? over;
    if (replacing != null) {
      for (final st in replacing) {
        final b = strokeBounds(st);
        over = over == null ? b : over.expandToInclude(b);
      }
    }
    final room = math.max(200.0, _paperWidth - 80);
    var layout = made.fitted(room);
    // a diagram taller than the page is made smaller still
    final tall = _infinite ? double.infinity : math.max(200.0, _heightOf(page) - 80);
    if (layout.size.height > tall) layout = layout.fitted(math.max(100.0, layout.size.width * tall / layout.size.height), minScale: 0.3);
    final origin = Offset(
      math.max(0.0, _visibleLeft + (_paperWidth - layout.size.width) / 2).clamp(0.0, math.max(0.0, _paperWidth - layout.size.width)),
      _infinite ? scrolled + 40 : math.min(scrolled + 40, math.max(0.0, _heightOf(page) - layout.size.height - 20)),
    );
    // (over the drawing it was read from: in the middle of it)
    final at = over == null
        ? origin
        : Offset(
            (over.center.dx - layout.size.width / 2).clamp(0.0, math.max(0.0, _paperWidth - layout.size.width)),
            _infinite ? math.max(0.0, over.center.dy - layout.size.height / 2) : (over.center.dy - layout.size.height / 2).clamp(0.0, math.max(0.0, _heightOf(page) - layout.size.height)),
          );

    final placed = placeLayout(layout, at, author: Authorship.current, layer: _placeLayer);
    final boxes = placed.boxes, strokes = placed.strokes;
    for (final b in boxes) {
      _attachBox(b);
    }
    setState(() {
      final list = _strokesPerPage.putIfAbsent(page, () => []);
      if (replacing != null) {
        for (var i = 0; i < list.length; i++) {
          if (replacing.contains(list[i])) gone.add((i, list[i]));
        }
        list.removeWhere(replacing.contains);
      }
      list.addAll(strokes);
      _textBoxesPerPage.putIfAbsent(page, () => []).addAll(boxes);
      // all of it is selected, so that it can be moved as one
      _selection = strokes;
      _groupBoxes = boxes;
      _selectedStrokePage = page;
      _activeSelectedBox = null;
      _selectedImage = null;
      _undoStack.push(UndoStep(
        () {
          for (final s in strokes) {
            _strokesPerPage[page]?.remove(s);
          }
          for (final b in boxes) {
            _textBoxesPerPage[page]?.remove(b);
          }
          // (the drawing comes back where it was in the order of the strokes)
          for (final (i, st) in gone) {
            final l = _strokesPerPage.putIfAbsent(page, () => []);
            l.insert(math.min(i, l.length), st);
          }
          _clearSelection();
        },
        () {
          _strokesPerPage[page]?.removeWhere(replacing?.contains ?? (_) => false);
          _strokesPerPage.putIfAbsent(page, () => []).addAll(strokes);
          _textBoxesPerPage.putIfAbsent(page, () => []).addAll(boxes);
        },
      ));
    });
    _scheduleSave();
  }
}
