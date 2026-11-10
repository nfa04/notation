part of 'block_editor.dart';

/// The kinds of picture a keyboard may hand to the document (stickers, GIFs, pictures from its clipboard). Others are left to the keyboard
/// to turn away.
const List<String> blockContentTypes = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

/// The cursor that floats over the text while a finger moves over the space bar of the iOS keyboard.
class _Floating {
  /// Where the finger was when it began, as the keyboard counts (the screen).
  final Offset origin;

  /// The middle of the caret then, in the box of the lines.
  final Offset from;

  /// The cursor that follows the finger, in the box of the lines.
  Rect rect;

  /// The place the caret goes to when the finger lets go.
  TextPosition at;

  _Floating(this.origin, this.from, this.rect, this.at);
}

/// The editor of the document, for the handwriting of iPadOS ("Scribble"): it is told which text the pen may write on.
class _BlockScribble implements ScribbleClient {
  static int _next = 1;

  final BlockEditorState editor;

  @override
  final String elementIdentifier = 'block-editor-${_next++}';

  _BlockScribble(this.editor);

  @override
  void onScribbleFocus(Offset offset) => editor._scribbleFocus(offset);

  @override
  bool isInScribbleRect(Rect rect) => editor._scribbleOver(rect);

  @override
  Rect get bounds => editor._scribbleBounds;
}

/// What the system gives a keyboard besides keys: the floating cursor of iOS, handwriting with a pen (iPadOS, and Android 13 and up), and
/// pictures a keyboard puts in (stickers, GIFs).
extension _BlockInput on BlockEditorState {
  // ---- the floating cursor

  /// How many pixels of the screen make a pixel of the lines (the page can be zoomed).
  double _screenScale() {
    final column = _column;
    if (column == null || !column.attached) return 1;
    final t = column.getTransformTo(null);
    final s = (MatrixUtils.transformPoint(t, const Offset(1, 0)) - MatrixUtils.transformPoint(t, Offset.zero)).distance;
    return s > 0 ? s : 1;
  }

  /// A finger on the space bar of the iOS keyboard moves the cursor over the text: the cursor is drawn where the finger is, the caret
  /// where it would be put, and the selection goes there when the finger lets go. (Two fingers select: the keyboard changes the selection
  /// itself, which then stays.)
  void _floatCursor(RawFloatingCursorPoint point) {
    switch (point.state) {
      case FloatingCursorDragState.Start:
        final caret = _caretRect;
        if (caret == null || !_editable) return;
        _hideMarks();
        _floating = _Floating(point.offset ?? Offset.zero, caret.center, caret, TextPosition(offset: _extent, affinity: _c.selection.isValid ? _c.selection.affinity : TextAffinity.downstream));
        _caretTick.value++;
      case FloatingCursorDragState.Update:
        final f = _floating, column = _column, at = point.offset;
        if (f == null || column == null || !column.attached || !column.hasSize || at == null) return;
        var centre = f.from + (at - f.origin) / _screenScale();
        centre = Offset(centre.dx.clamp(0.0, _textWidth), centre.dy.clamp(0.0, math.max(0.0, _lines.height)));
        f.rect = Rect.fromCenter(center: centre, width: f.rect.width, height: f.rect.height);
        final place = _positionAt(column.localToGlobal(centre));
        if (place != null) f.at = place;
        // (near the edge of the screen the text goes along: the finger cannot reach further than the keyboard)
        final target = _rectAt(f.at.offset, affinity: f.at.affinity), seen = _visible();
        if (target != null && seen != null && (target.top < seen.top || target.bottom > seen.bottom)) column.showOnScreen(rect: target.inflate(8));
        _caretTick.value++;
      case FloatingCursorDragState.End:
        final f = _floating;
        _floating = null;
        if (f != null && (!_c.selection.isValid || _c.selection.isCollapsed)) {
          _goalX = null;
          _c.selection = TextSelection.fromPosition(f.at);
        }
        _caretTick.value++;
    }
  }

  // ---- handwriting on iPadOS

  /// The box of the document on the screen: where a pen may write.
  Rect get _scribbleBounds {
    final box = context.findRenderObject();
    if (!mounted || box is! RenderBox || !box.attached || !box.hasSize) return Rect.zero;
    return MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
  }

  /// Whether the pen writes on the document at [rect], a place on the screen: it is written, and it is not under something else.
  bool _scribbleOver(Rect rect) {
    if (!_editable) return false;
    final bounds = _scribbleBounds;
    if (bounds == Rect.zero || !bounds.overlaps(rect)) return false;
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, bounds.intersect(rect).center, View.of(context).viewId);
    final mine = context.findRenderObject();
    return hit.path.any((entry) => identical(entry.target, mine));
  }

  /// The pen began writing at [offset] (a place on the screen): the document takes the focus, and the caret goes there.
  void _scribbleFocus(Offset offset) {
    if (!_editable) return;
    widget.focusNode.requestFocus();
    _placeCaret(offset);
    _sendRectsSoon(at: Duration.zero);
  }

  /// Tells iPadOS where the letters of the text the keyboard knows are, so that it can tell what the pen does: a word crossed out is
  /// deleted, a line drawn between two letters opens room, a circle selects. (Only what is on the screen.)
  void _sendRects() {
    _rectsTimer = null;
    if (!_inputOpen || !_windowSet || defaultTargetPlatform != TargetPlatform.iOS || _lines.length == 0) return;
    final text = _c.text;
    final from = _windowFrom, to = text.length - _windowTail;
    if (from >= to) return;
    final seen = _visible();
    final rects = <SelectionRect>[];
    for (var i = _lines.lineAt(from); i <= _lines.lineAt(to) && i < _lines.length; i++) {
      final r = _renderOf(i);
      if (r == null) continue;
      final top = _lines.topOf(i);
      if (seen != null && (top > seen.bottom || top + r.size.height < seen.top)) continue;
      final b = _lines.blocks[i];
      final line = _lines.lines[i];
      var at = math.max(b.start, from);
      final end = math.min(b.end, to);
      for (final letter in text.substring(at, end).characters) {
        final next = at + letter.length;
        final boxes = r.boxes(TextRange(start: at - b.start, end: next - b.start));
        if (boxes.isNotEmpty) {
          final box = boxes.first;
          final rect = box.toRect().shift(Offset(0, top + line.shift(box.top)));
          if (seen == null || rect.bottom >= seen.top && rect.top <= seen.bottom) rects.add(SelectionRect(position: at - from, bounds: rect, direction: box.direction));
        }
        at = next;
      }
    }
    if (listEquals(rects, _rectsSent)) return;
    _rectsSent = rects;
    _input!.setSelectionRects(rects);
  }

  /// Once the text, the window of the keyboard or the scrolling stopped changing for a moment.
  void _sendRectsSoon({Duration at = const Duration(milliseconds: 250)}) {
    if (!_inputOpen || defaultTargetPlatform != TargetPlatform.iOS) return;
    _rectsTimer?.cancel();
    // (after the frame: text that was just typed is laid out in it, and the letters are asked of the layout)
    _rectsTimer = Timer(at, () {
      if (!mounted) return;
      SchedulerBinding.instance
        ..addPostFrameCallback((_) {
          if (mounted) _sendRects();
        })
        ..ensureVisualUpdate();
    });
  }

  // ---- handwriting on Android

  /// A pen touches the document: where it does the caret goes, the keyboard connection is there, and the keyboard is asked to take
  /// the handwriting (Android 13 and up, where it has a recogniser). What it reads comes as text like any key.
  void _startHandwriting(Offset global) {
    if (defaultTargetPlatform != TargetPlatform.android || !_editable) return;
    _placeCaret(global);
    _focus();
    unawaited(_handwriting());
  }

  Future<void> _handwriting() async {
    try {
      if (!await Scribe.isFeatureAvailable() || !mounted) return;
      // (the connection to the keyboard is made once the focus is there)
      if (!_inputOpen) await WidgetsBinding.instance.endOfFrame;
      if (mounted && _inputOpen) await Scribe.startStylusHandwriting();
    } catch (e) {
      debugPrint('starting the handwriting failed: $e');
    }
  }

  // ---- pictures from the keyboard

  void _contentFromKeyboard(KeyboardInsertedContent content) {
    final take = widget.onContent;
    if (take == null || !_editable) return;
    unawaited(take(content));
  }
}

/// The gestures of a pen on text (see [recognizePenGesture]): the pen is followed while it draws, and when it lifts what it drew is looked at.
/// Where the system does this itself (Scribble on iPadOS, the handwriting of the keyboard on Android) the pen never reaches here to the end:
/// the stroke is taken over, and cancelled. What is not a gesture stays what it was: a drag selects.
extension _BlockPen on BlockEditorState {
  Widget _penGestures(Widget child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _penDown,
        onPointerMove: _penMove,
        onPointerUp: _penUp,
        onPointerCancel: (e) {
          if (e.pointer == _penPointer) _penPointer = null;
        },
        child: child,
      );

  void _penDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.stylus || !_editable) return;
    _pen
      ..clear()
      ..add(e.position);
    _penPointer = e.pointer;
  }

  void _penMove(PointerMoveEvent e) {
    if (e.pointer != _penPointer || _pen.length > 2000) return;
    _pen.add(e.position);
  }

  void _penUp(PointerUpEvent e) {
    if (e.pointer != _penPointer) return;
    _penPointer = null;
    final path = [..._pen, e.position];
    _pen.clear();
    // (after the drag has ended: the selection it made is what the gesture then changes)
    scheduleMicrotask(() {
      if (mounted) _penDone(path);
    });
  }

  void _penDone(List<Offset> path) {
    if (!_editable || _lines.length == 0) return;
    final middle = _positionAt(path[path.length ~/ 2]);
    final rect = middle == null ? null : _rectAt(middle.offset);
    final gesture = recognizePenGesture(path, (rect?.height ?? 24) * _screenScale());
    if (gesture == null) return;
    final done = switch (gesture.kind) {
      PenGestureKind.scratchOut => _penScratch(gesture.box),
      PenGestureKind.circle => _penCircle(gesture.box),
      PenGestureKind.splitOrJoin => _penSpace(gesture.box),
    };
    if (done) HapticFeedback.selectionClick();
  }

  static final RegExp _wordChar = RegExp(r"[\p{L}\p{N}_'\u2019]", unicode: true);

  static bool _isWordChar(String text, int at) => at >= 0 && at < text.length && _wordChar.hasMatch(text[at]);

  /// The text between [a] and [b] with the words it cuts through whole (words stay inside their line).
  TextRange _wholeWords(int a, int b) {
    final text = _c.text;
    var from = math.min(a, b), to = math.max(a, b);
    final first = _lineOf(from).start, last = _lineOf(to).end;
    while (from > first && _isWordChar(text, from - 1) && _isWordChar(text, from)) {
      from--;
    }
    while (to < last && _isWordChar(text, to) && _isWordChar(text, to - 1)) {
      to++;
    }
    return TextRange(start: from, end: to);
  }

  /// The place of the text under the left and the right edge of [box], at its middle (the top and the bottom for a loop of several lines),
  /// and whether the text is where the pen was (the pen did not write on empty paper).
  ({TextRange words, bool onText})? _under(Rect box, {bool lines = false}) {
    final high = box.height > (_caretRect?.height ?? 24) * _screenScale() * 1.6;
    final half = (_caretRect?.height ?? 24) * _screenScale() / 2;
    final a = _positionAt(Offset(box.left, high && lines ? box.top + half : box.center.dy));
    final b = _positionAt(Offset(box.right, high && lines ? box.bottom - half : box.center.dy));
    if (a == null || b == null) return null;
    final words = _wholeWords(a.offset, b.offset);
    if (words.isCollapsed) return null;
    final shown = screenRectOf(TextRange(start: math.min(a.offset, b.offset), end: math.max(a.offset, b.offset)));
    final over = shown?.intersect(box);
    return (words: words, onText: over != null && over.width >= box.width * 0.5 && over.height > 0);
  }

  /// A zigzag over words deletes them, and a space with them where one would be left twice.
  bool _penScratch(Rect box) {
    final under = _under(box);
    if (under == null || !under.onText) return false;
    final text = _c.text;
    var from = under.words.start, to = under.words.end;
    if (to < text.length && text[to] == ' ' && (from == 0 || text[from - 1] == ' ' || text[from - 1] == '\n')) {
      to++;
    } else if (from > 0 && text[from - 1] == ' ' && (to == text.length || text[to] == '\n' || text[to] == ' ')) {
      from--;
    }
    _hideMarks();
    _typed(() => _c.value = TextEditingValue(text: text.replaceRange(from, to, ''), selection: TextSelection.collapsed(offset: from)));
    _focus();
    return true;
  }

  /// A loop round words selects them.
  bool _penCircle(Rect box) {
    final under = _under(box, lines: true);
    if (under == null || !under.onText) return false;
    _goalX = null;
    _c.selection = TextSelection(baseOffset: under.words.start, extentOffset: under.words.end);
    _focus();
    _showHandles();
    return true;
  }

  /// A stroke down between two letters of a word makes it two; down on a space, it joins the two.
  bool _penSpace(Rect box) {
    final column = _column;
    final p = _positionAt(box.center);
    if (column == null || !column.attached || p == null) return false;
    final at = p.offset;
    final shown = _rectAt(at);
    if (shown == null) return false;
    final close = column.localToGlobal(shown.center);
    final reach = shown.height * _screenScale();
    if ((close.dx - box.center.dx).abs() > reach * 0.8 || (close.dy - box.center.dy).abs() > reach) return false;
    final text = _c.text;
    final before = at > 0 ? text[at - 1] : '\n', after = at < text.length ? text[at] : '\n';
    if (before == '\n' || after == '\n') return false;
    _hideMarks();
    if (before != ' ' && after != ' ') {
      _typed(() => _c.value = TextEditingValue(text: text.replaceRange(at, at, ' '), selection: TextSelection.collapsed(offset: at + 1)));
    } else {
      final gone = before == ' ' ? at - 1 : at;
      if (gone > 0 && text[gone - 1] == '\n' || gone + 1 < text.length && text[gone + 1] == '\n') return false;
      _typed(() => _c.value = TextEditingValue(text: text.replaceRange(gone, gone + 1, ''), selection: TextSelection.collapsed(offset: gone)));
    }
    _focus();
    return true;
  }
}
