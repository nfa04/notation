import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';
import '../l10n/language.dart';

/// A draggable scrollbar for a long list of pages. While the thumb is held a
/// small preview of the page it points at is shown; the list only moves when
/// the thumb is let go.
class PageScrollbar extends StatefulWidget {
  final ScrollController controller;
  final int pageCount;

  /// Scrolls to the top of page [index].
  final void Function(int index) onJumpToPage;

  /// A picture of page [index], shown next to the thumb while dragging.
  final Widget Function(int index) previewBuilder;

  /// Others who have a page in view: a coloured dot with their initial beside the track, at that page.
  final List<({int page, Color color, String label})> markers;

  const PageScrollbar({
    super.key,
    this.markers = const [],
    required this.controller,
    required this.pageCount,
    required this.onJumpToPage,
    required this.previewBuilder,
  });

  @override
  State<PageScrollbar> createState() => _PageScrollbarState();
}

class _PageScrollbarState extends State<PageScrollbar> {
  static const double _thumbHeight = 64;
  static const double _grabWidth = 32;

  /// Thumb position (0 = top, 1 = bottom) while dragging, else null.
  double? _dragging;

  int _pageAt(double fraction) =>
      (fraction * (widget.pageCount - 1)).round().clamp(0, math.max(0, widget.pageCount - 1));

  double _scrolledFraction() {
    final c = widget.controller;
    // exactly one list: while a list is being replaced there can be two for a moment
    if (c.positions.length != 1) return 0;
    final position = c.positions.single;
    if (!position.hasContentDimensions) return 0;
    final max = position.maxScrollExtent;
    return max <= 0 ? 0 : (position.pixels / max).clamp(0.0, 1.0);
  }

  /// The dot of someone else, placed where their page is on the track; several on one page sit side by side.
  Widget _marker(({int page, Color color, String label}) m, int index, double travel) {
    final before = widget.markers.take(index).where((o) => o.page == m.page).length;
    final fraction = widget.pageCount < 2 ? 0.0 : m.page.clamp(0, widget.pageCount - 1) / (widget.pageCount - 1);
    // one person on two devices has one label twice (a name, or the same name and id): the key still has to tell them apart
    final sameLabel = widget.markers.take(index).where((o) => o.label == m.label).length;
    return Positioned(
      key: ValueKey(sameLabel == 0 ? 'presence-marker-${m.label}' : 'presence-marker-${m.label}-$sameLabel'),
      right: _grabWidth + 2 + before * 20,
      top: fraction * travel + (_thumbHeight - 18) / 2,
      child: Tooltip(
        message: tr('{name}: page {n}', {'name': m.label, 'n': m.page + 1}),
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: m.color, shape: BoxShape.circle),
          child: Text.verbatim(m.label.isEmpty ? '?' : m.label.characters.first.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pageCount < 2) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final travel = math.max(1.0, box.maxHeight - _thumbHeight);
      return AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final dragging = _dragging;
          final fraction = dragging ?? _scrolledFraction();
          final top = fraction * travel;
          final page = _pageAt(fraction);
          return Stack(clipBehavior: Clip.none, children: [
            if (dragging != null)
              Positioned(
                key: const ValueKey('preview-slot'),
                right: _grabWidth + 8,
                top: (top + _thumbHeight / 2 - 120).clamp(0.0, math.max(0.0, box.maxHeight - 240)),
                child: Material(
                  key: const ValueKey('page-preview'),
                  elevation: 6,
                  borderRadius: BorderRadius.circular(8),
                  color: scheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(width: 150, child: widget.previewBuilder(page)),
                      const SizedBox(height: 6),
                      Text.verbatim(tr('Page {n} / {total}', {'n': page + 1, 'total': widget.pageCount}), style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
                ),
              ),
            for (var i = 0; i < widget.markers.length; i++) _marker(widget.markers[i], i, travel),
            Positioned(
              // a stable identity: the preview comes and goes in front of it
              key: const ValueKey('thumb-slot'),
              right: 0,
              top: top,
              width: _grabWidth,
              height: _thumbHeight,
              child: Semantics(
                slider: true,
                label: tr('Pages'),
                value: tr('Page {n} of {total}', {'n': _pageAt(_scrolledFraction()) + 1, 'total': widget.pageCount}),
                increasedValue: tr('Page {n} of {total}', {'n': (_pageAt(_scrolledFraction()) + 2).clamp(1, widget.pageCount), 'total': widget.pageCount}),
                decreasedValue: tr('Page {n} of {total}', {'n': _pageAt(_scrolledFraction()).clamp(1, widget.pageCount), 'total': widget.pageCount}),
                onIncrease: () => widget.onJumpToPage((_pageAt(_scrolledFraction()) + 1).clamp(0, widget.pageCount - 1)),
                onDecrease: () => widget.onJumpToPage((_pageAt(_scrolledFraction()) - 1).clamp(0, widget.pageCount - 1)),
                child: GestureDetector(
                key: const ValueKey('page-scrollbar-thumb'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) => setState(() => _dragging = _scrolledFraction()),
                onVerticalDragUpdate: (d) =>
                    setState(() => _dragging = ((_dragging ?? 0) + d.delta.dy / travel).clamp(0.0, 1.0)),
                onVerticalDragEnd: (_) {
                  final target = _pageAt(_dragging ?? 0);
                  setState(() => _dragging = null);
                  widget.onJumpToPage(target);
                },
                onVerticalDragCancel: () => setState(() => _dragging = null),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: dragging != null ? 10 : 6,
                    height: _thumbHeight,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: dragging != null ? 0.9 : 0.45),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
              ),
            ),
          ]);
        },
      );
    });
  }
}
