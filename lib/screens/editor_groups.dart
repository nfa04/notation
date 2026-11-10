part of 'fixed_page_note_editor.dart';

/// Groups: drawings, text boxes and pictures that are kept together. What is in a group is selected, moved, resized, copied, put on a
/// layer and deleted together; *Group* in the selection's tools makes one of what is selected, *Ungroup* lets go of it.
extension _EditorGroups on _FixedPageNoteEditorState {
  bool get _groupsOn => _on(Feature.arrange);

  /// The groups that anything in the selection is in.
  Set<String> _selectedGroups() => {
        for (final s in _selection)
          if (s.group != noGroup) s.group,
        for (final b in _groupBoxes)
          if (b.group != noGroup) b.group,
        for (final m in _groupImages)
          if (m.group != noGroup) m.group,
      };

  /// Adds to the selection what is in the same groups as anything in it, on the page of the selection (but not what is on a hidden or
  /// locked layer). Called whenever the selection is drawn, so that every way of selecting something takes its group with it.
  void _takeWholeGroups(int page) {
    if (!_groupsOn || _selectedStrokePage != page) return;
    final groups = _selectedGroups();
    if (groups.isEmpty) return;
    for (final s in _strokesPerPage[page] ?? const <DrawingStroke>[]) {
      if (groups.contains(s.group) && !_selection.contains(s) && _layers.editable(s)) _selection.add(s);
    }
    for (final b in _textBoxesPerPage[page] ?? const <TextBoxWidgetModel>[]) {
      if (groups.contains(b.group) && !_groupBoxes.contains(b) && _boxEditable(b)) {
        _groupBoxes.add(b);
        if (identical(_activeSelectedBox, b)) _activeSelectedBox = null; // (one selection at a time)
      }
    }
    for (final m in _imagesPerPage[page] ?? const <ImageItem>[]) {
      if (groups.contains(m.group) && !_groupImages.contains(m) && _imageEditable(m)) {
        _groupImages.add(m);
        if (identical(_selectedImage, m)) _selectedImage = null;
      }
    }
  }

  /// Selects the group a text box or picture is in, all of it, so that pulling the one moves the others with it. False if it is in none.
  bool _selectGroupOf({TextBoxWidgetModel? box, ImageItem? image}) {
    final id = box?.group ?? image?.group ?? noGroup;
    if (!_groupsOn || id == noGroup) return false;
    final page = box != null ? _pageOfBox(box) : _pageOfImage(image!);
    if (page == null) return false;
    _activeSelectedBox = null;
    _selectedImage = null;
    _selection = [for (final s in _strokesPerPage[page] ?? const <DrawingStroke>[]) if (s.group == id && _layers.editable(s)) s];
    _groupBoxes = [for (final b in _textBoxesPerPage[page] ?? const <TextBoxWidgetModel>[]) if (b.group == id && _boxEditable(b)) b];
    _groupImages = [for (final m in _imagesPerPage[page] ?? const <ImageItem>[]) if (m.group == id && _imageEditable(m)) m];
    _selectedStrokePage = page;
    return true;
  }

  /// How many things are selected.
  int get _selectedCount => _selection.length + _groupBoxes.length + _groupImages.length;

  /// Whether the selection can be made a group: two or more things that are not one group already.
  bool get _mayGroup {
    if (!_groupsOn || _selectedCount < 2) return false;
    final groups = _selectedGroups();
    final ungrouped = _selection.any((s) => s.group == noGroup) || _groupBoxes.any((b) => b.group == noGroup) || _groupImages.any((m) => m.group == noGroup);
    return ungrouped || groups.length > 1;
  }

  bool get _mayUngroup => _groupsOn && _selectedGroups().isNotEmpty;

  /// Sets the group of everything selected to [id] ([noGroup] to let go), as one step to take back.
  void _setSelectionGroup(String id) {
    final strokes = List.of(_selection), boxes = List.of(_groupBoxes), images = List.of(_groupImages);
    final before = (
      strokes: [for (final s in strokes) s.group],
      boxes: [for (final b in boxes) b.group],
      images: [for (final m in images) m.group],
    );
    void put(List<String> s, List<String> b, List<String> m) {
      setState(() {
        for (var i = 0; i < strokes.length; i++) {
          strokes[i].group = s[i];
        }
        for (var i = 0; i < boxes.length; i++) {
          boxes[i].group = b[i];
        }
        for (var i = 0; i < images.length; i++) {
          images[i].group = m[i];
        }
      });
    }

    put(List.filled(strokes.length, id), List.filled(boxes.length, id), List.filled(images.length, id));
    _undoStack.push(UndoStep(
      () => put(before.strokes, before.boxes, before.images),
      () => put(List.filled(strokes.length, id), List.filled(boxes.length, id), List.filled(images.length, id)),
    ));
    _scheduleSave();
  }

  void _groupSelection() {
    if (_mayGroup) _setSelectionGroup(newElementId());
  }

  void _ungroupSelection() {
    if (_mayUngroup) _setSelectionGroup(noGroup);
  }

  /// The buttons of the selection's tools for groups: *Group* (two or more things) and *Ungroup* (something in a group).
  List<Widget> _groupButtons() => [
        if (_mayGroup)
          IconButton(
            key: const ValueKey('group-selection'),
            icon: const Icon(Icons.workspaces_outlined),
            tooltip: tr('Group: keep these together'),
            visualDensity: VisualDensity.compact,
            onPressed: _groupSelection,
          ),
        if (_mayUngroup)
          IconButton(
            key: const ValueKey('ungroup-selection'),
            icon: const Icon(Icons.workspaces_filled),
            tooltip: tr('Ungroup'),
            visualDensity: VisualDensity.compact,
            onPressed: _ungroupSelection,
          ),
      ];
}
