part of 'block_editor.dart';

/// What pointers do: where the caret goes, what is selected, and the menu and handles of a selection.
extension _BlockGestures on BlockEditorState {
  Widget _gestures(Widget child) => _penGestures(TextSelectionGestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: _tapDown,
        onSingleTapUp: _tapUp,
        onDoubleTapDown: _doubleTap,
        onTripleTapDown: _tripleTap,
        onDragSelectionStart: _dragStart,
        onDragSelectionUpdate: _dragUpdate,
        onDragSelectionEnd: _dragEnd,
        onSingleLongTapStart: _longPress,
        onSingleLongTapMoveUpdate: _longPressMove,
        onSingleLongTapEnd: _longPressEnd,
        onSecondaryTapDown: _secondaryDown,
        onSecondaryTap: _secondaryTap,
        child: child,
      ));

  /// The place of the text at [global], a place on the screen.
  TextPosition? _positionAt(Offset global) {
    final column = _column;
    if (column == null || !column.attached || !column.hasSize || _lines.length == 0) return null;
    final local = column.globalToLocal(global);
    if (local.dy < 0) return const TextPosition(offset: 0);
    if (local.dy >= _lines.height) return TextPosition(offset: _c.text.length);
    final i = _lines.lineAtY(local.dy);
    final r = _renderOf(i);
    final start = _lines.blocks[i].start;
    if (r == null) return TextPosition(offset: start);
    final p = r.positionAt(Offset(local.dx, _lines.lines[i].natural(local.dy - _lines.topOf(i))));
    return TextPosition(offset: start + p.offset, affinity: p.affinity);
  }

  void _focus() {
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    } else {
      _openInput();
    }
  }

  static bool _shift() => HardwareKeyboard.instance.logicalKeysPressed.any((k) => k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight);

  void _placeCaret(Offset global) {
    final p = _positionAt(global);
    if (p == null) return;
    _goalX = null;
    final s = _c.selection;
    _c.selection = _shift() && s.isValid ? s.extendTo(p) : TextSelection.fromPosition(p);
  }

  void _tapDown(TapDragDownDetails d) {
    _hideMenu();
    if (d.kind == PointerDeviceKind.stylus || d.kind == PointerDeviceKind.invertedStylus) _startHandwriting(d.globalPosition);
    // (with a finger the caret goes there when it comes up: this could still be a scroll)
    if (d.kind == PointerDeviceKind.mouse || d.kind == PointerDeviceKind.trackpad) {
      if (d.consecutiveTapCount <= 1) _placeCaret(d.globalPosition);
      _focus();
    }
  }

  void _tapUp(TapDragUpDetails d) {
    if (d.kind != PointerDeviceKind.mouse && d.kind != PointerDeviceKind.trackpad) {
      _placeCaret(d.globalPosition);
      _focus();
      _showHandles();
    }
  }

  /// The word at [global], in places of the text.
  TextRange? _wordAt(Offset global) {
    final p = _positionAt(global);
    if (p == null) return null;
    final i = _lines.lineAt(p.offset);
    final r = _renderOf(i);
    final b = _lines.blocks[i];
    if (r == null) return null;
    final word = r.wordAt(math.min(p.offset - b.start, b.end - b.start));
    return TextRange(start: b.start + word.start, end: b.start + word.end);
  }

  void _selectWordAt(Offset global) {
    final word = _wordAt(global);
    if (word == null) return;
    _goalX = null;
    _c.selection = TextSelection(baseOffset: word.start, extentOffset: word.end);
  }

  void _doubleTap(TapDragDownDetails d) {
    _selectWordAt(d.globalPosition);
    _focus();
    if (d.kind != PointerDeviceKind.mouse) {
      _showHandles();
      _showMenu();
    }
  }

  void _tripleTap(TapDragDownDetails d) {
    final p = _positionAt(d.globalPosition);
    if (p == null) return;
    final b = _lines.blocks[_lines.lineAt(p.offset)];
    _goalX = null;
    _c.selection = TextSelection(baseOffset: b.start, extentOffset: b.end);
    _focus();
  }

  void _dragStart(TapDragStartDetails d) {
    // (a finger across a document that is not being written is no selection, and brings no keyboard)
    if (d.kind == PointerDeviceKind.touch && !widget.focusNode.hasFocus) return;
    final p = _positionAt(d.globalPosition);
    if (p == null) return;
    _dragBase = _shift() && _c.selection.isValid ? _c.selection.baseOffset : p.offset;
    _dragKind = d.kind;
    _focus();
  }

  void _dragUpdate(TapDragUpdateDetails d) {
    final p = _positionAt(d.globalPosition);
    final base = _dragBase;
    if (p == null || base == null) return;
    _c.selection = TextSelection(baseOffset: base, extentOffset: p.offset, affinity: p.affinity);
  }

  void _dragEnd(TapDragEndDetails d) {
    final dragged = _dragBase != null;
    _dragBase = null;
    if (dragged && _dragKind != PointerDeviceKind.mouse && _dragKind != PointerDeviceKind.trackpad) _selected();
  }

  void _longPress(LongPressStartDetails d) {
    _pressedWord = _wordAt(d.globalPosition);
    _selectWordAt(d.globalPosition);
    _focus();
    _showHandles();
  }

  // (by whole words, from the one that was pressed: a finger held still still moves a little)
  void _longPressMove(LongPressMoveUpdateDetails d) {
    final from = _pressedWord, to = _wordAt(d.globalPosition);
    if (from == null || to == null) return;
    _c.selection = to.end <= from.start
        ? TextSelection(baseOffset: from.end, extentOffset: to.start)
        : TextSelection(baseOffset: from.start, extentOffset: math.max(from.end, to.end));
  }

  void _longPressEnd(LongPressEndDetails d) {
    _pressedWord = null;
    _showMenu();
  }

  /// A selection was made by something on the screen, which is done with it now: what can be done with it comes up.
  void _selected() {
    _showHandles();
    if (_c.selection.isValid && !_c.selection.isCollapsed) _showMenu();
  }

  void _secondaryDown(TapDownDetails d) {
    _downAt = d.globalPosition;
    final p = _positionAt(d.globalPosition);
    final s = _c.selection;
    // (a click on what is selected keeps it, for the menu to act on)
    if (p != null && !(s.isValid && !s.isCollapsed && p.offset >= s.start && p.offset <= s.end)) _selectWordAt(d.globalPosition);
    _focus();
  }

  void _secondaryTap() {
    final at = _downAt;
    if (at != null) _showMenu(at: at);
  }

  // ---- the menu

  void _hideMenu() {
    if (_menu.isShown) _menu.remove();
  }

  /// Where the menu goes: over the selection, however it was made; the keyboard and the scrolling can move that while the menu is open.
  /// A click has it where it was clicked ([at]).
  TextSelectionToolbarAnchors _menuAnchors(Offset? at) {
    final ends = at == null ? _menuEnds() : null;
    final column = _column;
    if (ends == null || column == null) return TextSelectionToolbarAnchors(primaryAnchor: at ?? _downAt ?? Offset.zero);
    final seen = _visible();
    double kept(double y) => seen == null ? y : y.clamp(seen.top, seen.bottom);
    final x = ends.start.top == ends.end.top ? (ends.start.left + ends.end.left) / 2 : column.size.width / 2;
    return TextSelectionToolbarAnchors(
      primaryAnchor: column.localToGlobal(Offset(x, kept(ends.start.top))),
      secondaryAnchor: column.localToGlobal(Offset(x, kept(ends.end.bottom))),
    );
  }

  ({Rect start, Rect end})? _menuEnds() {
    final s = _c.selection;
    if (!s.isValid) return null;
    final a = _rectAt(s.start), b = _rectAt(s.end, affinity: TextAffinity.upstream);
    return a == null || b == null ? null : (start: a, end: b);
  }

  /// The menu goes with what it is for, and away when that has left the screen.
  void _followMenu() {
    if (!_menu.isShown || _menuAt != null) return;
    final ends = _menuEnds(), seen = _visible();
    if (ends == null || seen != null && (ends.start.top > seen.bottom || ends.end.bottom < seen.top)) return _hideMenu();
    _menu.markNeedsBuild();
  }

  void _showMenu({Offset? at}) {
    final s = _c.selection;
    final picked = s.isValid && !s.isCollapsed;
    List<ContextMenuButtonItem> items() => EditableText.getEditableButtonItems(
          clipboardStatus: ClipboardStatus.pasteable,
          onCopy: picked ? () => _copy(cut: false) : null,
          onCut: picked && _editable ? () => _copy(cut: true) : null,
          onPaste: _editable && _canPaste ? () => _paste() : null,
          onSelectAll: _c.text.isEmpty ? null : _selectAllFromMenu,
          onLookUp: null,
          onSearchWeb: null,
          onShare: null,
          onLiveTextInput: null,
        );
    unawaited(Clipboard.hasStrings().then((has) {
      if (!mounted || has == _canPaste) return;
      _canPaste = has;
      if (_menu.isShown) _menu.markNeedsBuild();
    }, onError: (Object _) {}));
    _menuFor = s;
    _menuAt = at;
    _menu.show(
      context: context,
      contextMenuBuilder: (context) {
        final anchors = _menuAnchors(at);
        final build = widget.menuBuilder;
        // (it is part of the text: a tap on it is not a tap elsewhere, which would close it before its button had it)
        return TextFieldTapRegion(
          child: build != null
              ? build(context, BlockMenu(context: this.context, items: items(), value: _c.value, hide: _hideMenu, anchors: anchors))
              : AdaptiveTextSelectionToolbar.buttonItems(anchors: anchors, buttonItems: items()),
        );
      },
    );
  }

  // (on a touch screen what can be done with all of it comes up again: there may be no keys)
  void _selectAllFromMenu() {
    _hideMenu();
    _selectAll();
    if (!_touchHandles) return;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted) _selected();
      })
      ..ensureVisualUpdate();
  }

  // ---- the handles

  /// Where the two ends of the selection are, while they have handles.
  ({Rect start, Rect end})? _selectionEnds() {
    if (_handles == null) return null;
    final s = _c.selection;
    if (!s.isValid) return null;
    final a = _rectAt(s.start), b = _rectAt(s.end, affinity: TextAffinity.upstream);
    if (a == null || b == null) return null;
    return (start: a, end: b);
  }

  void _showHandles() {
    if (!_touchHandles) return;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) return;
        if (_handles == null) {
          final overlay = _makeHandles();
          if (overlay == null) return;
          _handles = overlay..showHandles();
        }
        _keepMarks();
      })
      ..ensureVisualUpdate();
  }

  bool get _touchHandles => widget.selectionControls != null && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.fuchsia);

  List<TextSelectionPoint> _endpoints(({Rect start, Rect end}) ends) {
    final column = _column;
    Offset screen(Offset o) => column == null ? o : column.localToGlobal(o);
    return _c.selection.isCollapsed
        ? [TextSelectionPoint(screen(ends.end.bottomLeft), null)]
        : [TextSelectionPoint(screen(ends.start.bottomLeft), null), TextSelectionPoint(screen(ends.end.bottomLeft), null)];
  }

  SelectionOverlay? _makeHandles() {
    final s = _c.selection;
    if (!s.isValid) return null;
    final a = _rectAt(s.start), b = _rectAt(s.end, affinity: TextAffinity.upstream);
    if (a == null || b == null) return null;
    final ends = (start: a, end: b);
    return SelectionOverlay(
      context: context,
      debugRequiredFor: widget,
      startHandleType: s.isCollapsed ? TextSelectionHandleType.collapsed : TextSelectionHandleType.left,
      endHandleType: s.isCollapsed ? TextSelectionHandleType.collapsed : TextSelectionHandleType.right,
      lineHeightAtStart: a.height,
      lineHeightAtEnd: b.height,
      startHandlesVisible: _startVisible,
      endHandlesVisible: _endVisible,
      selectionEndpoints: _endpoints(ends),
      selectionControls: widget.selectionControls,
      selectionDelegate: _handleDelegate,
      clipboardStatus: null,
      startHandleLayerLink: _startLink,
      endHandleLayerLink: _endLink,
      toolbarLayerLink: _toolbarLink,
      onStartHandleDragUpdate: (d) => _dragHandle(d, start: true),
      onEndHandleDragUpdate: (d) => _dragHandle(d, start: false),
      onEndHandleDragEnd: (_) => _selected(),
      onStartHandleDragEnd: (_) => _selected(),
      onSelectionHandleTapped: _showMenu,
    );
  }

  void _dragHandle(DragUpdateDetails d, {required bool start}) {
    final s = _c.selection;
    final rect = _rectAt(start ? s.start : s.end);
    // (the handle hangs under its line: the finger means the line above it)
    final p = _positionAt(d.globalPosition - Offset(0, (rect?.height ?? 24) / 2));
    if (p == null) return;
    if (s.isCollapsed) {
      _c.selection = TextSelection.fromPosition(p);
    } else if (start) {
      if (p.offset < s.end) _c.selection = TextSelection(baseOffset: p.offset, extentOffset: s.end);
    } else if (p.offset > s.start) {
      _c.selection = TextSelection(baseOffset: s.start, extentOffset: p.offset);
    }
  }

  /// Moves the handles to where the selection is now.
  void _keepMarks() {
    final h = _handles;
    if (h == null) return;
    final ends = _selectionEnds();
    if (ends == null) return;
    final s = _c.selection;
    h
      ..startHandleType = s.isCollapsed ? TextSelectionHandleType.collapsed : TextSelectionHandleType.left
      ..endHandleType = s.isCollapsed ? TextSelectionHandleType.collapsed : TextSelectionHandleType.right
      ..lineHeightAtStart = ends.start.height
      ..lineHeightAtEnd = ends.end.height
      ..selectionEndpoints = _endpoints(ends);
    _startVisible.value = !s.isCollapsed;
    _endVisible.value = true;
  }

  /// Takes the handles and the menu away.
  void _hideMarks() {
    _hideMenu();
    _handles?.dispose();
    _handles = null;
  }
}
