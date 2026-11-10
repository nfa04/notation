import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// The line that ends a group of tools in a bar at the side of the page, see [ToolColumns].
class ToolGroupDivider extends StatelessWidget {
  final double width;
  final double height;
  const ToolGroupDivider({super.key, required this.width, required this.height});

  @override
  Widget build(BuildContext context) => SizedBox(width: width, child: Divider(height: height));
}

/// The tools of a bar at the side of the page, down the height there is. A [ToolGroupDivider] ends a group, and a group that does
/// not fit in what is left of a column goes to the next one as a whole, so that tools that belong together stay together (only a
/// group higher than the bar itself is broken).
class ToolColumns extends StatelessWidget {
  final List<Widget> children;

  /// Tools too wide for a column, each on a line across the whole bar: above the columns, and at the foot of the bar.
  final List<Widget> top;
  final List<Widget> bottom;

  /// The least width of the bar when it has such lines (they keep it to this even when one column would do).
  final double lineWidth;

  const ToolColumns({super.key, required this.children, this.top = const [], this.bottom = const [], this.lineWidth = 0});

  @override
  Widget build(BuildContext context) {
    final groups = <List<Widget>>[[]];
    for (final child in children) {
      groups.last.add(child);
      if (child is ToolGroupDivider) groups.add([]);
    }
    final columns = Wrap(
      direction: Axis.vertical,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final group in groups)
          if (group.isNotEmpty) Wrap(direction: Axis.vertical, crossAxisAlignment: WrapCrossAlignment.center, children: group),
      ],
    );
    if (top.isEmpty && bottom.isEmpty) return columns;
    return _LinesAndColumns(top: top.length, lineWidth: lineWidth, children: [...top, columns, ...bottom]);
  }
}

/// Lines as wide as the columns between them. The columns are laid out in the height the lines leave, and only then is it known
/// how wide the lines are, which neither a [Column] nor a [Wrap] can do. The child after the first [top] is the columns.
class _LinesAndColumns extends MultiChildRenderObjectWidget {
  final int top;
  final double lineWidth;
  const _LinesAndColumns({required this.top, required this.lineWidth, required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLinesAndColumns(top, lineWidth);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderLinesAndColumns)
      ..top = top
      ..lineWidth = lineWidth;
  }
}

class _LineData extends ContainerBoxParentData<RenderBox> {}

class _RenderLinesAndColumns extends RenderBox with ContainerRenderObjectMixin<RenderBox, _LineData>, RenderBoxContainerDefaultsMixin<RenderBox, _LineData> {
  _RenderLinesAndColumns(this._top, this._lineWidth);

  int _top;
  set top(int value) {
    if (value == _top) return;
    _top = value;
    markNeedsLayout();
  }

  double _lineWidth;
  set lineWidth(double value) {
    if (value == _lineWidth) return;
    _lineWidth = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _LineData) child.parentData = _LineData();
  }

  @override
  void performLayout() {
    final children = getChildrenAsList();
    final columns = children[_top];
    final above = children.take(_top).toList(), below = children.skip(_top + 1).toList();
    var linesHigh = 0.0;
    for (final line in [...above, ...below]) {
      line.layout(BoxConstraints.tightFor(width: _lineWidth), parentUsesSize: true);
      linesHigh += line.size.height;
    }
    columns.layout(BoxConstraints(maxHeight: math.max(0, constraints.maxHeight - linesHigh)), parentUsesSize: true);
    final width = math.max(columns.size.width, _lineWidth);
    for (final line in [...above, ...below]) {
      line.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
    }
    size = constraints.constrain(Size(width, constraints.hasBoundedHeight ? constraints.maxHeight : linesHigh + columns.size.height));

    void put(RenderBox child, double x, double y) => (child.parentData! as _LineData).offset = Offset(x, y);
    var y = 0.0;
    for (final line in above) {
      put(line, 0, y);
      y += line.size.height;
    }
    put(columns, (width - columns.size.width) / 2, y);
    y = size.height;
    for (final line in below.reversed) {
      y -= line.size.height;
      put(line, 0, y);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);
}

/// A bar at the side of the page that keeps its shape while the screen is short, and scrolls instead: laid out in a shorter height it
/// would go to more and more columns, and those come off the width the page is scaled to. The keyboard takes half of a tablet.
class SteadyBar extends StatelessWidget {
  final Widget child;

  /// The height it is laid out in at the least, a small window with no keyboard too.
  static const double leastHeight = 560;

  const SteadyBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final view = View.of(context);
        final tall = math.max(box.maxHeight + view.viewInsets.bottom / view.devicePixelRatio, leastHeight);
        return SingleChildScrollView(child: SizedBox(height: tall, child: child));
      });
}

/// The page area with the panels and the bars at its side, which slide in and out. The page and everything beside it are laid out
/// once, at the size they end up with, and only drawn aside while something moves: laying out all the pages of a long document
/// again for every frame of a slide would not be smooth. [panels] (look-ups, history and the like, in a row), [first] and [second]
/// are null while there is no such thing; the last one stays on screen until it has slid out. They stand from left to right in that
/// order.
class PageWithSideBars extends StatefulWidget {
  /// The pages, which fill what the others leave.
  final Widget pages;
  final Widget? panels;
  final Widget? first;
  final Widget? second;

  /// How far the pages stand down from the top; when it changes (a ruler comes above them), they are laid out at the new place
  /// at once and eased there from the old one.
  final double pagesDrop;

  /// The scale the pages are drawn at, read after they are laid out. Pages that are fitted to the width are another size when a bar
  /// has taken room, so they are drawn at the old size and eased to the new one, as the bar comes.
  final double Function()? pagesScale;
  const PageWithSideBars({super.key, required this.pages, this.panels, this.first, this.second, this.pagesDrop = 0, this.pagesScale});

  @override
  State<PageWithSideBars> createState() => _PageWithSideBarsState();
}

class _PageWithSideBarsState extends State<PageWithSideBars> with TickerProviderStateMixin {
  static const _slots = 3;
  late final List<AnimationController> _open;
  final List<Widget?> _last = List.filled(_slots, null);
  late final AnimationController _drop = AnimationController(vsync: this, duration: const Duration(milliseconds: 200), value: 1);
  late final Animation<double> _dropEased = CurvedAnimation(parent: _drop, curve: Curves.easeOutCubic);
  double _dropStart = 0;

  List<Widget?> get _beside => [widget.panels, widget.first, widget.second];

  @override
  void initState() {
    super.initState();
    _open = [
      for (var i = 0; i < _slots; i++)
        AnimationController(vsync: this, duration: const Duration(milliseconds: 200), value: _beside[i] == null ? 0 : 1)
          ..addStatusListener((status) {
            // (animateTo reports "completed" at the end of a slide out, so it is the value that says it is gone)
            if (!status.isAnimating && _open[i].value == 0 && _beside[i] == null && _last[i] != null) setState(() => _last[i] = null);
          }),
    ];
    for (var i = 0; i < _slots; i++) {
      _last[i] = _beside[i];
    }
  }

  @override
  void didUpdateWidget(PageWithSideBars old) {
    super.didUpdateWidget(old);
    if (old.pagesDrop != widget.pagesDrop) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _dropStart = 0;
      } else {
        // (what still shows of an earlier shift goes on from where it is)
        _dropStart = _dropStart * (1 - _dropEased.value) + old.pagesDrop - widget.pagesDrop;
        _drop.value = 0;
        _afterThisFrame(() => _drop.forward(from: 0));
      }
    }
    final now = _beside, before = [old.panels, old.first, old.second];
    for (var i = 0; i < _slots; i++) {
      if (now[i] != null) _last[i] = now[i];
      if ((now[i] != null) == (before[i] != null)) continue;
      if (MediaQuery.disableAnimationsOf(context)) {
        _open[i].value = now[i] != null ? 1.0 : 0.0;
      } else {
        _afterThisFrame(() => _open[i].animateTo(_beside[i] != null ? 1.0 : 0.0, curve: Curves.easeOutCubic));
      }
    }
  }

  /// Starts a slide once the frame that has made room for it is done: that frame lays the pages out at their final size, which can
  /// take long, and an animation that starts with it would be partly over when it first shows (or over, on a long document).
  void _afterThisFrame(VoidCallback start) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) start();
    });
  }

  @override
  void dispose() {
    for (final c in _open) {
      c.dispose();
    }
    _drop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final beside = _beside;
    return _SideBarLayout(
      shown: [for (final b in beside) b != null],
      open: _open,
      drop: _dropEased,
      dropStart: _dropStart,
      pagesScale: widget.pagesScale,
      children: [
        // (boundaries of their own, so that moving them aside draws nothing again)
        RepaintBoundary(child: widget.pages),
        for (var i = 0; i < _slots; i++) RepaintBoundary(child: beside[i] ?? _last[i] ?? const SizedBox.shrink()),
      ],
    );
  }
}

class _SideBarLayout extends MultiChildRenderObjectWidget {
  final List<bool> shown;
  final List<Animation<double>> open;
  final Animation<double> drop;
  final double dropStart;
  final double Function()? pagesScale;
  const _SideBarLayout({required this.shown, required this.open, required this.drop, required this.dropStart, this.pagesScale, required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSideBars(shown, open, drop)
    ..dropStart = dropStart
    ..pagesScale = pagesScale;

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderSideBars)
      ..shown = shown
      ..dropStart = dropStart
      ..pagesScale = pagesScale;
  }
}

class _SideBarData extends ContainerBoxParentData<RenderBox> {}

/// The children are the pages and then the three things beside them. Their layout is the final one (what is there takes its width
/// from the page); [_open] says how far each has slid in, and only where things are drawn (and hit) follows that.
class _RenderSideBars extends RenderBox with ContainerRenderObjectMixin<RenderBox, _SideBarData>, RenderBoxContainerDefaultsMixin<RenderBox, _SideBarData> {
  _RenderSideBars(this._shown, this._open, this._drop);

  List<bool> _shown;
  set shown(List<bool> value) {
    if (listEquals(value, _shown)) return;
    _shown = value;
    _shownChanged = true;
    markNeedsLayout();
  }

  double Function()? pagesScale;
  bool _shownChanged = false;
  double? _lastScale;

  /// While pages that fit the width are eased to their new size: how many times larger they were drawn at the start, and how wide
  /// the room for them was then.
  double _scaleFrom = 1, _widthFrom = 0;

  /// How far above its place the page is still drawn, and how far on its way it is: [_dropStart] of the distance goes away.
  double _dropStart = 0;
  set dropStart(double value) {
    if (value == _dropStart) return;
    _dropStart = value;
    markNeedsPaint();
  }

  final Animation<double> _drop;
  final List<Animation<double>> _open;
  final _width = [0.0, 0.0, 0.0];
  double _pagesWidth = 0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SideBarData) child.parentData = _SideBarData();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    for (final a in _open) {
      a.addListener(markNeedsPaint);
    }
    _drop.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    for (final a in _open) {
      a.removeListener(markNeedsPaint);
    }
    _drop.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final kids = getChildrenAsList();
    final total = constraints.maxWidth, height = constraints.maxHeight;
    final tall = BoxConstraints(maxWidth: total, minHeight: height, maxHeight: height);
    var taken = 0.0;
    for (var i = 0; i < _width.length; i++) {
      kids[1 + i].layout(tall, parentUsesSize: true);
      _width[i] = kids[1 + i].size.width;
      if (_shown[i]) taken += _width[i];
    }
    _pagesWidth = math.max(0, total - taken);
    kids[0].layout(BoxConstraints.tightFor(width: _pagesWidth, height: height));
    size = Size(total, height);
    // (the pages have been laid out: if the room beside them has changed, the scale they fit to has too)
    final scale = pagesScale?.call();
    if (scale != null && scale > 0) {
      final last = _lastScale;
      if (_shownChanged && last != null && (scale - last).abs() > 1e-4) {
        _scaleFrom = last / scale;
        _widthFrom = total - _width.indexed.fold(0.0, (sum, e) => sum + e.$2 * _open[e.$1].value.clamp(0.0, 1.0));
      } else if (last != null && (scale - last).abs() > 1e-4) {
        _scaleFrom = 1; // (a zoom, or a panel dragged to another width: it follows at once)
      }
      _lastScale = scale;
    }
    _shownChanged = false;
  }

  /// Where the children are drawn, with the part of each that has slid in: the pages move aside by how much the others have yet to
  /// take (or have yet to give back), by half of it, as the middle of the room they have does. What is beside them stands against
  /// the right edge, each against the next, and slide as one strip.
  ({double pages, double dy, double scale, List<double> at, List<double> left, List<double> visible, bool moving}) _look() {
    final visible = [for (var i = 0; i < _width.length; i++) _width[i] * _open[i].value.clamp(0.0, 1.0)];
    final settled = [for (var i = 0; i < _width.length; i++) _shown[i] ? _width[i] : 0.0];
    final aside = settled.fold(0.0, (a, b) => a + b) - visible.fold(0.0, (a, b) => a + b);
    final left = List.filled(_width.length, 0.0), at = List.filled(_width.length, 0.0);
    var right = size.width;
    var later = false;
    for (var i = _width.length - 1; i >= 0; i--) {
      left[i] = right - visible[i];
      // the last one that is there comes in from the edge by its front, one with another beside it on its right is cut off at the
      // front instead, so that the two go by like one strip (a bar that leaves while another comes)
      at[i] = later ? right - _width[i] : left[i];
      later = later || visible[i] > 0.01;
      right = left[i];
    }
    final dy = _dropStart * (1 - _drop.value);
    // (the room for the pages is that much wider than what they were laid out at, and the size follows it from the old to the new)
    var scale = 1.0;
    if (_scaleFrom != 1 && (_widthFrom - _pagesWidth).abs() > 0.5) {
      scale = 1 + (_scaleFrom - 1) * (aside / (_widthFrom - _pagesWidth)).clamp(0.0, 1.0);
    }
    return (
      pages: aside / 2,
      dy: dy,
      scale: scale,
      at: at,
      left: left,
      visible: visible,
      moving: aside.abs() > 0.01 || dy.abs() > 0.01 || (scale - 1).abs() > 1e-4 || [for (var i = 0; i < _width.length; i++) visible[i] > 0.01 && visible[i] < _width[i] - 0.01].contains(true),
    );
  }

  Offset _offsetOf(RenderBox child, [({double pages, double dy, double scale, List<double> at, List<double> left, List<double> visible, bool moving})? look]) {
    look ??= _look();
    final kids = getChildrenAsList();
    for (var i = 0; i < _width.length; i++) {
      if (identical(child, kids[1 + i])) return Offset(look.at[i], 0);
    }
    return Offset(look.pages, look.dy);
  }

  /// Where the pages are drawn: moved aside, down from where they stand, and larger or smaller about the middle of what they were
  /// laid out in (they stand at the top).
  Matrix4 _pagesMatrix(({double pages, double dy, double scale, List<double> at, List<double> left, List<double> visible, bool moving}) look) =>
      Matrix4.translationValues(look.pages + _pagesWidth / 2, look.dy, 0)
        ..scaleByDouble(look.scale, look.scale, 1, 1)
        ..translateByDouble(-_pagesWidth / 2, 0, 0, 1);

  @override
  void paint(PaintingContext context, Offset offset) {
    final look = _look();
    final kids = getChildrenAsList();
    void all(PaintingContext context, Offset offset) {
      if (look.scale == 1) {
        context.paintChild(kids[0], offset + _offsetOf(kids[0], look));
      } else {
        context.pushTransform(needsCompositing, offset, _pagesMatrix(look), (context, offset) => context.paintChild(kids[0], offset));
      }
      for (var i = 0; i < _width.length; i++) {
        final visible = look.visible[i];
        if (visible <= 0.01) continue;
        if (visible >= _width[i] - 0.01) {
          context.paintChild(kids[1 + i], offset + _offsetOf(kids[1 + i], look));
        } else {
          // (one on its way is cut off where the page is, and slides in from the edge)
          context.pushClipRect(needsCompositing, offset, Rect.fromLTWH(look.left[i], 0, visible, size.height), (context, offset) {
            context.paintChild(kids[1 + i], offset + _offsetOf(kids[1 + i], look));
          });
        }
      }
    }

    if (look.moving) {
      context.pushClipRect(needsCompositing, offset, Offset.zero & size, all);
    } else {
      all(context, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final look = _look();
    final kids = getChildrenAsList();
    for (var i = _width.length - 1; i >= 0; i--) {
      final visible = look.visible[i];
      if (visible <= 0.01 || position.dx < look.left[i] || position.dx >= look.left[i] + visible) continue;
      final child = kids[1 + i];
      if (result.addWithPaintOffset(offset: _offsetOf(child, look), position: position, hitTest: (r, p) => child.hitTest(r, position: p))) return true;
    }
    final pages = kids[0];
    return result.addWithPaintTransform(transform: _pagesMatrix(look), position: position, hitTest: (r, p) => pages.hitTest(r, position: p));
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (identical(child, getChildrenAsList()[0])) {
      transform.multiply(_pagesMatrix(_look()));
      return;
    }
    final o = _offsetOf(child);
    transform.translateByDouble(o.dx, o.dy, 0, 1);
  }
}
