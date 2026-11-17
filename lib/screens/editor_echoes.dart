part of 'fixed_page_note_editor.dart';

/// "You wrote about this before": while a text is written, a small note names the other notes whose facts (those of the graph view) have
/// the same terms; with a sentence model also the notes that say something similar in other words. A moment after the writing stops.
extension _EditorEchoes on _FixedPageNoteEditorState {
  bool get _echoesOn => _on(Feature.echoes) && (widget.onOpenNote != null || widget.onOpenNoteAt != null);

  /// A moment after the text [text] (read when the moment comes) was changed: look for notes that say the same.
  void _echoesSoon(String Function() text) {
    if (!_loaded || !_echoesOn) return;
    _echoText = text;
    _echoTimer?.cancel();
    _echoTimer = Timer(const Duration(milliseconds: 1800), _lookForEchoes);
  }

  Future<void> _lookForEchoes() async {
    final read = _echoText;
    if (!mounted || read == null || !_echoesOn) return;
    // (the facts are read when first needed and again after a few minutes: a graph that was made meanwhile counts)
    final now = DateTime.now();
    if (_echoIndex == null || _echoIndexAt == null || now.difference(_echoIndexAt!) > const Duration(minutes: 5)) {
      try {
        _echoIndex = EchoIndex(await widget.repository.knowledge.allFacts());
        _echoIndexAt = now;
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    final text = read();
    final found = [..._echoIndex!.find(text, exceptNote: widget.noteId)];
    // notes that say the same in other words (when a sentence model is there): after the ones that share words, up to three in all
    final knowledge = widget.knowledge;
    if (knowledge != null && found.length < 3) {
      try {
        for (final s in await knowledge.similarNotes(text, exceptNote: widget.noteId, max: 3 - found.length)) {
          if (found.length < 3 && !found.any((e) => e.noteId == s.noteId)) found.add(Echo(s.noteId, const [], null, similarity: s.score));
        }
      } catch (_) {
        // (a model that fails leaves the echoes of words)
      }
      if (!mounted) return;
    }
    final key = found.map((e) => e.noteId).join(',');
    if (key == _echoLooked) return; // the same notes as before: a person who closed the note does not see it come back
    _echoLooked = key;
    final titles = <String, String>{};
    for (final e in found) {
      final info = await widget.repository.noteInfo(e.noteId);
      if (info != null) titles[e.noteId] = info.title;
    }
    if (!mounted) return;
    setState(() {
      _echoHidden = false;
      _echoes = [for (final e in found) if (titles.containsKey(e.noteId)) e];
      _echoTitles = titles;
    });
  }

  Widget _echoChip() {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomLeft,
      child: Material(
        key: const ValueKey('echoes'),
        elevation: 2,
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.hub_outlined, size: 16, color: scheme.onSecondaryContainer),
            const SizedBox(width: 6),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(tr('Also in'), style: TextStyle(color: scheme.onSecondaryContainer)),
                  for (final e in _echoes)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ActionChip(
                        key: ValueKey('echo-${e.noteId}'),
                        visualDensity: VisualDensity.compact,
                        label: Text.verbatim(_echoTitles[e.noteId]!.isEmpty ? tr('Untitled') : _echoTitles[e.noteId]!),
                        tooltip: e.terms.isEmpty ? tr('Says something similar') : tr('Both have: {terms}', {'terms': e.terms.join(', ')}),
                        onPressed: () => widget.onOpenNoteAt != null ? widget.onOpenNoteAt!(e.noteId, e.page) : widget.onOpenNote?.call(e.noteId),
                      ),
                    ),
                ]),
              ),
            ),
            IconButton(
              key: const ValueKey('echoes-close'),
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: tr('Hide'),
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _echoHidden = true),
            ),
          ]),
        ),
      ),
    );
  }
}
