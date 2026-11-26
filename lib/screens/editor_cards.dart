part of 'fixed_page_note_editor.dart';

/// Cards made of a selection on the page: a picture of it with a typed answer, covers over its parts, or words of its text hidden.
extension _EditorCards on _FixedPageNoteEditorState {
  /// Whether "Make cards" is offered for the selection.
  bool get _canMakeCards => widget.cards != null && _on(Feature.flashcards) && _selectedStrokePage >= 0 && _selectionBounds() != null;

  Future<void> _makeCardsFromSelection() async {
    final cards = widget.cards;
    final page = _selectedStrokePage;
    var area = _selectionBounds();
    if (cards == null || page < 0 || area == null) return;
    if (!_infinite) area = area.intersect(Offset.zero & Size(_paperWidth, _heightOf(page)));
    if (area.width < 4 || area.height < 4) return;
    final messenger = ScaffoldMessenger.of(context);
    // about 1200 pixels across (sharp on a tablet), never less than the page's own size or more than three times it
    final scale = (1200 / area.width).clamp(1.0, 3.0);
    final width = (area.width * scale).round(), height = math.max(1, (area.height * scale).round());
    final Uint8List png;
    try {
      png = await _picturePage(page, ImagePreset.screen, seeThrough: false, area: area, across: width.toDouble());
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not make the picture: {error}', {'error': e}))));
      return;
    }
    if (!mounted) return;
    // what is known of the text already (typed in boxes, handwriting read in the background): offered as the answer
    final read = [
      for (final b in _groupBoxes)
        if (b.controller.text.trim().isNotEmpty) b.controller.text.trim(),
      if (_selection.isNotEmpty) ?_ink?.lookupText(_selection)?.trim(),
    ].where((t) => t.isNotEmpty).join('\n');
    final draft = await showMakeCards(context, png: png, width: width, height: height, readText: read);
    if (draft == null) return;
    final picture = await cards.putPicture(png, width: width, height: height);
    final base = RegionCard(picture: picture, width: width, height: height, note: widget.noteId, page: page, area: [area.left, area.top, area.width, area.height]);
    final made = draft.cards(base);
    final added = await cards.addAll(widget.noteId, made);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      key: const ValueKey('cards-made'),
      content: Text.verbatim(added == 0 ? tr('These cards are kept for review already.') : trCount(added, '{n} card kept for review', '{n} cards kept for review')),
    ));
  }
}
