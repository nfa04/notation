import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../l10n/language.dart' show tr;
import '../markdown/live_markdown.dart';
import '../markdown/markdown_parser.dart';
import '../models/rich_text.dart';
import 'block_column.dart';
import 'document_lines.dart';
import 'pen_gesture.dart';

part 'block_gestures.dart';
part 'block_input.dart';
part 'block_marks.dart';
part 'block_moves.dart';

/// What a menu on the document is made from (see [BlockEditor.menuBuilder]).
class BlockMenu {
  final BuildContext context;
  final List<ContextMenuButtonItem> items;
  final TextEditingValue value;
  final VoidCallback hide;
  final TextSelectionToolbarAnchors anchors;

  const BlockMenu({required this.context, required this.items, required this.value, required this.hide, required this.anchors});
}

typedef BlockMenuBuilder = Widget Function(BuildContext context, BlockMenu menu);

/// The written document, written line by line: every line ([DocumentLine]) is a paragraph of its own and only those around the screen
/// exist, with one caret and one selection over all of them, which are those of the [controller]. A text field lays out all of its
/// text with each key, which no phone or old tablet does in time with a long document; here a key costs one line, wherever it is and
/// however long the document is.
class BlockEditor extends StatefulWidget {
  final LiveMarkdownController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final double width;
  final bool autofocus;
  final String? hint;

  /// Pastes what is on the clipboard (formatted text is more than this editor knows of).
  final Future<void> Function()? onPaste;

  /// The menu on the text; null: the usual one.
  final BlockMenuBuilder? menuBuilder;

  /// The handles of a selection on a touch screen.
  final TextSelectionControls? selectionControls;

  /// Called when the document got taller or shorter.
  final VoidCallback? onShape;

  /// Goes up when what the lines know of each other changes.
  final ValueNotifier<int>? othersChanged;

  /// Told how far down the text what is built goes: from where to where.
  final ValueNotifier<(double, double)>? nearby;

  /// The sheets of paper the text is on (null: one long sheet).
  final ({double room, double step})? sheets;

  /// Takes a picture the keyboard puts in (a sticker, a GIF; see [blockContentTypes]); null: the keyboard is not asked for any.
  final Future<void> Function(KeyboardInsertedContent content)? onContent;

  const BlockEditor({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.width,
    this.autofocus = false,
    this.hint,
    this.onPaste,
    this.menuBuilder,
    this.selectionControls,
    this.onShape,
    this.othersChanged,
    this.nearby,
    this.sheets,
    this.onContent,
  });

  @override
  State<BlockEditor> createState() => BlockEditorState();
}

/// How much text around the caret the keyboard is told of, either way. It needs some to complete words and to delete across lines;
/// telling it all of the document costs a key what the document is long.
const int _imeRoom = 1024;

class BlockEditorState extends State<BlockEditor> with TextInputClient, DeltaTextInputClient, WidgetsBindingObserver {
  LiveMarkdownController get _c => widget.controller;
  late final DocumentLines _lines = DocumentLines(_estimate)
    ..sheets = widget.sheets
    ..rowHeight = (widget.style.fontSize ?? 16) * (widget.style.height ?? 1.5);

  /// What is built of each line that is, by the line's id.
  final Map<int, _BlockItemState> _items = {};
  final Map<int, RenderBlockLine> _renders = {};
  final Map<int, _BlockItem> _built = {};

  /// The lines around the screen that are built, `[_first, _last]`.
  int _first = 0, _last = -1;

  /// The line at the top of the screen (see [BlockColumn.anchor]).
  int _anchor = 0;

  /// Lines that are only being measured, off the screen.
  Set<int> _measuring = const {};
  Timer? _measureTimer;

  final GlobalKey _columnKey = GlobalKey();
  RenderBlockColumn? get _column => _columnKey.currentContext?.findRenderObject() as RenderBlockColumn?;

  ScrollPosition? _position;

  /// Whether what the blocks know of each other is to be looked at again after this frame, and how far they are.
  bool _factsDue = false;
  _Numbers _numbers = const _Numbers();
  int _numbersVersion = 0, _stylesVersion = 0;

  bool get _editable => !_c.readingView;
  late bool _wasEditable = _editable;

  double get _textWidth => LiveMarkdownView.textWidth(widget.width);

  double _estimate(MdBlock b) {
    final size = widget.style.fontSize ?? 16;
    final height = size * (widget.style.height ?? 1.5);
    final length = b.end - b.start;
    final perLine = math.max(10.0, _textWidth / (size * 0.5));
    return switch (b.type) {
      MdBlockType.heading => height * headingScale(b.level),
      MdBlockType.table => height * 1.6 * ('\n'.allMatches(_c.text.substring(b.start, b.end)).length),
      MdBlockType.code => height * 0.95 * ('\n'.allMatches(b.code).length + 1) + height,
      MdBlockType.math => height * 2.5,
      _ => height * math.max(1, (length / perLine).ceil()),
    };
  }

  // ---- following the text

  @override
  void initState() {
    super.initState();
    _lines.update(parsedText(_c));
    _numbers = _Numbers.of(_lines.blocks);
    _first = 0;
    _last = math.min(_lines.length - 1, 80);
    _c.addListener(_changed);
    widget.focusNode.addListener(_focusChanged);
    WidgetsBinding.instance.addObserver(this);
    TextInput.registerScribbleElement(_scribble.elementIdentifier, _scribble);
    _caretWas = (_c.text, _c.selection);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _laidOutAt = _position != null && _position!.hasPixels ? _position!.pixels : null;
      _lookAround();
      _measureSoon();
      if (widget.focusNode.hasFocus) _focusChanged();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_scrolled);
      _position = position?..addListener(_scrolled);
    }
  }

  @override
  void didUpdateWidget(BlockEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (!identical(old.focusNode, widget.focusNode)) {
      old.focusNode.removeListener(_focusChanged);
      widget.focusNode.addListener(_focusChanged);
    }
    if (!identical(old.nearby, widget.nearby)) {
      // (a new one starts with a guess: it is told what is built, which it would otherwise only hear once that changes)
      final told = _told, nearby = widget.nearby;
      // (after the build: its listeners are not to be built again in the middle of it)
      if (told != null && nearby != null) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(widget.nearby, nearby)) nearby.value = _told ?? told;
        });
      }
    }
    if (old.sheets != widget.sheets) {
      _lines.setSheets(widget.sheets);
      _built.clear();
      _column?.markNeedsLayout();
    }
    if (old.width != widget.width || old.style != widget.style) {
      // (every line wraps differently now)
      for (final l in _lines.lines) {
        l.measured = false;
      }
      _built.clear();
      _measureSoon();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_changed);
    widget.focusNode.removeListener(_focusChanged);
    _position?.removeListener(_scrolled);
    _measureTimer?.cancel();
    _placeTimer?.cancel();
    _rectsTimer?.cancel();
    TextInput.unregisterScribbleElement(_scribble.elementIdentifier);
    _blink?.cancel();
    _closeInput();
    _hideMarks();
    _caretTick.dispose();
    _startVisible.dispose();
    _endVisible.dispose();
    super.dispose();
  }

  /// The keyboard came or went, or the window changed: the caret stays out from under the keyboard, and the menu with its text.
  @override
  void didChangeMetrics() {
    final keyboard = View.of(context).viewInsets.bottom;
    final grew = keyboard > _keyboard;
    _keyboard = keyboard;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (grew && widget.focusNode.hasFocus) _showCaret();
      _followMenu();
    });
  }

  double _keyboard = 0;

  void _changed() {
    _nearGood = false;
    final old = _lines.blocks;
    final change = _lines.update(parsedText(_c));
    final (text, selection) = _caretWas;
    // (what the controller says can be of no concern to the caret, a word found to be misspelled or a box ticked further down: the page
    // is not brought back to it)
    var moved = _typing && !identical(text, _c.text) || selection != _c.selection && !_movedByOthers(text, selection);
    if (moved || !identical(text, _c.text)) _goalX = null;
    _caretWas = (_c.text, _c.selection);
    if (_c.text.isEmpty != text.isEmpty) setState(() {}); // (the hint)
    if (_editable != _wasEditable) {
      moved = true;
      _wasEditable = _editable;
      if (_inputOpen) {
        _input!.updateConfig(_inputConfig);
      } else if (_editable && widget.focusNode.hasFocus) {
        _openInput();
      }
    }
    if (change != null) {
      if (!_factsDue && _concernsOthers(old, change)) {
        _factsDue = true;
        SchedulerBinding.instance.addPostFrameCallback((_) => _lookAtFacts());
      }
      if (!change.sameCount) {
        final by = change.end - change.oldEnd;
        if (_last >= change.first) _last = math.min(_lines.length - 1, math.max(change.first, _last + by));
        if (_first > change.first) _first = math.max(0, _first + by);
        _measuring = const {};
        setState(() {});
        // (lines that are gone leave room for lines that are not built)
        _watchFrame();
      }
    }
    final line = _lines.lines.isEmpty ? null : _caretLine;
    if (line != null && (line - 1 < _first || line + 1 > _last) && !_builtAll(line)) setState(() {});
    final base = _baseLine;
    if (base != null && !_built.containsKey(_lines.lines[base].id)) setState(() {});
    for (final item in _items.values) {
      item.refresh();
    }
    if (_menu.isShown && _c.selection != _menuFor) _hideMenu();
    if (moved) {
      _caretChanged();
    } else {
      _caretTick.value++;
    }
    _syncInput();
    _keepMarks();
    _measureSoon();
  }

  /// Whether the caret, which was at [was] in [old], only went along with a change elsewhere in the text (someone else writing).
  bool _movedByOthers(String old, TextSelection was) {
    final edit = _c.lastEdit;
    if (_typing || identical(old, _c.text) || !identical(edit.of, old) || !identical(edit.now, _c.text)) return false;
    return old.length - edit.tail < was.start || edit.start > was.end;
  }

  bool _builtAll(int line) {
    for (var i = math.max(0, line - 1); i <= math.min(_lines.length - 1, line + 1); i++) {
      if (!_built.containsKey(_lines.lines[i].id)) return false;
    }
    return true;
  }

  /// Whether a change may change what other lines show: numbers of footnotes and captions, cross-references, the styles, the contents.
  bool _concernsOthers(List<MdBlock> old, LineChange change) {
    bool concerns(MdBlock b) =>
        b.type == MdBlockType.footnote ||
        b.type == MdBlockType.caption ||
        b.type == MdBlockType.heading ||
        b.type == MdBlockType.setting ||
        b.markup.any((m) => m.kind == MdMarkupKind.anchor || m.kind == MdMarkupKind.footnote || m.kind == MdMarkupKind.cite);
    for (var i = change.first; i < change.oldEnd && i < old.length; i++) {
      if (concerns(old[i])) return true;
    }
    for (var i = change.first; i < change.end && i < _lines.blocks.length; i++) {
      if (concerns(_lines.blocks[i])) return true;
    }
    return false;
  }

  void _lookAtFacts() {
    _factsDue = false;
    if (!mounted) return;
    final now = _Numbers.of(_lines.blocks);
    final styles = !listEquals(now.styleLines, _numbers.styleLines);
    final numbers = !mapEquals(now.footnotes, _numbers.footnotes) || !mapEquals(now.references, _numbers.references) || !listEquals(now.captions, _numbers.captions) || !listEquals(now.contents, _numbers.contents) || !listEquals(now.cited, _numbers.cited);
    _numbers = now;
    if (styles) _stylesVersion++;
    if (numbers) _numbersVersion++;
    if (numbers) {
      final others = widget.othersChanged;
      if (others != null) others.value++;
    }
    if (styles || numbers) {
      for (final item in _items.values) {
        item.refresh();
      }
    }
  }

  /// What block [b] knows of the others.
  LiveFacts _factsFor(MdBlock b) {
    var caption = 0;
    if (b.type == MdBlockType.caption) {
      for (final o in _lines.blocks) {
        if (o.type == MdBlockType.caption && o.label == b.label) caption++;
        if (o.start >= b.start) break;
      }
    }
    return LiveFacts(_c.text, _lines.blocks, footnotes: _numbers.footnotes, styles: _numbers.styles, captions: {0: caption}, references: _numbers.references);
  }

  /// Whether block [b] shows something of the others.
  static bool _dependsOnOthers(MdBlock b) =>
      b.type == MdBlockType.toc ||
      b.type == MdBlockType.caption ||
      b.type == MdBlockType.footnote ||
      b.type == MdBlockType.bibliography ||
      b.markup.any((m) => m.kind == MdMarkupKind.footnote || m.kind == MdMarkupKind.ref || m.kind == MdMarkupKind.cite);

  // what of the marks of the text is near the screen: looked for once for a change, not once for each line
  bool _nearGood = false;
  int _nearFrom = 0, _nearTo = 0;
  List<TextSpanAttribute> _nearAttributes = const [];
  List<({int start, int end})> _nearWrong = const [], _nearFound = const [], _nearDoubtful = const [];

  void _gatherNear(int from, int to) {
    final c = _c;
    final blocks = _lines.blocks;
    var low = from, high = to;
    if (_first < blocks.length) low = math.min(low, blocks[_first].start);
    if (_last < blocks.length && _last >= 0) high = math.max(high, blocks[_last].end);
    _nearFrom = low;
    _nearTo = high;
    bool near(int start, int end) => end > low && start < high;
    _nearAttributes = [
      for (final a in c.attributes)
        if (near(a.start, a.end)) a,
    ];
    _nearFound = [
      for (final r in c.found)
        if (near(r.start, r.end)) r,
    ];
    _nearWrong = [
      for (final r in c.misspelled)
        if (near(r.start, r.end)) (start: r.start, end: r.end),
    ];
    _nearDoubtful = [
      if (c.checkGrammar)
        for (final g in c.grammar)
          if (near(g.start, g.end)) (start: g.start, end: g.end),
    ];
    _nearGood = true;
  }

  /// How line [line] is to look: when that is what it was, it is left alone.
  _Look? _lookOf(DocumentLine line) {
    if (line.index >= _lines.length || !identical(_lines.lines[line.index], line)) return null;
    final b = _lines.blocks[line.index];
    final from = b.start, to = b.end;
    if (!_nearGood || from < _nearFrom || to > _nearTo) _gatherNear(from, to);
    final c = _c;
    final attributes = <TextSpanAttribute>[];
    for (final a in _nearAttributes) {
      if (a.end > from && a.start < to) attributes.add(a.moved(math.max(a.start, from) - from, math.min(a.end, to) - from));
    }
    List<({int start, int end})> local(List<({int start, int end})> ranges) => ranges.isEmpty
        ? const []
        : [
            for (final r in ranges)
              if (r.end > from && r.start < to) (start: math.max(r.start, from) - from, end: math.min(r.end, to) - from),
          ];
    final found = local(_nearFound);
    var foundNow = -1;
    if (c.foundNow >= 0 && c.foundNow < c.found.length) {
      final now = c.found[c.foundNow];
      if (now.end > from && now.start < to) foundNow = found.indexWhere((r) => r.start == math.max(now.start, from) - from);
    }
    return _Look(
      version: line.version,
      styles: _stylesVersion,
      numbers: (line.dependsOnOthers ??= _dependsOnOthers(b)) ? _numbersVersion : 0,
      attributes: attributes,
      misspelled: local(_nearWrong),
      found: found,
      foundNow: foundNow,
      grammar: local(_nearDoubtful),
      reveal: _revealOf(from, to),
      focusMode: c.focusMode,
    );
  }

  /// The selection as the line `[from, to]` of the text sees it: what it touches shows its Markdown (see [liveBlockSpan]).
  TextSelection? _revealOf(int from, int to) {
    final c = _c;
    if (!c.revealing || c.readingView) return null;
    final s = c.selection;
    if (!s.isValid) return null;
    if (s.start > to || s.end < from) return c.focusMode ? TextSelection.collapsed(offset: to - from + 5) : null;
    return TextSelection(baseOffset: s.baseOffset.clamp(from, to) - from, extentOffset: s.extentOffset.clamp(from, to) - from);
  }

  /// What is selected of the line `[from, to]`.
  ({TextRange? range, bool on}) _selectedOf(int from, int to) {
    final s = _c.selection;
    if (!s.isValid || s.isCollapsed || s.start > to || s.end < from) return const (range: null, on: false);
    return (range: TextRange(start: math.max(s.start, from) - from, end: math.min(s.end, to) - from), on: s.end > to);
  }

  // ---- what others ask of it

  /// How many times a line was made anew (for the tests of what a key costs).
  @visibleForTesting
  int debugBuilds = 0;

  /// Whether every line was laid out once.
  bool get allMeasured => _lines.firstUnmeasured(0) == null;

  /// Each line that is built, by its id, and how far down the screen it is.
  @visibleForTesting
  List<(int, double)> linesOnScreen() => [
        for (final e in _renders.entries)
          if (e.value.attached && e.value.hasSize) (e.key, e.value.localToGlobal(Offset.zero).dy),
      ];

  /// Where the caret is on the screen; null: its line is not built.
  @visibleForTesting
  Rect? get screenCaret {
    final rect = _caretRect, column = _column;
    if (rect == null || column == null) return null;
    return Rect.fromPoints(column.localToGlobal(rect.topLeft), column.localToGlobal(rect.bottomRight));
  }

  /// Opens the menu on the selection.
  @visibleForTesting
  void debugShowMenu() => _showMenu();

  /// How tall the text is, as far as it is known.
  double get documentHeight => _lines.height;

  /// How many sheets of paper the text is on, as far as it is known.
  int get sheetCount => _lines.sheetCount;

  /// Puts the caret at [offset] and scrolls so that its line is at the top of the screen (the entries of the table of contents).
  void goTo(int offset) {
    if (_lines.length == 0) return;
    _c.selection = TextSelection.collapsed(offset: offset.clamp(0, _c.text.length));
    show(offset);
  }

  /// Scrolls so that the line of the place [offset] of the text is [above] below the top of the screen (the screen pixels of what is
  /// over it).
  void show(int offset, {double above = 8}) {
    if (_lines.length == 0) return;
    final at = offset.clamp(0, _c.text.length);
    void scroll() {
      final column = _column, position = _position, seen = _visible();
      if (!mounted || column == null || seen == null || position == null || !position.hasPixels) return;
      final view = position.context.notificationContext?.findRenderObject();
      if (view is! RenderBox) return;
      final scale = _scaleIn(column, view);
      if (scale <= 0) return;
      final line = _lines.lineAt(at);
      final to = position.pixels + (_lines.topOf(line) - seen.top) * scale - above;
      position.jumpTo(to.clamp(position.minScrollExtent, position.maxScrollExtent));
    }

    scroll();
    // (the lines on the way were only guessed at until they were built: once they are, the place is a little elsewhere)
    SchedulerBinding.instance.addPostFrameCallback((_) => scroll());
  }

  /// Where the stretch [range] of the text is on the screen; null: it is not built.
  Rect? screenRectOf(TextRange range) {
    final column = _column;
    final i = _lines.lineAt(range.start);
    final r = _renderOf(i);
    if (column == null || r == null) return null;
    final b = _lines.blocks[i];
    final boxes = r.boxes(TextRange(start: range.start - b.start, end: math.min(range.end, b.end) - b.start));
    if (boxes.isEmpty) return null;
    final line = boxes.map((x) => x.toRect()).reduce((a, x) => a.expandToInclude(x));
    final rect = line.shift(Offset(0, _lines.topOf(i) + _lines.lines[i].shift(line.top)));
    return Rect.fromPoints(column.localToGlobal(rect.topLeft), column.localToGlobal(rect.bottomRight));
  }

  void _shapeChanged() {
    if (_shapeDue) return;
    _shapeDue = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _shapeDue = false;
      if (mounted) widget.onShape?.call();
    });
  }

  bool _shapeDue = false;

  // ---- which lines exist

  /// How far the list was scrolled when it was last laid out: where the box of the lines is on screen says that much, until the next
  /// layout, whatever the scrolling is at by now.
  double? _laidOutAt;
  bool _frameWatched = false;

  void _watchFrame() {
    if (_frameWatched) return;
    _frameWatched = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _frameWatched = false;
      if (mounted) pageResized();
    });
  }

  /// What is on screen is to be looked at again: the layout is new. That is after a frame, and when the page around the lines has been
  /// laid out at another size, which moves them on screen without anything telling them.
  void pageResized() {
    final position = _position;
    _laidOutAt = position != null && position.hasPixels ? position.pixels : null;
    _lookAround();
    _followMenu();
  }

  double _scaleIn(RenderBox column, RenderBox view) {
    final toView = column.getTransformTo(view);
    return (MatrixUtils.transformPoint(toView, const Offset(0, 1)) - MatrixUtils.transformPoint(toView, Offset.zero)).distance;
  }

  /// What is on screen, in the box of the lines; null: there is no scrolling here, all of it is.
  Rect? _visible() {
    final column = _column;
    final position = _position;
    if (column == null || !column.attached || !column.hasSize || position == null) return null;
    final view = position.context.notificationContext?.findRenderObject();
    if (view is! RenderBox || !view.hasSize || !view.attached) return null;
    final seen = MatrixUtils.inverseTransformRect(column.getTransformTo(view), Offset.zero & view.size);
    final was = _laidOutAt;
    if (was == null || !position.hasPixels || position.pixels == was) return seen;
    final scale = _scaleIn(column, view);
    return scale > 0 ? seen.shift(Offset(0, (position.pixels - was) / scale)) : seen;
  }

  void _scrolled() {
    _watchFrame();
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) _lookAround();
    _keepMarks();
    _sendRectsSoon();
  }

  /// Builds what came near the screen, drops what went away from it.
  void _lookAround() {
    if (!mounted || _lines.length == 0) return;
    final seen = _visible();
    if (seen == null) {
      if (_position != null) return; // (not laid out yet)
      if (_first != 0 || _last != _lines.length - 1) {
        setState(() {
          _first = 0;
          _last = _lines.length - 1;
        });
      }
      _tell( (0, double.infinity));
      return;
    }
    // (half a screen either way: every line that exists costs each key a look and each frame a layer)
    final room = seen.height / 2;
    _anchor = _lines.lineAtY(seen.top);
    if (_lines.lineAtY(seen.top - room / 2) >= _first && _lines.lineAtY(seen.bottom + room / 2) <= _last) return;
    setState(() {
      _first = _lines.lineAtY(seen.top - room);
      _last = _lines.lineAtY(seen.bottom + room);
    });
    _tell( (seen.top - room, seen.bottom + room));
  }

  /// What [BlockEditor.nearby] was last told.
  (double, double)? _told;

  void _tell((double, double) range) {
    _told = range;
    widget.nearby?.value = range;
  }

  // lines above the screen that turned out another height than was thought (see [BlockColumn.anchor])
  final Map<DocumentLine, double> _heightsAbove = {};

  void _heightAbove(DocumentLine line, double height) {
    if (_heightsAbove.isEmpty) SchedulerBinding.instance.addPostFrameCallback((_) => _applyHeightsAbove());
    _heightsAbove[line] = height;
  }

  void _applyHeightsAbove() {
    final column = _column, position = _position;
    final anchor = math.min(_anchor, _lines.length - 1);
    final before = _lines.length == 0 ? 0.0 : _lines.topOf(anchor);
    for (final e in _heightsAbove.entries) {
      if (e.key.index < _lines.length && identical(_lines.lines[e.key.index], e.key)) _lines.setHeight(e.key, e.value);
    }
    _heightsAbove.clear();
    if (!mounted || _lines.length == 0 || column == null || position == null || !position.hasPixels) return;
    final above = _lines.topOf(anchor) - before;
    final view = position.context.notificationContext?.findRenderObject();
    if (above == 0 || view is! RenderBox) return;
    position.correctBy(above * _scaleIn(column, view));
    column.markNeedsLayout();
    _watchFrame();
  }

  void _measureSoon() {
    _measureTimer?.cancel();
    _measureTimer = Timer(const Duration(milliseconds: 300), _measureSome);
  }

  /// Lays out some of the lines that never were, a few to a frame, while nothing else happens: where the pages end and how long the
  /// scrollbar is come from these, and until then they are estimates.
  void _measureSome() {
    if (!mounted) return;
    final from = math.min(_last + 1, _lines.length);
    final next = _lines.firstUnmeasured(from);
    if (next == null) {
      if (_measuring.isNotEmpty) setState(() => _measuring = const {});
      return;
    }
    setState(() {
      _measuring = {for (var i = next; i < _lines.length && i < next + _measureBatch; i++) i};
    });
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // (as many as take a few milliseconds of a frame, whatever this machine is)
      final took = _measureClock.elapsedMicroseconds;
      _measureClock.reset();
      if (took > 0) _measureBatch = (_measureBatch * (took < 3000 ? 2 : (took > 8000 ? 0.5 : 1))).round().clamp(4, 400);
      _measureTimer?.cancel();
      _measureTimer = Timer(const Duration(milliseconds: 4), _measureSome);
    });
  }

  /// Runs from the build of a frame that measures to its end.
  final Stopwatch _measureClock = Stopwatch();

  int _measureBatch = 16;

  // ---- pointers and keys

  /// How far left a caret going up or down wants to be.
  double? _goalX;
  int? _dragBase;
  PointerDeviceKind? _dragKind;

  /// The word a long press started on.
  TextRange? _pressedWord;
  Offset? _downAt;
  final ContextMenuController _menu = ContextMenuController();

  /// Whether there is text to paste, as far as it is known.
  bool _canPaste = true;

  /// The selection the menu was opened on, and where it was clicked open (null: it is on the selection).
  TextSelection? _menuFor;
  Offset? _menuAt;
  SelectionOverlay? _handles;
  final LayerLink _startLink = LayerLink(), _endLink = LayerLink(), _toolbarLink = LayerLink();
  final ValueNotifier<bool> _startVisible = ValueNotifier(false), _endVisible = ValueNotifier(true);
  late final _NoSelectionDelegate _handleDelegate = _NoSelectionDelegate(this);
  late final Map<Type, Action<Intent>> _actions = _makeActions();

  // ---- the caret

  final ValueNotifier<int> _caretTick = ValueNotifier(0);
  bool _caretOn = true;
  Timer? _blink;
  bool _wantCaretSeen = false;

  /// While a change comes from the keyboard: the caret stays on screen, also when it stayed where it is (Delete).
  bool _typing = false;

  void _typed(VoidCallback change) {
    _typing = true;
    try {
      change();
    } finally {
      _typing = false;
    }
  }

  late (String, TextSelection) _caretWas;

  int get _extent {
    final s = _c.selection;
    return s.isValid ? math.min(s.extentOffset, _c.text.length) : _c.text.length;
  }

  int get _caretLine => _lines.lineAt(_extent);

  /// The line the other end of the selection is on: it stays built, wherever it is, for the handle and the menu that go by it.
  int? get _baseLine {
    final s = _c.selection;
    return s.isValid && !s.isCollapsed && _lines.length > 0 ? _lines.lineAt(math.min(s.baseOffset, _c.text.length)) : null;
  }

  bool get _caretShown => widget.focusNode.hasFocus && _editable && _c.selection.isValid && _c.selection.isCollapsed;

  bool _holdsCaret(DocumentLine line) => line.index == _caretLine && _c.selection.isValid;

  void _goToLine(int index) {
    _setSelection(TextSelection.collapsed(offset: _lines.blocks[index].end));
    widget.focusNode.requestFocus();
  }

  void _tappedOutside(PointerDownEvent event) {
    _hideMenu();
    if (!widget.focusNode.hasFocus) return;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia:
        // (a finger scrolls too: only a mouse or a pen elsewhere ends the writing)
        if (event.kind != PointerDeviceKind.touch && event.kind != PointerDeviceKind.trackpad) widget.focusNode.unfocus();
      case TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows:
        widget.focusNode.unfocus();
    }
  }

  /// The render object of line [index], when it is built and laid out.
  RenderBlockLine? _renderOf(int index) {
    final r = _renders[_lines.lines[index].id];
    return r != null && r.attached && r.hasSize ? r : null;
  }

  /// Where a caret at [offset] of the text is, in the box of the lines.
  Rect? _rectAt(int offset, {TextAffinity affinity = TextAffinity.downstream}) {
    if (_lines.length == 0) return null;
    final i = _lines.lineAt(offset);
    final r = _renderOf(i);
    if (r == null) return null;
    final at = offset - _lines.blocks[i].start;
    final rect = r.caretRect(TextPosition(offset: at, affinity: affinity));
    return rect.shift(Offset(0, _lines.topOf(i) + _lines.lines[i].shift(rect.top)));
  }

  Rect? get _caretRect => _rectAt(_extent, affinity: _c.selection.isValid ? _c.selection.affinity : TextAffinity.downstream);

  void _caretChanged() {
    _caretOn = true;
    _caretTick.value++;
    _blink?.cancel();
    _blink = _caretShown
        ? Timer.periodic(const Duration(milliseconds: 500), (_) {
            _caretOn = !_caretOn;
            _caretTick.value++;
          })
        : null;
    if (widget.focusNode.hasFocus && !_wantCaretSeen) {
      _wantCaretSeen = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => _showCaret());
    }
  }

  void _showCaret() {
    _wantCaretSeen = false;
    if (!mounted) return;
    final rect = _caretRect, column = _column;
    // (with no selection there is no caret to show: the whole text was replaced, by an undo or a newer copy)
    if (rect == null || column == null || !column.attached || !column.hasSize || !_c.selection.isValid) return;
    // the part that is on screen already moves nothing
    final seen = _visible();
    if (seen != null && (rect.top < seen.top || rect.bottom > seen.bottom)) column.showOnScreen(rect: rect.inflate(8));
    _sendPlaceSoon();
  }

  /// A word being composed has its list of choices beside it, at once; else where the caret is can wait until the typing stops.
  void _sendPlaceSoon() {
    if (_c.value.composing.isValid && !_c.value.composing.isCollapsed) return _sendPlace();
    _placeTimer?.cancel();
    _placeTimer = Timer(const Duration(milliseconds: 120), () {
      if (mounted) _sendPlace();
    });
  }

  Timer? _placeTimer;

  void _focusChanged() {
    final focused = widget.focusNode.hasFocus;
    if (focused) {
      if (!_c.selection.isValid) _c.selection = TextSelection.collapsed(offset: _c.text.length);
      _openInput();
    } else {
      _closeInput();
      _hideMarks();
    }
    _caretChanged();
    for (final item in _items.values) {
      item.refresh();
    }
  }

  // ---- the keyboard's side of it

  TextInputConnection? _input;

  /// The cursor floating over the text, while a finger is on the space bar of the iOS keyboard (see block_input.dart).
  _Floating? _floating;

  /// The editor as the pen of an iPad finds it (see block_input.dart), and where the letters were last told to the system.
  late final _BlockScribble _scribble = _BlockScribble(this);

  /// The stroke a pen is drawing on the text, and which pen it is (see [recognizePenGesture]).
  final List<Offset> _pen = [];
  int? _penPointer;
  Timer? _rectsTimer;
  List<SelectionRect>? _rectsSent;

  /// What the keyboard knows: a stretch of the text, from [_windowFrom] with [_windowTail] characters after it.
  TextEditingValue _remote = TextEditingValue.empty;
  int _windowFrom = 0, _windowTail = 0;
  bool _windowSet = false;

  bool get _inputOpen => _input != null && _input!.attached;

  TextInputConfiguration get _inputConfig => TextInputConfiguration(
        viewId: View.of(context).viewId,
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        readOnly: !_editable,
        enableDeltaModel: true,
        allowedMimeTypes: widget.onContent == null ? const [] : blockContentTypes,
        keyboardAppearance: Theme.of(context).brightness,
      );

  void _openInput() {
    if (!_editable) return;
    if (!_inputOpen) {
      _input = TextInput.attach(this, _inputConfig);
      _remote = TextEditingValue.empty;
      _windowSet = false;
      _rectsSent = null;
      _syncInput();
      _sendPlace();
      _sendRectsSoon(at: Duration.zero);
    }
    _input!.show();
  }

  void _closeInput() {
    if (_inputOpen) _input!.close();
    _input = null;
    _floating = null;
    _rectsTimer?.cancel();
  }

  /// Where the keyboard's stretch of the text should be now.
  ({int from, int to}) _windowNow() {
    final text = _c.text;
    final s = _c.selection.isValid ? _c.selection : TextSelection.collapsed(offset: text.length);
    if (_lines.length == 0) return (from: 0, to: text.length);
    // (it stays while there is enough of it around the selection: moving it tells the keyboard, and a key pressed before that reached
    // it is a key on the old stretch)
    final keptTo = text.length - _windowTail;
    const enough = _imeRoom ~/ 4;
    if (_windowSet && keptTo - _windowFrom <= 4 * _imeRoom && s.start - _windowFrom >= math.min(enough, s.start) && keptTo - s.end >= math.min(enough, text.length - s.end)) {
      return (from: _windowFrom, to: keptTo);
    }
    final a = _lines.lineAt(s.start), b = _lines.lineAt(s.end);
    var from = math.max(_lines.blocks[math.max(0, a - 1)].start, s.start - _imeRoom);
    var to = math.min(_lines.blocks[math.min(_lines.length - 1, b + 1)].end, s.end + _imeRoom);
    // (not between the halves of a character)
    if (from > 0 && from < text.length && _isLowSurrogate(text.codeUnitAt(from))) from--;
    if (to > 0 && to < text.length && _isLowSurrogate(text.codeUnitAt(to))) to++;
    return (from: from, to: to);
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// Tells the keyboard what changed that it did not do itself.
  void _syncInput() {
    if (!_inputOpen) return;
    final text = _c.text;
    final v = _c.value;
    // (a word being composed stays where the keyboard has it)
    final composing = v.composing.isValid && !v.composing.isCollapsed;
    final w = composing ? (from: _windowFrom, to: text.length - _windowTail) : _windowNow();
    final from = w.from, to = w.to;
    _windowFrom = from;
    _windowTail = text.length - to;
    _windowSet = true;
    int local(int at) => (at - from).clamp(0, to - from);
    final s = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: text.length);
    final now = TextEditingValue(
      text: text.substring(from, to),
      selection: s.copyWith(baseOffset: local(s.baseOffset), extentOffset: local(s.extentOffset)),
      composing: composing ? TextRange(start: local(v.composing.start), end: local(v.composing.end)) : TextRange.empty,
    );
    if (now == _remote) return;
    _remote = now;
    _input!.setEditingState(now);
    _sendRectsSoon();
  }

  /// [v] is what the keyboard made of its stretch of the text.
  void _fromKeyboard(TextEditingValue v) {
    final text = _c.text;
    final from = _windowFrom;
    _remote = v;
    if (!_editable) return;
    int whole(int at) => at + from;
    final selection = v.selection.isValid ? v.selection.copyWith(baseOffset: whole(v.selection.baseOffset), extentOffset: whole(v.selection.extentOffset)) : _c.selection;
    final composing = v.composing.isValid ? TextRange(start: whole(v.composing.start), end: whole(v.composing.end)) : TextRange.empty;
    final to = text.length - _windowTail;
    if (text.substring(from, to) == v.text) {
      if (selection != _c.selection || composing != _c.value.composing) _c.value = _c.value.copyWith(selection: selection, composing: composing);
      return;
    }
    _hideMarks();
    // (what is typed changes the keyboard's stretch of the text; a line broken or joined the lines at its ends, which it holds too)
    _typed(() => _c.setWithin(TextEditingValue(text: text.replaceRange(from, to, v.text), selection: selection, composing: composing), same: _sameBefore(from), sameEnd: _sameAfter(to, text)));
  }

  /// How much before the place [from] of the text the change of a key can go: to the line before.
  int _sameBefore(int from) {
    final i = _lines.lineAt(from);
    return _lines.blocks[math.max(0, i - 1)].start;
  }

  int _sameAfter(int to, String text) {
    final i = _lines.lineAt(to);
    return text.length - _lines.blocks[math.min(_lines.length - 1, i + 1)].end;
  }

  void _sendPlace() {
    if (!_inputOpen) return;
    final column = _column;
    if (column == null || !column.attached || !column.hasSize) return;
    _input!.setEditableSizeAndTransform(column.size, column.getTransformTo(null));
    final rect = _caretRect;
    if (rect == null) return;
    _input!
      ..setCaretRect(rect)
      ..setComposingRect(rect);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _remote;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (value == _remote) return;
    _fromKeyboard(value);
  }

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    var v = _remote;
    var late = false;
    for (final delta in textEditingDeltas) {
      if (delta.oldText == v.text) {
        v = delta.apply(v);
        continue;
      }
      // it answers what it was told before a change it did not know of yet (a stretch of the text that moved, a word corrected): the key
      // still counts, and goes where the caret is now
      late = true;
      v = _atCaret(delta, v) ?? v;
    }
    _fromKeyboard(v);
    if (late) {
      _remote = const TextEditingValue(text: '\u0000');
      _syncInput();
    }
  }

  /// What [delta], made on another text than [v], does at the caret of [v]; null: what it takes away is not there.
  TextEditingValue? _atCaret(TextEditingDelta delta, TextEditingValue v) {
    final s = v.selection;
    if (!s.isValid) return null;
    final TextRange gone;
    final String put;
    switch (delta) {
      case TextEditingDeltaInsertion(:final textInserted):
        gone = s;
        put = textInserted;
      case TextEditingDeltaDeletion(:final textDeleted):
        if (!s.isCollapsed) {
          gone = s;
        } else {
          gone = TextRange(start: s.start - textDeleted.length, end: s.start);
          if (gone.start < 0 || v.text.substring(gone.start, gone.end) != textDeleted) return null;
        }
        put = '';
      case TextEditingDeltaReplacement(:final textReplaced, :final replacementText):
        gone = TextRange(start: s.start - textReplaced.length, end: s.start);
        if (gone.start < 0 || v.text.substring(gone.start, gone.end) != textReplaced) return null;
        put = replacementText;
      default:
        return null;
    }
    return TextEditingValue(text: v.text.replaceRange(gone.start, gone.end, put), selection: TextSelection.collapsed(offset: gone.start + put.length));
  }

  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) => _floatCursor(point);

  @override
  void insertContent(KeyboardInsertedContent content) => _contentFromKeyboard(content);

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _input?.connectionClosedReceived();
    _input = null;
    widget.focusNode.unfocus();
  }

  // ---- what is shown

  @override
  Widget build(BuildContext context) {
    // (the focus is the innermost: what the keys ask for is looked for going up from it)
    return Actions(
      actions: _actions,
      child: UndoHistory<TextEditingValue>(
        value: _c,
        focusNode: widget.focusNode,
        onTriggered: (value) => _c.setDirectly(value),
        shouldChangeUndoStack: (old, now) {
          if (!now.selection.isValid) return false;
          if (old == null) return true;
          if (defaultTargetPlatform != TargetPlatform.android && !_c.value.composing.isCollapsed) return false;
          return old.text != now.text || old.composing != now.composing;
        },
        undoStackModifier: (value) => defaultTargetPlatform == TargetPlatform.android ? value.copyWith(composing: TextRange.empty) : value,
        child: TextFieldTapRegion(
          onTapOutside: _tappedOutside,
          child: MouseRegion(
            cursor: SystemMouseCursors.text,
            child: Focus(
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              includeSemantics: false,
              child: _gestures(
                Stack(children: [
                  // (a line that is laid out again draws the box of the lines again: not all of the page they are on)
                  RepaintBoundary(
                    child: BlockColumn(
                      key: _columnKey,
                      lines: _lines,
                      width: _textWidth,
                      anchor: () => _anchor,
                      onAbove: _heightAbove,
                      onHeight: _shapeChanged,
                      shown: (line) => line >= _first && line <= _last || !_measuring.contains(line),
                      children: _children(),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: RepaintBoundary(child: _BlockMarks(this)),
                    ),
                  ),
                  if (_c.text.isEmpty && widget.hint != null)
                    Positioned(
                      left: 0,
                      top: 0,
                      child: IgnorePointer(child: RichText(text: TextSpan(text: widget.hint, style: widget.style.copyWith(color: Theme.of(context).hintColor)))),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _children() {
    if (_lines.length == 0) return const [];
    if (_measuring.isNotEmpty) {
      _measureClock
        ..reset()
        ..start();
    } else {
      _measureClock.stop();
    }
    final last = math.min(_last, _lines.length - 1);
    final caret = _caretLine;
    final wanted = <int>{
      for (var i = math.max(0, _first); i <= last; i++) i,
      for (var i = math.max(0, caret - 1); i <= math.min(_lines.length - 1, caret + 1); i++) i,
      ?_baseLine,
      ..._measuring.where((i) => i < _lines.length),
    };
    final order = wanted.toList()..sort();
    final kept = <int, _BlockItem>{};
    final out = <Widget>[];
    for (final i in order) {
      final line = _lines.lines[i];
      final item = _built[line.id] ?? _BlockItem(key: ValueKey(line.id), editor: this, line: line);
      kept[line.id] = item;
      out.add(item);
    }
    _built
      ..clear()
      ..addAll(kept);
    return out;
  }
}

/// (A selection overlay asks for one of these, for a toolbar it does not build here.)
class _NoSelectionDelegate implements TextSelectionDelegate {
  final BlockEditorState editor;
  _NoSelectionDelegate(this.editor);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  TextEditingValue get textEditingValue => editor._c.value;

  @override
  void userUpdateTextEditingValue(TextEditingValue value, SelectionChangedCause cause) => editor._c.value = value;
}

/// What the lines know of each other (see [LiveFacts]).
class _Numbers {
  final Map<String, int> footnotes;
  final Map<String, NamedStyle> styles;
  final Map<String, String> references;
  final List<int> captions;
  final List<String> contents;

  /// The lines the styles are set by.
  final List<String> styleLines;

  /// What is cited, in order.
  final List<String> cited;

  const _Numbers({this.footnotes = const {}, this.styles = const {}, this.references = const {}, this.captions = const [], this.contents = const [], this.styleLines = const [], this.cited = const []});

  factory _Numbers.of(List<MdBlock> blocks) => _Numbers(
        footnotes: footnoteNumbers(blocks),
        styles: documentStyles(blocks),
        references: crossReferences(blocks, figure: tr('Figure'), table: tr('Table')),
        captions: captionNumbers(blocks).values.toList(),
        contents: [for (final e in tocEntries(blocks)) '${e.$1} ${e.$2}'],
        styleLines: [
          for (final b in blocks)
            if (b.type == MdBlockType.setting) '${b.label} ${b.runs.map((r) => r.text).join()}',
        ],
        cited: [
          for (final b in blocks)
            for (final r in b.runs)
              if (r.cite != null) '${r.cite}',
        ],
      );
}

/// How a line is to look, all in places of the line.
class _Look {
  final int version, styles, numbers, foundNow;
  final List<TextSpanAttribute> attributes;
  final List<({int start, int end})> misspelled, found, grammar;
  final TextSelection? reveal;
  final bool focusMode;

  const _Look({
    required this.version,
    required this.styles,
    required this.numbers,
    required this.attributes,
    required this.misspelled,
    required this.found,
    required this.foundNow,
    required this.grammar,
    required this.reveal,
    required this.focusMode,
  });

  bool same(_Look o) {
    if (version != o.version || styles != o.styles || numbers != o.numbers || foundNow != o.foundNow || focusMode != o.focusMode || reveal != o.reveal) return false;
    if (!listEquals(misspelled, o.misspelled) || !listEquals(found, o.found) || !listEquals(grammar, o.grammar)) return false;
    if (attributes.length != o.attributes.length) return false;
    for (var i = 0; i < attributes.length; i++) {
      final a = attributes[i], b = o.attributes[i];
      if (a.start != b.start || a.end != b.end || a.type != b.type || a.value != b.value) return false;
    }
    return true;
  }
}

/// A line that is built: it is drawn again only when its [_Look] changes.
class _BlockItem extends StatefulWidget {
  final BlockEditorState editor;
  final DocumentLine line;

  const _BlockItem({super.key, required this.editor, required this.line});

  @override
  State<_BlockItem> createState() => _BlockItemState();
}

class _BlockItemState extends State<_BlockItem> {
  BlockEditorState get _editor => widget.editor;
  DocumentLine get _line => widget.line;

  late _Look _look = _editor._lookOf(_line)!;
  TextSpan? _span;
  _Look? _spanLook;
  TextRange? _selected;
  bool _selectedOn = false;
  bool _holdsCaret = false;

  // (where the line starts when this is asked: the text before it changes, and it is not drawn again for that)
  int get _start => _editor._lines.blocks[_line.index].start;

  late final LiveMarkdownActions _actions = LiveMarkdownActions(
    onLink: (target) => _editor._c.onLink?.call(target),
    onCitation: (run) => _editor._c.onCitation?.call(run.shifted(_start)),
    onToggleTask: (box) => _editor._c.toggleTask(box + _start),
    onHeading: _editor.goTo,
    onComment: (context, m) => _editor._c.editComment(context, m.shifted(_start)),
  );

  @override
  void initState() {
    super.initState();
    _editor._items[_line.id] = this;
    _readSelection();
  }

  @override
  void dispose() {
    if (identical(_editor._items[_line.id], this)) _editor._items.remove(_line.id);
    super.dispose();
  }

  // (what the line shows can come from around it: the size of text, the style of citations)
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _spanLook = null;
  }

  void _readSelection() {
    final b = _editor._lines.blocks[_line.index];
    final s = _editor._selectedOf(b.start, b.end);
    _selected = s.range;
    _selectedOn = s.on;
  }

  void refresh() {
    final look = _editor._lookOf(_line);
    if (look == null) return;
    final b = _editor._lines.blocks[_line.index];
    final s = _editor._selectedOf(b.start, b.end);
    final caret = _editor._holdsCaret(_line);
    if (look.same(_look) && s.range == _selected && s.on == _selectedOn && caret == _holdsCaret) return;
    setState(() {
      _look = look;
      _selected = s.range;
      _selectedOn = s.on;
    });
  }

  TextSpan _spanNow(BuildContext context) {
    final look = _look;
    final old = _span;
    if (old != null && _spanLook != null && _spanLook!.same(look)) return old;
    final b = _editor._lines.blocks[_line.index];
    final text = _editor._c.text.substring(b.start, b.end);
    final source = LiveSource(
      owner: this,
      text: text,
      attributes: look.attributes,
      misspelled: look.misspelled,
      found: look.found,
      foundNow: look.foundNow,
      grammar: () => look.grammar,
      focusMode: look.focusMode,
      blocks: [b.start == 0 ? b : b.shifted(-b.start)],
      facts: () => _editor._factsFor(b),
    );
    _spanLook = look;
    _editor.debugBuilds++;
    return _span = liveBlockSpan(context, source, _editor.widget.style, width: _editor._textWidth, reveal: look.reveal, actions: _actions);
  }

  /// The text field a screen reader finds where the caret is; the other lines are text it reads, that a tap goes to.
  BlockLineField? _field() {
    final e = _editor;
    if (!_holdsCaret) return null;
    final b = e._lines.blocks[_line.index];
    final s = e._c.selection;
    int local(int at) => (at - b.start).clamp(0, b.end - b.start);
    return BlockLineField(
      value: e._c.text.substring(b.start, b.end),
      selection: s.isValid ? TextSelection(baseOffset: local(s.baseOffset), extentOffset: local(s.extentOffset)) : null,
      focused: e.widget.focusNode.hasFocus,
      readOnly: !e._editable,
      direction: Directionality.of(context),
      onSetSelection: (v) => e._setSelection(TextSelection(baseOffset: b.start + v.baseOffset, extentOffset: b.start + v.extentOffset)),
      onMoveByCharacter: (forward, extend) => e._moveTo(e._characterEdge(e._extent, forward), collapse: !extend),
      onMoveByWord: (forward, extend) => e._moveTo(e._wordEdge(e._extent, forward), collapse: !extend),
      onCopy: s.isCollapsed ? null : () => e._copy(cut: false),
      onCut: s.isCollapsed || !e._editable ? null : () => e._copy(cut: true),
      onPaste: e._editable ? e._paste : null,
    );
  }

  MdBlock get _block => _editor._lines.blocks[_line.index];

  @override
  Widget build(BuildContext context) {
    final look = _editor._lookOf(_line);
    if (look != null) _look = look;
    _holdsCaret = _editor._holdsCaret(_line);
    return BlockPlace(
      line: _line,
      child: RepaintBoundary(
        child: Semantics(
          onTap: _editor._editable && !_holdsCaret ? () => _editor._goToLine(_line.index) : null,
          header: _block.type == MdBlockType.heading,
          headingLevel: _block.type == MdBlockType.heading ? _block.level.clamp(1, 6) : null,
          child: BlockLine(
            line: _line,
            rows: _editor.widget.sheets != null,
            selected: _selected,
            selectedOn: _selectedOn,
            selectionColor: DefaultSelectionStyle.of(context).selectionColor ?? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
            onRender: (r) => r == null ? _editor._renders.remove(_line.id) : _editor._renders[_line.id] = r,
            field: _field(),
            child: RichText(
              strutStyle: StrutStyle.disabled,
              textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
              text: _spanNow(context),
            ),
          ),
        ),
      ),
    );
  }
}
