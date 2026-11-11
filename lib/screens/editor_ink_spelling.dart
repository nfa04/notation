part of 'fixed_page_note_editor.dart';

/// Spell checking of the handwriting: the words the dictionaries do not know are underlined where they are written, once the
/// writing has been read in the background ([NoteInkReader]; the same readings the search and the PDF text use). A tap on
/// the word shows what it may have been meant to be, and offers to add it to the dictionary or leave it alone.
extension _EditorInkSpelling on _FixedPageNoteEditorState {
  /// Whether the handwriting is checked: spell checking is on, there is a dictionary and the handwriting reader is.
  bool get _spellInkOn => _on(Feature.spelling) && widget.spell != null && widget.spell!.active && widget.handwriting != null && _inSettings(Feature.handwriting);

  /// Works out the underlines again from what has been read (after readings arrive, the ink changes or the dictionaries do).
  void _refreshInkSpelling() {
    if (!mounted) return;
    final spell = widget.spell;
    final next = <InkMisspelling>[];
    if (_spellInkOn) {
      final seen = <String>{};
      for (final r in _ink?.readings() ?? const <({InkCluster block, String? text, String? latex})>[]) {
        final text = r.text;
        if (text == null) continue;
        final unsure = _ink?.unsureOf(r.block.key) ?? const <String>{};
        final key = '${r.block.page}\u0000${r.block.key}\u0000$text\u0000${unsure.join(' ')}';
        seen.add(key);
        next.addAll(_inkSpellByBlock[key] ??= checkedInk([(block: r.block, text: text)], spell!.checker, unsure: unsure));
      }
      _inkSpellByBlock.removeWhere((k, _) => !seen.contains(k));
    } else {
      _inkSpellByBlock.clear();
    }
    final same = next.length == _inkSpelling.length && !next.asMap().entries.any((e) => e.value.key != _inkSpelling[e.key].key || e.value.word != _inkSpelling[e.key].word || e.value.correct != _inkSpelling[e.key].correct || e.value.unsure != _inkSpelling[e.key].unsure || e.value.rect != _inkSpelling[e.key].rect);
    if (!same) setState(() => _inkSpelling = next);
  }

  /// Soon after the writing changed (a changed block has no reading until it is read again, and its underlines go).
  void _refreshInkSpellingSoon() {
    if (!_spellInkOn && _inkSpelling.isEmpty) return;
    _spellTimer?.cancel();
    _spellTimer = Timer(const Duration(milliseconds: 300), _refreshInkSpelling);
  }

  /// The underlines of one page.
  List<Widget> _spellWidgets(int pageIndex) => [
        for (final m in _inkSpelling)
          if (m.page == pageIndex && (!m.correct || m.unsure || (widget.spell?.showChecked ?? false)))
            Positioned.fromRect(
              rect: m.rect.inflate(2),
              child: IgnorePointer(
                ignoring: _mode == CanvasInteractionMode.draw, // (the pen draws there; tap it in another mode)
                child: Builder(
                  builder: (box) => GestureDetector(
                    key: ValueKey(m.correct ? 'ink-word-${m.word}' : 'ink-spell-${m.word}'),
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (d) {
                      if (_mode == CanvasInteractionMode.selectText) _selectWordStrokes(m);
                      // the menu opens just under the word (as it is on the screen, zoom included), not over it
                      var at = d.globalPosition;
                      final render = box.findRenderObject();
                      if (render is RenderBox && render.hasSize) at = Offset(at.dx, render.localToGlobal(Offset(0, render.size.height)).dy + 4);
                      if (m.correct) {
                        _wordMenu(m, at);
                      } else {
                        _spellMenu(m, at);
                      }
                    },
                    // (yellow: the reader was not sure of the word, so it may be what was read that is wrong; red: not in the dictionary)
                    child: CustomPaint(painter: m.unsure ? const _SquigglePainter(Colors.amber) : m.correct ? const _CheckedPainter() : const _SquigglePainter(Colors.red)),
                  ),
                ),
              ),
            ),
      ];

  /// Selects every stroke of a tapped word (those of its block that lie within the word's box), so the word can be moved as one.
  void _selectWordStrokes(InkMisspelling m) {
    if (m.strokes.isNotEmpty) {
      final own = [for (final s in m.strokes) if (_layers.editable(s)) s];
      if (own.isEmpty) return;
      setState(() {
        _clearSelection();
        _activeSelectedBox = null;
        _selectedImage = null;
        _selection = own;
        _selectedStrokePage = m.page;
      });
      return;
    }
    InkCluster? block;
    for (final r in _ink?.readings() ?? const <({InkCluster block, String? text, String? latex})>[]) {
      if (r.block.page == m.page && r.block.key == m.key) {
        block = r.block;
        break;
      }
    }
    if (block == null) return;
    final box = m.rect.inflate(2);
    final strokes = [
      for (final s in block.strokes)
        if (s.points.isNotEmpty && _layers.editable(s) && box.contains(strokeBounds(s).center)) s,
    ];
    if (strokes.isEmpty) return;
    setState(() {
      _clearSelection();
      _activeSelectedBox = null;
      _selectedImage = null;
      _selection = strokes;
      _selectedStrokePage = m.page;
    });
  }

  /// A word that is spelled right, tapped to see what it was read as: copy it, or see that it is not there at all.
  Future<void> _wordMenu(InkMisspelling m, Offset at) async {
    if (!mounted) return;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(Rect.fromLTWH(at.dx, at.dy, 1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem<int>(enabled: false, height: 32, child: Text(tr('Read as: {word}', {'word': m.word}), style: const TextStyle(fontStyle: FontStyle.italic))),
        if (m.unsure) PopupMenuItem<int>(enabled: false, height: 32, child: Text(tr('The reader was not sure of this word'))),
        PopupMenuItem<int>(value: 1, child: Text(tr('Copy'))),
      ],
    );
    if (choice == 1) await Clipboard.setData(ClipboardData(text: m.word));
  }

  Future<void> _spellMenu(InkMisspelling m, Offset at) async {
    final spell = widget.spell;
    if (spell == null || !mounted) return;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final suggestions = spell.checker.suggestions(m.word, max: 5);
    final choice = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(Rect.fromLTWH(at.dx, at.dy, 1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem<int>(enabled: false, height: 32, child: Text(tr('Not in the dictionary: {word}', {'word': m.word}), style: const TextStyle(fontStyle: FontStyle.italic))),
        if (m.unsure) PopupMenuItem<int>(enabled: false, height: 32, child: Text(tr('The reader was not sure of this word'))),
        for (var i = 0; i < suggestions.length; i++) PopupMenuItem<int>(key: ValueKey('ink-spell-suggestion-$i'), value: i, child: Text(suggestions[i], style: const TextStyle(fontWeight: FontWeight.w600))),
        PopupMenuItem<int>(value: -1, child: Text(tr('Add to dictionary'))),
        PopupMenuItem<int>(value: -2, child: Text(tr('Ignore'))),
      ],
    );
    if (choice == null || !mounted) return;
    if (choice == -1) {
      await spell.addWord(m.word);
    } else if (choice == -2) {
      spell.ignore(m.word);
    } else {
      // (the ink cannot be changed into a word: the right spelling goes to the clipboard to write it by)
      await Clipboard.setData(ClipboardData(text: suggestions[choice]));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied: {word}', {'word': suggestions[choice]}))));
    }
  }
}

/// A wavy line along the foot of a word: red for a misspelled one, yellow for one the reader was not sure of.
class _SquigglePainter extends CustomPainter {
  final Color color;
  const _SquigglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(0, size.height - 2);
    var up = true;
    for (var x = 0.0; x < size.width; x += 3) {
      path.lineTo(math.min(x + 3, size.width), size.height - (up ? 4 : 1));
      up = !up;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_SquigglePainter old) => old.color != color;
}

/// A green dotted line along the foot of a word that is spelled right (shown when the person asks to see what was read).
class _CheckedPainter extends CustomPainter {
  const _CheckedPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green.withValues(alpha: 0.8)
      ..strokeWidth = 1.6;
    for (var x = 0.0; x < size.width; x += 4) {
      canvas.drawLine(Offset(x, size.height - 2), Offset(math.min(x + 2, size.width), size.height - 2), paint);
    }
  }

  @override
  bool shouldRepaint(_CheckedPainter old) => false;
}
