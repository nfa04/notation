part of 'fixed_page_note_editor.dart';

/// The stamp library: drawings kept to be put on pages again.
extension _EditorStamps on _FixedPageNoteEditorState {
  StampLibrary get _stamps => StampLibrary(getApplicationSupportDirectory);

  /// Keeps the selected drawings as a stamp, under a name that is asked for.
  Future<void> _saveAsStamp() async {
    final lines = [for (final s in _selection) if (s.points.length >= 2) s];
    if (lines.isEmpty) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return PlatformAlertDialog(
          title: Text(tr('Save as a stamp')),
          content: TextField(
            key: const ValueKey('stamp-name'),
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: tr('Name')),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
            FilledButton(key: const ValueKey('stamp-save'), onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(tr('Save'))),
          ],
        );
      },
    );
    if (name == null || !mounted) return;
    final stamp = Stamp.of(NoteRepository.newId(), name, lines);
    try {
      await _stamps.add(stamp);
      if (!mounted) return;
      _stampsTick.value++;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr('Saved as a stamp.'))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not save the stamp: {error}', {'error': e}))));
    }
  }

  /// Opens the library; the stamp that is chosen is put on the page on screen.
  Future<void> _openStamps() async {
    if (_stampsOpen) {
      _toggleSidePanel(true, () {});
      return;
    }
    if (!_drawingLayer.editable) {
      _layerBlocked();
      return;
    }
    if (_roomForSidePanel) {
      _toggleSidePanel(_stampsOpen, () => _stampsOpen = true);
      return;
    }
    final stamp = await showDialog<Stamp>(context: context, builder: (_) => StampsDialog(library: _stamps));
    if (stamp == null || !mounted) return;
    _placeStamp(stamp);
  }

  /// The library beside the note: a stamp that is chosen goes on the page, and the library stays open.
  Widget _stampsPanel({required VoidCallback onClose}) => StampsPanel(
        key: const ValueKey('stamps-panel'),
        library: _stamps,
        changed: _stampsTick,
        onPick: (stamp) {
          if (!_drawingLayer.editable) return _layerBlocked();
          _placeStamp(stamp);
        },
        onClose: onClose,
      );

  /// Puts the stamp near the top of the page on screen, in the middle, selected so that it can be moved or resized at once (a stamp
  /// wider or taller than half the page is made smaller).
  void _placeStamp(Stamp stamp) {
    final box = stamp.bounds;
    if (stamp.strokes.isEmpty) return;
    final (page, scrolled) = _visiblePage();
    final scale = math.min(1.0, math.min(_paperWidth * 0.5 / math.max(1.0, box.width), _heightOf(page) * 0.5 / math.max(1.0, box.height)));
    final w = box.width * scale, h = box.height * scale;
    final topLeft = Offset(
      (_infinite ? _visibleLeft + 80 : (_paperWidth - w) / 2).clamp(0.0, math.max(0.0, _paperWidth - w)),
      (scrolled + 80).clamp(0.0, math.max(0.0, _heightOf(page) - h)),
    );
    final lines = stamp.placed(topLeft - box.topLeft * scale, scale: scale, author: Authorship.current, layer: _placeLayer);
    setState(() {
      _clearSelection();
      _strokesPerPage.putIfAbsent(page, () => []).addAll(lines);
      _selection = lines;
      _selectedStrokePage = page;
      _undoStack.push(UndoStep(
        () => _strokesPerPage[page]?.removeWhere(lines.contains),
        () => _strokesPerPage.putIfAbsent(page, () => []).addAll(lines),
      ));
    });
  }
}
