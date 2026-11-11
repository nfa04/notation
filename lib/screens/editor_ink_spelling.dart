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
        final key = '${r.block.page}\u0000${r.block.key}\u0000$text';
        seen.add(key);
        next.addAll(_inkSpellByBlock[key] ??= misspelledInk([(block: r.block, text: text)], spell!.checker));
      }
      _inkSpellByBlock.removeWhere((k, _) => !seen.contains(k));
    } else {
      _inkSpellByBlock.clear();
    }
    final same = next.length == _inkSpelling.length && !next.asMap().entries.any((e) => e.value.key != _inkSpelling[e.key].key || e.value.word != _inkSpelling[e.key].word || e.value.rect != _inkSpelling[e.key].rect);
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
          if (m.page == pageIndex)
            Positioned.fromRect(
              rect: m.rect.inflate(2),
              child: IgnorePointer(
                ignoring: _mode == CanvasInteractionMode.draw, // (the pen draws there; tap it in another mode)
                child: GestureDetector(
                  key: ValueKey('ink-spell-${m.word}'),
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (d) => _spellMenu(m, d.globalPosition),
                  child: const CustomPaint(painter: _SquigglePainter()),
                ),
              ),
            ),
      ];

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

/// A wavy red line along the foot of a misspelled word.
class _SquigglePainter extends CustomPainter {
  const _SquigglePainter();

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
        ..color = Colors.red.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_SquigglePainter old) => false;
}
