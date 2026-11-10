import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../markdown/live_markdown.dart';
import 'document_lines.dart';

/// The lines of the document that are built, each where it belongs, in a box as tall as all of the document. Only those are ever
/// laid out, so that a key that is pressed costs what the screen costs, not what the document does.
class BlockColumn extends MultiChildRenderObjectWidget {
  final DocumentLines lines;
  final double width;

  /// The line at the top of the screen. A line above it that turns out another height than was thought goes to [onAbove] and not into
  /// the layout: what is above the screen and how far it is scrolled have to change together, in one layout, for what is on screen to
  /// stay where it is, and by the time a line is laid out it is too late for the scrolling.
  final int Function() anchor;
  final void Function(DocumentLine line, double height) onAbove;

  /// Called when all of it got taller or shorter.
  final VoidCallback onHeight;

  /// Which lines are drawn: the others are only being measured.
  final bool Function(int line) shown;

  const BlockColumn({super.key, required this.lines, required this.width, required this.anchor, required this.onAbove, required this.onHeight, required this.shown, required super.children});

  @override
  RenderBlockColumn createRenderObject(BuildContext context) => RenderBlockColumn(lines, width, anchor, onAbove, onHeight, shown);

  @override
  void updateRenderObject(BuildContext context, RenderBlockColumn renderObject) => renderObject
    ..width = width
    ..anchor = anchor
    ..onAbove = onAbove
    ..onHeight = onHeight
    ..shown = shown;
}

class BlockParentData extends ContainerBoxParentData<RenderBox> {
  DocumentLine? line;
}

/// Which line a child of a [BlockColumn] is.
class BlockPlace extends ParentDataWidget<BlockParentData> {
  final DocumentLine line;
  const BlockPlace({super.key, required this.line, required super.child});

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as BlockParentData;
    if (data.line == line) return;
    data.line = line;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => BlockColumn;
}

class RenderBlockColumn extends RenderBox with ContainerRenderObjectMixin<RenderBox, BlockParentData>, RenderBoxContainerDefaultsMixin<RenderBox, BlockParentData> {
  final DocumentLines lines;
  double _width;
  int Function() anchor;
  void Function(DocumentLine line, double height) onAbove;
  VoidCallback onHeight;
  bool Function(int line) shown;

  RenderBlockColumn(this.lines, this._width, this.anchor, this.onAbove, this.onHeight, this.shown);

  set width(double v) {
    if (v == _width) return;
    _width = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BlockParentData) child.parentData = BlockParentData();
  }

  @override
  void performLayout() {
    final top = anchor();
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as BlockParentData;
      child.layout(BoxConstraints.tightFor(width: _width), parentUsesSize: true);
      final line = data.line!;
      // (a line above the screen waits: see [onAbove])
      if (line.index < top && child.size.height != line.height) {
        onAbove(line, child.size.height);
      } else {
        lines.setHeight(line, child.size.height);
      }
      child = data.nextSibling;
    }
    child = firstChild;
    while (child != null) {
      final data = child.parentData! as BlockParentData;
      final line = data.line!;
      data.offset = Offset(0, lines.topOf(line.index));
      (line.render as RenderBlockLine?)?.breaks = line.breaks;
      child = data.nextSibling;
    }
    final was = hasSize ? size.height : -1;
    size = constraints.constrain(Size(_width, lines.height));
    if (size.height != was) onHeight();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as BlockParentData;
      if (shown(data.line!.index)) context.paintChild(child, data.offset + offset);
      child = data.nextSibling;
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    var child = lastChild;
    while (child != null) {
      final data = child.parentData! as BlockParentData;
      final box = child;
      // (a line that goes over to the next sheet is drawn with a gap in it that it does not know of)
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, at) => box.hitTest(result, position: Offset(at.dx, data.line!.natural(at.dy))),
      );
      if (hit) return true;
      child = data.previousSibling;
    }
    return false;
  }

  // (those being measured are not there for a screen reader)
  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as BlockParentData;
      if (shown(data.line!.index)) visitor(child);
      child = data.nextSibling;
    }
  }
}

/// What a screen reader is told of the line the caret is on: it is the text field there.
class BlockLineField {
  final String value;
  final TextSelection? selection;
  final bool focused, readOnly;
  final TextDirection direction;
  final ValueChanged<TextSelection> onSetSelection;
  final void Function(bool forward, bool extend) onMoveByCharacter, onMoveByWord;
  final VoidCallback? onCopy, onCut, onPaste;

  const BlockLineField({
    required this.value,
    required this.selection,
    required this.focused,
    required this.readOnly,
    required this.direction,
    required this.onSetSelection,
    required this.onMoveByCharacter,
    required this.onMoveByWord,
    this.onCopy,
    this.onCut,
    this.onPaste,
  });
}

/// A line of the document with what is selected of it behind it.
class BlockLine extends SingleChildRenderObjectWidget {
  /// What is selected of the line (null: none), and whether the selection goes on past its end.
  final TextRange? selected;
  final bool selectedOn;
  final Color selectionColor;

  /// Called with the line's render object when it starts and (with null) when it ends.
  final ValueChanged<RenderBlockLine?> onRender;

  /// While the caret is on the line.
  final BlockLineField? field;

  final DocumentLine line;

  /// Whether where its rows end is of interest (the text is on sheets of paper).
  final bool rows;

  const BlockLine({super.key, required this.line, this.rows = false, required this.selected, required this.selectedOn, required this.selectionColor, required this.onRender, this.field, required super.child});

  @override
  RenderBlockLine createRenderObject(BuildContext context) => RenderBlockLine(line, rows, selected, selectedOn, selectionColor, onRender)..field = field;

  @override
  void updateRenderObject(BuildContext context, RenderBlockLine renderObject) => renderObject
    ..wantsRows = rows
    ..selectionColor = selectionColor
    ..setSelected(selected, selectedOn)
    ..field = field;
}

class RenderBlockLine extends RenderExactHeight {
  TextRange? _selected;
  bool _selectedOn;
  Color _color;
  final ValueChanged<RenderBlockLine?> _onRender;

  final DocumentLine line;
  bool wantsRows;

  RenderBlockLine(this.line, this.wantsRows, this._selected, this._selectedOn, this._color, this._onRender) : _breaks = line.breaks;

  List<({double at, double gap})> _breaks;
  set breaks(List<({double at, double gap})> v) {
    if (listEquals(v, _breaks)) return;
    _breaks = v;
    markNeedsPaint();
  }

  BlockLineField? _field;
  set field(BlockLineField? v) {
    if (identical(v, _field)) return;
    final was = _field;
    _field = v;
    if (was != null || v != null) markNeedsSemanticsUpdate();
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_field == null) super.visitChildrenForSemantics(visitor);
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    final f = _field;
    if (f == null) return;
    config
      ..isSemanticBoundary = true
      ..isTextField = true
      ..isMultiline = true
      ..isFocused = f.focused
      ..isReadOnly = f.readOnly
      ..value = f.value
      ..textDirection = f.direction
      ..onSetSelection = f.onSetSelection
      ..onMoveCursorForwardByCharacter = ((extend) => f.onMoveByCharacter(true, extend))
      ..onMoveCursorBackwardByCharacter = ((extend) => f.onMoveByCharacter(false, extend))
      ..onMoveCursorForwardByWord = ((extend) => f.onMoveByWord(true, extend))
      ..onMoveCursorBackwardByWord = ((extend) => f.onMoveByWord(false, extend));
    if (f.selection != null) config.textSelection = f.selection;
    if (f.onCopy != null) config.onCopy = f.onCopy;
    if (f.onCut != null) config.onCut = f.onCut;
    if (f.onPaste != null) config.onPaste = f.onPaste;
  }

  set selectionColor(Color v) {
    if (v == _color) return;
    _color = v;
    if (_selected != null) markNeedsPaint();
  }

  void setSelected(TextRange? range, bool on) {
    if (range == _selected && on == _selectedOn) return;
    _selected = range;
    _selectedOn = on;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    line.render = this;
    _onRender(this);
  }

  @override
  void detach() {
    if (identical(line.render, this)) line.render = null;
    _onRender(null);
    super.detach();
  }

  RenderParagraph get paragraph => child! as RenderParagraph;

  /// The place in the line at [local].
  TextPosition positionAt(Offset local) => paragraph.getPositionForOffset(local);

  List<Rect>? _rows;

  /// The visual lines the paragraph is wrapped into, top to bottom.
  List<Rect> get _visualLines {
    final kept = _rows;
    if (kept != null) return kept;
    final rows = <Rect>[];
    for (final box in _length == 0 ? const <TextBox>[] : boxes(TextRange(start: 0, end: _length))) {
      final r = box.toRect();
      if (r.height <= 0) continue;
      final i = rows.indexWhere((x) => r.center.dy >= x.top && r.center.dy <= x.bottom);
      if (i < 0) {
        rows.add(Rect.fromLTRB(0, r.top, size.width, r.bottom));
      } else {
        rows[i] = Rect.fromLTRB(0, math.min(rows[i].top, r.top), size.width, math.max(rows[i].bottom, r.bottom));
      }
    }
    rows.sort((x, y) => x.top.compareTo(y.top));
    return _rows = rows.isEmpty ? [Offset.zero & size] : rows;
  }

  /// How many places the line has, as it is drawn.
  int get _length => _lengthKept ??= paragraph.text.toPlainText(includeSemanticsLabels: false).length;
  int? _lengthKept;

  /// The left of the place [position], and how far down its visual line is. At the end of the text what is asked of the paragraph goes by the
  /// character before it, which can be Markdown drawn at no size (a text field only comes there at the end of a document, a line here
  /// at the end of each line): there it goes by what is drawn last.
  Offset _placeOf(TextPosition position) {
    if (position.offset < _length) {
      final at = paragraph.getOffsetForCaret(position, Rect.zero);
      return Offset(at.dx, at.dy + paragraph.getFullHeightForCaret(position) / 2);
    }
    final drawn = _length == 0 ? const <TextBox>[] : boxes(TextRange(start: 0, end: _length)).where((b) => b.right > b.left).toList();
    return drawn.isEmpty ? Offset(0, _visualLines.first.center.dy) : Offset(drawn.last.right, drawn.last.toRect().center.dy);
  }

  @override
  void performLayout() {
    _rows = null;
    _lengthKept = null;
    super.performLayout();
    if (!wantsRows) return;
    final rows = _visualLines.length < 2 ? null : [for (final r in _visualLines) r.bottom];
    if (!listEquals(rows, line.rows)) {
      line
        ..rows = rows
        ..rowsMoved = true;
    }
  }

  /// The visual line a caret at [position] is on, from its top to its bottom.
  Rect lineBoxAt(TextPosition position) {
    final y = _placeOf(position).dy;
    final rows = _visualLines;
    return rows.lastWhere((r) => r.top <= y, orElse: () => rows.first);
  }

  /// Where a caret at [position] is, in the line: as tall as its visual line. (What the text says of a caret goes by the letter next to it,
  /// and comes out shorter and higher at the end of a line than inside a word.)
  Rect caretRect(TextPosition position) {
    final box = lineBoxAt(position);
    return Rect.fromLTWH(_placeOf(position).dx, box.top, 2, box.height);
  }

  /// The boxes of the characters in [range], in the line.
  List<TextBox> boxes(TextRange range) => paragraph.getBoxesForSelection(TextSelection(baseOffset: range.start, extentOffset: range.end), boxHeightStyle: BoxHeightStyle.max);

  TextRange wordAt(int offset) => paragraph.getWordBoundary(TextPosition(offset: offset));

  /// The edges of the visual line a caret at [position] is on.
  TextRange visualLineAt(TextPosition position) {
    final y = caretRect(position).center.dy;
    return TextRange(start: positionAt(Offset(0, y)).offset, end: positionAt(Offset(size.width, y)).offset);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_breaks.isEmpty) return _paintPart(context, offset);
    // over two sheets: the rows before the gap, and those after it further down
    var from = 0.0, shift = 0.0;
    for (var i = 0; i <= _breaks.length; i++) {
      final to = i < _breaks.length ? _breaks[i].at : size.height;
      context.pushClipRect(needsCompositing, offset + Offset(0, shift), Rect.fromLTRB(-16, from, size.width + 16, to), _paintPart);
      if (i < _breaks.length) {
        from = to;
        shift += _breaks[i].gap;
      }
    }
  }

  void _paintPart(PaintingContext context, Offset offset) {
    final range = _selected;
    if (range != null) {
      final paint = Paint()..color = _color;
      final found = range.isCollapsed ? const <TextBox>[] : boxes(range);
      for (final box in found) {
        context.canvas.drawRect(box.toRect().shift(offset), paint);
      }
      // (the line break of a line that is selected on past it)
      if (_selectedOn) {
        final end = found.isEmpty ? caretRect(TextPosition(offset: range.end)) : found.last.toRect();
        context.canvas.drawRect(Rect.fromLTWH(offset.dx + end.right, offset.dy + end.top, 6, end.height), paint);
      }
    }
    super.paint(context, offset);
  }
}
