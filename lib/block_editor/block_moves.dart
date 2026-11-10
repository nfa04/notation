part of 'block_editor.dart';

/// What the keys do: the same intents as in a text field, so that each platform has its own keys for them.
extension _BlockMoves on BlockEditorState {
  Map<Type, Action<Intent>> _makeActions() => {
        DoNothingAndStopPropagationTextIntent: DoNothingAction(consumesKey: false),
        DeleteCharacterIntent: CallbackAction<DeleteCharacterIntent>(onInvoke: (i) => _delete(i.forward, _characterEdge)),
        DeleteToNextWordBoundaryIntent: CallbackAction<DeleteToNextWordBoundaryIntent>(onInvoke: (i) => _delete(i.forward, _wordEdge)),
        DeleteToLineBreakIntent: CallbackAction<DeleteToLineBreakIntent>(onInvoke: (i) => _delete(i.forward, _lineEdge)),
        ExtendSelectionByCharacterIntent: CallbackAction<ExtendSelectionByCharacterIntent>(onInvoke: _byCharacter),
        ExtendSelectionToNextWordBoundaryIntent: CallbackAction<ExtendSelectionToNextWordBoundaryIntent>(onInvoke: (i) => _extend(i, _wordEdge)),
        ExtendSelectionToNextWordBoundaryOrCaretLocationIntent: CallbackAction<ExtendSelectionToNextWordBoundaryOrCaretLocationIntent>(onInvoke: (i) => _extend(i, _wordEdge)),
        ExtendSelectionToLineBreakIntent: CallbackAction<ExtendSelectionToLineBreakIntent>(onInvoke: (i) => _extend(i, _lineEdge)),
        ExpandSelectionToLineBreakIntent: CallbackAction<ExpandSelectionToLineBreakIntent>(onInvoke: (i) => _expand(i, _lineEdge)),
        ExtendSelectionToNextParagraphBoundaryIntent: CallbackAction<ExtendSelectionToNextParagraphBoundaryIntent>(onInvoke: (i) => _extend(i, _paragraphEdge)),
        ExtendSelectionToNextParagraphBoundaryOrCaretLocationIntent: CallbackAction<ExtendSelectionToNextParagraphBoundaryOrCaretLocationIntent>(onInvoke: (i) => _extend(i, _paragraphEdge)),
        ExtendSelectionToDocumentBoundaryIntent: CallbackAction<ExtendSelectionToDocumentBoundaryIntent>(onInvoke: (i) => _extend(i, _documentEdge)),
        ExpandSelectionToDocumentBoundaryIntent: CallbackAction<ExpandSelectionToDocumentBoundaryIntent>(onInvoke: (i) => _expand(i, _documentEdge)),
        ExtendSelectionVerticallyToAdjacentLineIntent: CallbackAction<ExtendSelectionVerticallyToAdjacentLineIntent>(onInvoke: _byLine),
        ExtendSelectionVerticallyToAdjacentPageIntent: CallbackAction<ExtendSelectionVerticallyToAdjacentPageIntent>(onInvoke: _byPage),
        ScrollToDocumentBoundaryIntent: CallbackAction<ScrollToDocumentBoundaryIntent>(onInvoke: _scrollToEdge),
        SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(onInvoke: (_) => _selectAll()),
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(onInvoke: (i) => _copy(cut: i.collapseSelection)),
        PasteTextIntent: CallbackAction<PasteTextIntent>(onInvoke: (_) => _paste()),
        ReplaceTextIntent: CallbackAction<ReplaceTextIntent>(onInvoke: (i) {
          if (_editable) _c.value = i.currentTextEditingValue.replaced(i.replacementRange, i.replacementText);
          return null;
        }),
        UpdateSelectionIntent: CallbackAction<UpdateSelectionIntent>(onInvoke: (i) {
          _setSelection(i.newSelection);
          return null;
        }),
        TransposeCharactersIntent: CallbackAction<TransposeCharactersIntent>(onInvoke: (_) => _transpose()),
      };

  void _setSelection(TextSelection s) {
    _goalX = null;
    final length = _c.text.length;
    _c.selection = s.copyWith(baseOffset: s.baseOffset.clamp(0, length), extentOffset: s.extentOffset.clamp(0, length));
  }

  // ---- where things end

  /// The line [offset] is on: its index, and where it is in the text.
  ({int index, int start, int end}) _lineOf(int offset) {
    final i = _lines.lineAt(offset);
    final b = _lines.blocks[i];
    return (index: i, start: b.start, end: b.end);
  }

  int _characterEdge(int offset, bool forward) {
    final text = _c.text;
    final line = _lineOf(offset);
    if (forward ? offset >= line.end : offset <= line.start) return (forward ? offset + 1 : offset - 1).clamp(0, text.length);
    // (a character can be several units of the text; only its line is looked at)
    final part = text.substring(line.start, line.end);
    final boundary = CharacterBoundary(part);
    final at = offset - line.start;
    return line.start + (forward ? boundary.getTrailingTextBoundaryAt(at) ?? part.length : boundary.getLeadingTextBoundaryAt(at - 1) ?? 0);
  }

  /// The end of the word after [offset], or the start of the one before it; past the end of a line that is the line break.
  int _wordEdge(int offset, bool forward) {
    final text = _c.text;
    var at = offset;
    while (true) {
      final line = _lineOf(at);
      if (forward ? at >= line.end : at <= line.start) {
        final past = (forward ? at + 1 : at - 1).clamp(0, text.length);
        if (at == offset && past != at) {
          at = past;
          continue;
        }
        return at;
      }
      final part = text.substring(line.start, line.end);
      final r = _renderOf(line.index);
      var i = at - line.start;
      // spaces and marks of punctuation are not stopped at
      bool blank(int k) => RegExp(r'[\s\p{P}\p{S}]', unicode: true).hasMatch(part[k]);
      if (forward) {
        while (i < part.length && blank(i)) {
          i++;
        }
        if (i >= part.length) return line.end;
        final word = r?.wordAt(i);
        return line.start + (word == null || word.end <= i ? _plainWordEnd(part, i) : word.end);
      }
      while (i > 0 && blank(i - 1)) {
        i--;
      }
      if (i <= 0) return line.start;
      final word = r?.wordAt(i - 1);
      return line.start + (word == null || word.start >= i ? _plainWordStart(part, i) : word.start);
    }
  }

  static int _plainWordEnd(String s, int from) {
    var i = from;
    while (i < s.length && s.codeUnitAt(i) > 0x20) {
      i++;
    }
    return i;
  }

  static int _plainWordStart(String s, int from) {
    var i = from;
    while (i > 0 && s.codeUnitAt(i - 1) > 0x20) {
      i--;
    }
    return i;
  }

  /// The end of the line as it is wrapped on screen.
  int _lineEdge(int offset, bool forward) {
    final line = _lineOf(offset);
    final r = _renderOf(line.index);
    if (r == null) return forward ? line.end : line.start;
    final local = offset - line.start;
    final edges = r.visualLineAt(TextPosition(offset: local, affinity: _c.selection.affinity));
    return line.start + (forward ? edges.end : edges.start);
  }

  int _paragraphEdge(int offset, bool forward) {
    final line = _lineOf(offset);
    if (forward) return offset < line.end ? line.end : (line.index + 1 < _lines.length ? _lines.blocks[line.index + 1].end : line.end);
    return offset > line.start ? line.start : (line.index > 0 ? _lines.blocks[line.index - 1].start : 0);
  }

  int _documentEdge(int offset, bool forward) => forward ? _c.text.length : 0;

  // ---- changing the text

  Object? _delete(bool forward, int Function(int, bool) edge) {
    if (!_editable) return null;
    final s = _c.selection;
    if (!s.isValid) return null;
    final text = _c.text;
    _hideMarks();
    final from = s.isCollapsed ? (forward ? s.start : edge(s.start, false)) : s.start;
    final to = s.isCollapsed ? (forward ? edge(s.start, true) : s.start) : s.end;
    if (from == to) return null;
    _typed(() => _c.value = TextEditingValue(text: text.replaceRange(from, to, ''), selection: TextSelection.collapsed(offset: from)));
    return null;
  }

  Object? _transpose() {
    final s = _c.selection;
    final text = _c.text;
    if (!_editable || !s.isValid || !s.isCollapsed || text.length < 2) return null;
    final after = s.start >= text.length ? text.length - 1 : s.start;
    if (after == 0) return null;
    final before = _characterEdge(after, false);
    final end = _characterEdge(after, true);
    _c.value = TextEditingValue(text: text.replaceRange(before, end, text.substring(after, end) + text.substring(before, after)), selection: TextSelection.collapsed(offset: end));
    return null;
  }

  void _selectAll() => _setSelection(TextSelection(baseOffset: 0, extentOffset: _c.text.length));

  Future<void> _copy({required bool cut}) async {
    final s = _c.selection;
    if (!s.isValid || s.isCollapsed) return;
    final text = _c.text;
    final picked = s.textInside(text);
    if (cut && _editable) {
      _c.value = TextEditingValue(text: text.replaceRange(s.start, s.end, ''), selection: TextSelection.collapsed(offset: s.start));
    } else if (!cut) {
      _hideMenu();
    }
    await Clipboard.setData(ClipboardData(text: picked));
  }

  Future<void> _paste() async {
    if (!_editable) return;
    final paste = widget.onPaste;
    _hideMarks();
    if (paste != null) return paste();
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted) return;
    final s = _c.selection.isValid ? _c.selection : TextSelection.collapsed(offset: _c.text.length);
    _c.value = TextEditingValue(text: _c.text.replaceRange(s.start, s.end, text), selection: TextSelection.collapsed(offset: s.start + text.length));
  }

  // ---- moving the caret

  /// Moves the moving end of the selection to [to], or all of it when [collapse]; a collapsed selection stays one only then.
  void _moveTo(int to, {required bool collapse, TextAffinity affinity = TextAffinity.downstream}) {
    final s = _c.selection;
    _c.selection = collapse || !s.isValid ? TextSelection.collapsed(offset: to, affinity: affinity) : s.extendTo(TextPosition(offset: to, affinity: affinity));
  }

  Object? _byCharacter(ExtendSelectionByCharacterIntent i) {
    final s = _c.selection;
    if (!s.isValid) return null;
    _goalX = null;
    // with something selected, the plain arrow keys go to its end
    if (!s.isCollapsed && i.collapseSelection) {
      _moveTo(i.forward ? s.end : s.start, collapse: true);
      return null;
    }
    _moveTo(_characterEdge(s.extentOffset, i.forward), collapse: i.collapseSelection);
    return null;
  }

  Object? _extend(DirectionalCaretMovementIntent i, int Function(int, bool) edge) {
    final s = _c.selection;
    if (!s.isValid) return null;
    _goalX = null;
    final moving = i.collapseSelection && !s.isCollapsed ? (i.forward ? s.end : s.start) : s.extentOffset;
    var to = edge(moving, i.forward);
    if (i.collapseAtReversal && !s.isCollapsed && (s.baseOffset < s.extentOffset) != (s.baseOffset < to) && to != s.baseOffset) to = s.baseOffset;
    // (at the end of a wrapped line, the caret stays on that line)
    _moveTo(to, collapse: i.collapseSelection, affinity: identical(edge, _lineEdge) && i.forward ? TextAffinity.upstream : TextAffinity.downstream);
    return null;
  }

  /// Like [_extend], but the selection only ever grows.
  Object? _expand(DirectionalCaretMovementIntent i, int Function(int, bool) edge) {
    final s = _c.selection;
    if (!s.isValid) return null;
    _goalX = null;
    final to = edge(i.forward ? s.end : s.start, i.forward);
    _c.selection = i.forward ? TextSelection(baseOffset: s.start, extentOffset: to) : TextSelection(baseOffset: s.end, extentOffset: to);
    return null;
  }

  Object? _byLine(ExtendSelectionVerticallyToAdjacentLineIntent i) {
    final s = _c.selection;
    if (!s.isValid) return null;
    final moving = i.collapseSelection && !s.isCollapsed ? (i.forward ? s.end : s.start) : s.extentOffset;
    final to = _verticalFrom(moving, i.forward);
    if (to == null) return null;
    final keep = _goalX;
    _moveTo(to.offset, collapse: i.collapseSelection, affinity: to.affinity);
    _goalX = keep;
    return null;
  }

  /// The place above or below [offset], as near as can be to where the caret started going up or down.
  TextPosition? _verticalFrom(int offset, bool down) {
    final line = _lineOf(offset);
    final r = _renderOf(line.index);
    if (r == null) return TextPosition(offset: down ? line.end : line.start);
    final place = TextPosition(offset: offset - line.start, affinity: _c.selection.affinity);
    final x = _goalX ??= r.caretRect(place).left;
    final box = r.lineBoxAt(place);
    final y = down ? box.bottom + 1 : box.top - 1;
    if (y >= 0 && y < r.size.height) {
      final p = r.positionAt(Offset(x, y));
      return TextPosition(offset: line.start + p.offset, affinity: p.affinity);
    }
    final next = line.index + (down ? 1 : -1);
    if (next < 0) return const TextPosition(offset: 0);
    if (next >= _lines.length) return TextPosition(offset: _c.text.length);
    final other = _renderOf(next);
    final start = _lines.blocks[next].start;
    if (other == null) return TextPosition(offset: start);
    final p = other.positionAt(Offset(x, down ? 1 : other.size.height - 1));
    return TextPosition(offset: start + p.offset, affinity: p.affinity);
  }

  Object? _byPage(ExtendSelectionVerticallyToAdjacentPageIntent i) {
    final s = _c.selection;
    final seen = _visible();
    final rect = _caretRect;
    if (!s.isValid || seen == null || rect == null) return null;
    final y = rect.center.dy + (i.forward ? seen.height : -seen.height);
    final target = _lines.lineAtY(y.clamp(0.0, _lines.height));
    final r = _renderOf(target);
    final start = _lines.blocks[target].start;
    final x = _goalX ??= rect.left;
    final place = r == null ? start : start + r.positionAt(Offset(x, _lines.lines[target].natural(y - _lines.topOf(target)))).offset;
    final keep = _goalX;
    _moveTo(i.forward && y >= _lines.height ? _c.text.length : (y < 0 ? 0 : place), collapse: i.collapseSelection);
    _goalX = keep;
    return null;
  }

  Object? _scrollToEdge(ScrollToDocumentBoundaryIntent i) {
    final position = _position;
    if (position != null) position.jumpTo(i.forward ? position.maxScrollExtent : position.minScrollExtent);
    return null;
  }
}
