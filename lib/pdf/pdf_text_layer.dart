import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/pdf_models.dart';

/// The text of a PDF page as one thing to select, laid out in page units (what the page is drawn in), without any text being laid
/// out: a character sits where its word's box says, evenly spread along it.
///
/// The text layer used to be one `Text` widget per word, hundreds a page, each with a global key and each a selectable the selection
/// area had to sort at every change. That took the most of the time of scrolling a text PDF on a slow tablet. This is one render object per
/// page that draws nothing but the selection.
class PdfTextModel {
  /// The lines in reading order (top to bottom, then left to right), their numbers in the list the page has.
  final List<int> order;
  final List<PdfTextLine> lines;
  final double scale;

  /// Where each line starts in [text] (the lines are joined by a line break).
  final List<int> starts;
  final String text;
  final List<List<PdfTextPiece>> _pieces;

  /// What the text covers, in the page units of the layer.
  final Rect bounds;

  PdfTextModel._(this.order, this.lines, this.scale, this.starts, this.text, this._pieces, this.bounds);

  factory PdfTextModel(PdfPageWords page, double pageUnits) {
    final scale = page.pageWidth > 0 ? pageUnits / page.pageWidth : 1.0;
    final order = readingOrder(page.lines);
    final lines = [for (final i in order) page.lines[i]];
    final starts = <int>[];
    final text = StringBuffer();
    final pieces = <List<PdfTextPiece>>[];
    Rect? bounds;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      starts.add(text.length);
      text.write(line.text);
      if (i + 1 < lines.length) text.write('\n');
      final list = <PdfTextPiece>[];
      for (var w = 0; w < line.words.length; w++) {
        final word = line.words[w];
        final last = w + 1 == line.words.length;
        final from = w == 0 ? 0 : word.startIndex.clamp(0, line.text.length);
        final to = last ? line.text.length : line.words[w + 1].startIndex.clamp(from, line.text.length);
        final left = (w == 0 ? math.min(word.xMin, line.xMin) : word.xMin) * scale;
        final right = (last ? math.max(word.xMax, line.xMax) : line.words[w + 1].xMin) * scale;
        list.add(PdfTextPiece(from, to, left, math.max(left, right)));
      }
      if (list.isEmpty && line.text.isNotEmpty) list.add(PdfTextPiece(0, line.text.length, line.xMin * scale, line.xMax * scale));
      pieces.add(list);
      final r = Rect.fromLTRB(line.xMin * scale, line.yMin * scale, line.xMax * scale, line.yMax * scale);
      bounds = bounds?.expandToInclude(r) ?? r;
    }
    return PdfTextModel._(order, lines, scale, starts, text.toString(), pieces, bounds ?? Rect.zero);
  }

  /// The lines of a page in the order they are read: top to bottom, and on one row left to right.
  static List<int> readingOrder(List<PdfTextLine> lines) {
    // (a tolerance in the comparison is not transitive and sorts lines into the wrong places: make rows first, then sort inside them)
    double mid(int i) => (lines[i].yMin + lines[i].yMax) / 2;
    final byY = List.generate(lines.length, (i) => i)..sort((a, b) => mid(a).compareTo(mid(b)));
    final result = <int>[];
    var row = <int>[];
    double rowMid = 0, rowHeight = 0;
    void flush() {
      row.sort((a, b) => lines[a].xMin.compareTo(lines[b].xMin));
      result.addAll(row);
      row = <int>[];
    }

    for (final i in byY) {
      if (row.isNotEmpty && (mid(i) - rowMid).abs() > 0.5 * rowHeight) flush();
      if (row.isEmpty) {
        rowMid = mid(i);
        rowHeight = lines[i].yMax - lines[i].yMin;
      }
      row.add(i);
    }
    flush();
    return result;
  }

  int get length => text.length;
  bool get isEmpty => text.isEmpty;

  /// The line a character of [text] is in (a line break belongs to the line it ends).
  int lineAt(int offset) {
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  int lineEnd(int line) => starts[line] + lines[line].text.length;

  List<PdfTextPiece> piecesOf(int line) => _pieces[line];

  double xIn(int line, int c) => _xIn(line, c);

  double _xIn(int line, int c) {
    final list = _pieces[line];
    if (list.isEmpty) return lines[line].xMin * scale;
    for (final p in list) {
      if (c < p.to || identical(p, list.last)) {
        final span = p.to - p.from;
        return span <= 0 ? p.left : p.left + (p.right - p.left) * ((c - p.from).clamp(0, span) / span);
      }
    }
    return list.last.right;
  }

  /// Where the caret before character [offset] stands: at the bottom of its line.
  Offset caret(int offset) {
    final i = lineAt(offset);
    final c = (offset - starts[i]).clamp(0, lines[i].text.length);
    return Offset(_xIn(i, c), lines[i].yMax * scale);
  }

  double lineHeight(int offset) {
    final line = lines[lineAt(offset)];
    return (line.yMax - line.yMin) * scale;
  }

  /// How far [p] is from the nearest line, and which it is.
  (int, double) nearestLine(Offset p) {
    var best = 0;
    var gap = double.infinity;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final top = l.yMin * scale, bottom = l.yMax * scale;
      final dy = p.dy < top ? top - p.dy : (p.dy > bottom ? p.dy - bottom : 0.0);
      final left = l.xMin * scale, right = l.xMax * scale;
      final dx = p.dx < left ? left - p.dx : (p.dx > right ? p.dx - right : 0.0);
      // (rows are far apart across, a row is long: along it counts less; boxes that overlap are told apart by the middle)
      final d = dy * 4 + dx + (p.dy - (top + bottom) / 2).abs() * 0.5;
      if (d < gap) {
        gap = d;
        best = i;
      }
    }
    final l = lines[best];
    final top = l.yMin * scale, bottom = l.yMax * scale;
    final dy = p.dy < top ? top - p.dy : (p.dy > bottom ? p.dy - bottom : 0.0);
    final dx = p.dx < l.xMin * scale ? l.xMin * scale - p.dx : (p.dx > l.xMax * scale ? p.dx - l.xMax * scale : 0.0);
    return (best, math.max(dy, dx));
  }

  /// The character of [text] whose caret is nearest [p].
  int offsetAt(Offset p) {
    if (lines.isEmpty) return 0;
    final (i, _) = nearestLine(p);
    final list = _pieces[i];
    final len = lines[i].text.length;
    if (list.isEmpty) return starts[i];
    var c = len;
    if (p.dx <= list.first.left) {
      c = 0;
    } else {
      for (final piece in list) {
        if (p.dx < piece.right || identical(piece, list.last)) {
          final span = piece.right - piece.left;
          final f = span <= 0 ? 0.0 : ((p.dx - piece.left) / span).clamp(0.0, 1.0);
          c = (piece.from + ((piece.to - piece.from) * f).round()).clamp(0, len);
          break;
        }
      }
    }
    return starts[i] + c;
  }

  /// The word [offset] is in, without the space after it.
  (int, int) wordAt(int offset) {
    final i = lineAt(offset);
    final line = lines[i];
    final c = (offset - starts[i]).clamp(0, line.text.length);
    var from = 0, to = line.text.length;
    for (final p in _pieces[i]) {
      if (c < p.to || identical(p, _pieces[i].last)) {
        from = p.from;
        to = p.to;
        break;
      }
    }
    while (to > from && line.text[to - 1].trim().isEmpty) {
      to--;
    }
    return (starts[i] + from, starts[i] + to);
  }

  (int, int) lineBoundaryAt(int offset) {
    final i = lineAt(offset);
    return (starts[i], lineEnd(i));
  }

  /// The boxes that [from] to [to] covers, a rectangle for each line it takes part of.
  List<Rect> rectsOf(int from, int to) {
    final rects = <Rect>[];
    if (from > to) {
      final t = from;
      from = to;
      to = t;
    }
    if (from == to || lines.isEmpty) return rects;
    for (var i = lineAt(from); i < lines.length && starts[i] < to; i++) {
      final a = math.max(from, starts[i]), b = math.min(to, lineEnd(i));
      if (b <= a && !(a == b && from < starts[i] && to > lineEnd(i))) continue;
      final l = lines[i];
      final xa = _xIn(i, a - starts[i]), xb = _xIn(i, b - starts[i]);
      rects.add(Rect.fromLTRB(math.min(xa, xb), l.yMin * scale, math.max(xa, xb), l.yMax * scale));
    }
    return rects;
  }

  /// The pieces of the lines that [from] to [to] covers: the line (as it is in the page's own list), and the characters of its text.
  List<(PdfTextLine, int, int)> spansOf(int from, int to) {
    final spans = <(PdfTextLine, int, int)>[];
    if (from > to) {
      final t = from;
      from = to;
      to = t;
    }
    if (from == to || lines.isEmpty) return spans;
    for (var i = lineAt(from); i < lines.length && starts[i] < to; i++) {
      final a = math.max(from, starts[i]) - starts[i], b = math.min(to, lineEnd(i)) - starts[i];
      if (b > a) spans.add((lines[i], a, b));
    }
    return spans;
  }
}

class PdfTextPiece {
  final int from, to;
  final double left, right;
  const PdfTextPiece(this.from, this.to, this.left, this.right);
}

/// The text of a PDF page for the selection area around it: the words are selected where they are on the page. Draws the selection
/// only (the page's picture shows the text). [page] is the words of the page; the layer is [width] by [height] page units.
class PdfTextLayer extends LeafRenderObjectWidget {
  const PdfTextLayer({super.key, required this.page, required this.width, required this.height, this.selectionColor});

  final PdfPageWords page;
  final double width, height;
  final Color? selectionColor;

  @override
  RenderPdfTextLayer createRenderObject(BuildContext context) => RenderPdfTextLayer(
        page: page,
        width: width,
        height: height,
        selectionColor: selectionColor ?? DefaultSelectionStyle.of(context).selectionColor,
        registrar: SelectionContainer.maybeOf(context),
      );

  @override
  void updateRenderObject(BuildContext context, RenderPdfTextLayer renderObject) {
    renderObject
      ..selectionColor = selectionColor ?? DefaultSelectionStyle.of(context).selectionColor
      ..registrar = SelectionContainer.maybeOf(context)
      ..setPage(page, width, height);
  }
}

class RenderPdfTextLayer extends RenderBox {
  RenderPdfTextLayer({required PdfPageWords page, required double width, required double height, Color? selectionColor, SelectionRegistrar? registrar})
      : _page = page,
        _width = width,
        _height = height,
        _selectionColor = selectionColor {
    _model = PdfTextModel(page, width);
    _selectable = PdfTextSelectable(this, _model);
    this.registrar = registrar;
  }

  PdfPageWords _page;
  double _width, _height;
  late PdfTextModel _model;
  late PdfTextSelectable _selectable;
  Color? _selectionColor;
  SelectionRegistrar? _registrar;

  PdfTextModel get model => _model;

  /// The characters selected (start and end edge, the start may be after the end), null when nothing is.
  (int, int)? get selection => _selectable.edges;

  /// The pieces of the lines that are selected (see [PdfTextModel.spansOf]).
  List<(PdfTextLine, int, int)> get selectedSpans {
    final e = _selectable.edges;
    return e == null ? const [] : _model.spansOf(e.$1, e.$2);
  }

  /// Where the words that read [word] are on the screen (for tests, which cannot find a word as a widget any more).
  @visibleForTesting
  List<Rect> wordRects(String word) {
    final m = getTransformTo(null);
    final rects = <Rect>[];
    for (var i = 0; i < _model.lines.length; i++) {
      final line = _model.lines[i];
      for (final piece in _model.piecesOf(i)) {
        final text = line.text.substring(piece.from, piece.to);
        if (text.trim() == word) {
          final a = _model.xIn(i, piece.from), b = _model.xIn(i, piece.from + text.trimRight().length);
          rects.add(MatrixUtils.transformRect(m, Rect.fromLTRB(a, line.yMin * _model.scale, b, line.yMax * _model.scale)));
        }
      }
    }
    return rects;
  }

  set selectionColor(Color? value) {
    if (value == _selectionColor) return;
    _selectionColor = value;
    markNeedsPaint();
  }

  SelectionRegistrar? get registrar => _registrar;
  set registrar(SelectionRegistrar? value) {
    if (value == _registrar) return;
    _unregister();
    _registrar = value;
    _register();
  }

  bool _registered = false;

  void _register() {
    if (_registered || _model.isEmpty || _registrar == null) return;
    _registrar!.add(_selectable);
    _registered = true;
  }

  void _unregister() {
    if (!_registered) return;
    _registrar?.remove(_selectable);
    _registered = false;
  }

  void setPage(PdfPageWords page, double width, double height) {
    if (identical(page, _page) && width == _width && height == _height) return;
    final same = identical(page, _page) && width == _width;
    _page = page;
    _width = width;
    if (_height != height) {
      _height = height;
      markNeedsLayout();
    }
    if (same) return;
    // (other words: what was selected is not there any more)
    _unregister();
    _selectable.dispose();
    _model = PdfTextModel(page, width);
    _selectable = PdfTextSelectable(this, _model);
    _register();
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(Size(_width, _height));

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final geometry = _selectable.value;
    final color = _selectionColor;
    if (color != null && geometry.hasSelection) {
      final paint = Paint()..color = color;
      for (final r in geometry.selectionRects) {
        context.canvas.drawRect(r.shift(offset), paint);
      }
    }
    final start = _selectable.startHandle, end = _selectable.endHandle;
    if (start != null && geometry.startSelectionPoint != null) {
      context.pushLayer(LeaderLayer(link: start, offset: offset + geometry.startSelectionPoint!.localPosition), (_, _) {}, Offset.zero);
    }
    if (end != null && geometry.endSelectionPoint != null) {
      context.pushLayer(LeaderLayer(link: end, offset: offset + geometry.endSelectionPoint!.localPosition), (_, _) {}, Offset.zero);
    }
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..label = _model.text
      ..textDirection = TextDirection.ltr;
  }

  @override
  void dispose() {
    _unregister();
    _selectable.dispose();
    super.dispose();
  }
}

/// What the selection area sees of a page's text.
class PdfTextSelectable with Selectable, ChangeNotifier {
  PdfTextSelectable(this.box, this.model);

  final RenderPdfTextLayer box;
  final PdfTextModel model;

  int? _start, _end;

  /// The word or line a selection by words or lines started with (it stays whole while the edge is dragged).
  (int, int)? _origin;
  LayerLink? startHandle, endHandle;

  SelectionGeometry _geometry = const SelectionGeometry(status: SelectionStatus.none, hasContent: true);

  (int, int)? get edges => _start == null || _end == null ? null : (_start!, _end!);

  @override
  SelectionGeometry get value => _geometry;

  @override
  int get contentLength => model.length;

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) => box.getTransformTo(ancestor);

  @override
  Size get size => box.size;

  @override
  List<Rect> get boundingBoxes => [model.bounds];

  @override
  void pushHandleLayers(LayerLink? start, LayerLink? end) {
    if (startHandle == start && endHandle == end) return;
    startHandle = start;
    endHandle = end;
    if (!_gone) box.markNeedsPaint(); // (the area lets go of the handles after the page left)
  }

  bool _gone = false;

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  @override
  SelectedContent? getSelectedContent() {
    final e = edges;
    if (e == null) return null;
    return SelectedContent(plainText: model.text.substring(math.min(e.$1, e.$2), math.max(e.$1, e.$2)));
  }

  @override
  SelectedContentRange? getSelection() {
    final e = edges;
    return e == null ? null : SelectedContentRange(startOffset: e.$1, endOffset: e.$2);
  }

  SelectionGeometry _compute() {
    final e = edges;
    if (e == null) return const SelectionGeometry(status: SelectionStatus.none, hasContent: true);
    final (a, b) = e;
    final collapsed = a == b;
    final reversed = a > b;
    final (startType, endType) = collapsed
        ? (TextSelectionHandleType.collapsed, TextSelectionHandleType.collapsed)
        : reversed
            ? (TextSelectionHandleType.right, TextSelectionHandleType.left)
            : (TextSelectionHandleType.left, TextSelectionHandleType.right);
    return SelectionGeometry(
      startSelectionPoint: SelectionPoint(localPosition: model.caret(a), lineHeight: model.lineHeight(a), handleType: startType),
      endSelectionPoint: SelectionPoint(localPosition: model.caret(b), lineHeight: model.lineHeight(b), handleType: endType),
      selectionRects: model.rectsOf(a, b),
      status: collapsed ? SelectionStatus.collapsed : SelectionStatus.uncollapsed,
      hasContent: true,
    );
  }

  void _changed() {
    final g = _compute();
    if (!_gone) box.markNeedsPaint();
    if (g == _geometry) return;
    _geometry = g;
    notifyListeners();
  }

  Offset _local(Offset global) {
    final m = box.getTransformTo(null)..invert();
    return MatrixUtils.transformPoint(m, global);
  }

  /// Whether [p] is on the text, or near enough to a line of it to be on it.
  bool _onText(Offset p) {
    if (model.isEmpty) return false;
    final (i, gap) = model.nearestLine(p);
    return gap <= math.max(6.0, (model.lines[i].yMax - model.lines[i].yMin) * model.scale * 0.6);
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final before = edges;
    final result = _dispatch(event);
    if (before != edges) _changed();
    return result;
  }

  SelectionResult _dispatch(SelectionEvent event) {
    final len = model.length;
    switch (event.type) {
      case SelectionEventType.startEdgeUpdate:
      case SelectionEventType.endEdgeUpdate:
        final update = event as SelectionEdgeUpdateEvent;
        final isEnd = event.type == SelectionEventType.endEdgeUpdate;
        final local = _local(update.globalPosition);
        // (the page is what the pointer is in or out of, not the text: the margin above the first line is still this page)
        final bounds = Offset.zero & box.size;
        if (model.isEmpty) return SelectionUtils.getResultBasedOnRect(bounds, local);
        final adjusted = SelectionUtils.adjustDragOffset(bounds, local);
        final g = model.offsetAt(adjusted);
        switch (update.granularity) {
          case TextGranularity.character:
            _origin = null;
            _setEdge(g, isEnd);
          case TextGranularity.word:
          case TextGranularity.paragraph:
          case TextGranularity.line:
          case TextGranularity.document:
            final (from, to) = update.granularity == TextGranularity.word ? model.wordAt(g) : model.lineBoundaryAt(g);
            final origin = _origin;
            if (origin != null) {
              final before = g < origin.$1;
              final moving = before ? from : to, fixed = before ? origin.$2 : origin.$1;
              if (isEnd) {
                _start = fixed;
                _end = moving;
              } else {
                _end = fixed;
                _start = moving;
              }
            } else {
              final other = isEnd ? _start : _end;
              final backward = other != null && g < other;
              _setEdge(backward ? from : to, isEnd);
            }
        }
        // (only where the pointer is says whether the edge is on this page: an edge at the first or last character is still on it)
        return SelectionUtils.getResultBasedOnRect(bounds, local);
      case SelectionEventType.clear:
        _start = _end = null;
        _origin = null;
        return SelectionResult.none;
      case SelectionEventType.selectAll:
        _start = 0;
        _end = len;
        return SelectionResult.none;
      case SelectionEventType.selectWord:
      case SelectionEventType.selectParagraph:
        if (event is SelectParagraphSelectionEvent && event.absorb) {
          _start = 0;
          _end = len;
          _origin = (0, len);
          return SelectionResult.next;
        }
        final at = event is SelectWordSelectionEvent ? event.globalPosition : (event as SelectParagraphSelectionEvent).globalPosition;
        final local = _local(at);
        if (!_onText(local)) return model.isEmpty ? SelectionResult.previous : SelectionUtils.getResultBasedOnRect(model.bounds, local);
        final g = model.offsetAt(local);
        if (_start != null && _end != null && _start != _end && g >= math.min(_start!, _end!) && g <= math.max(_start!, _end!)) return SelectionResult.end;
        final (from, to) = event is SelectWordSelectionEvent ? model.wordAt(g) : model.lineBoundaryAt(g);
        _start = from;
        _end = to;
        _origin = (from, to);
        return SelectionResult.end;
      case SelectionEventType.granularlyExtendSelection:
        return _extendBy(event as GranularlyExtendSelectionEvent);
      case SelectionEventType.directionallyExtendSelection:
        return _extendTowards(event as DirectionallyExtendSelectionEvent);
    }
  }

  void _setEdge(int offset, bool isEnd) {
    if (isEnd) {
      _end = offset;
      _start ??= offset;
    } else {
      _start = offset;
      _end ??= offset;
    }
  }

  SelectionResult _extendBy(GranularlyExtendSelectionEvent e) {
    final len = model.length;
    _end ??= e.forward ? 0 : len;
    _start ??= _end;
    final at = e.isEnd ? _end! : _start!;
    if (e.forward && at >= len) return SelectionResult.next;
    if (!e.forward && at <= 0) return SelectionResult.previous;
    final int to;
    switch (e.granularity) {
      case TextGranularity.character:
        to = at + (e.forward ? 1 : -1);
      case TextGranularity.word:
        var p = at;
        if (e.forward) {
          while (p < len && model.text[p].trim().isEmpty) {
            p++;
          }
          p = p >= len ? len : model.wordAt(p).$2;
        } else {
          while (p > 0 && model.text[p - 1].trim().isEmpty) {
            p--;
          }
          p = p <= 0 ? 0 : model.wordAt(p - 1).$1;
        }
        to = p;
      case TextGranularity.paragraph:
      case TextGranularity.line:
        final (from, end) = model.lineBoundaryAt(e.forward ? at : math.max(0, at - 1));
        to = e.forward ? (end > at ? end : math.min(len, end + 1)) : (from < at ? from : math.max(0, from - 1));
      case TextGranularity.document:
        to = e.forward ? len : 0;
    }
    _setEdge(to.clamp(0, len), e.isEnd);
    return SelectionResult.end;
  }

  SelectionResult _extendTowards(DirectionallyExtendSelectionEvent e) {
    final len = model.length;
    if (model.isEmpty) return SelectionResult.next;
    final inverse = box.getTransformTo(null)..invert();
    final x = MatrixUtils.transformPoint(inverse, Offset(e.dx, 0)).dx;
    switch (e.direction) {
      case SelectionExtendDirection.forward:
      case SelectionExtendDirection.backward:
        _end ??= e.direction == SelectionExtendDirection.forward ? 0 : len;
        _start ??= _end;
        final at = e.isEnd ? _end! : _start!;
        final caret = model.caret(at);
        _setEdge(model.offsetAt(Offset(x, caret.dy - model.lineHeight(at) / 2)), e.isEnd);
        return SelectionResult.end;
      case SelectionExtendDirection.previousLine:
      case SelectionExtendDirection.nextLine:
        final at = e.isEnd ? _end : _start;
        if (at == null) return SelectionResult.end;
        final line = model.lineAt(at);
        final other = e.direction == SelectionExtendDirection.nextLine ? line + 1 : line - 1;
        if (other < 0) {
          _setEdge(0, e.isEnd);
          return SelectionResult.previous;
        }
        if (other >= model.lines.length) {
          _setEdge(len, e.isEnd);
          return SelectionResult.next;
        }
        final l = model.lines[other];
        _setEdge(model.offsetAt(Offset(x, (l.yMin + l.yMax) / 2 * model.scale)), e.isEnd);
        return SelectionResult.end;
    }
  }
}
