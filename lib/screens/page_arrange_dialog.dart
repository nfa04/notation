import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';

import '../l10n/text.dart';

/// Shows all the pages of a note small, to drag into a new order (a page to the front, to the end, between two others).
///
/// [count] pages; the first [locked] of them stay where they are (the page with the written document). [thumbnail] makes the picture
/// of a page by its number now (only asked for pages that are on screen). Returns the new order, each the number of the page that is
/// there now (a page that was taken out is not in it), or null if nothing was changed or the person gave up.
Future<List<int>?> showPageArrangeDialog(
  BuildContext context, {
  required int count,
  required Future<Uint8List?> Function(int page) thumbnail,
  int locked = 0,
  int? current,
  double aspect = 1.414,
}) =>
    showDialog<List<int>>(
      context: context,
      builder: (_) => PageArrangeDialog(count: count, thumbnail: thumbnail, locked: locked, current: current, aspect: aspect),
    );

class PageArrangeDialog extends StatefulWidget {
  final int count;
  final int locked;
  final int? current;
  final double aspect;
  final Future<Uint8List?> Function(int page) thumbnail;

  const PageArrangeDialog({super.key, required this.count, required this.thumbnail, this.locked = 0, this.current, this.aspect = 1.414});

  @override
  State<PageArrangeDialog> createState() => _PageArrangeDialogState();
}

class _PageArrangeDialogState extends State<PageArrangeDialog> {
  /// Which page is at each place now.
  late final List<int> _order = List.generate(widget.count, (i) => i);

  /// The pictures, by page (null while they are being made), made one after the other.
  final Map<int, Future<Uint8List?>> _pictures = {};
  Future<void> _queue = Future.value();

  final ScrollController _scroll = ScrollController();
  Timer? _autoScroll;

  /// The page (its number as it was) that is picked up or chosen.
  int? _selected;

  /// The pages taken out (they stay in the grid, faded, until Apply, so that they can be put back).
  final Set<int> _removed = {};
  int? _dragging;

  /// The place the dragged page would be put at.
  int? _hover;

  @override
  void initState() {
    super.initState();
    _selected = widget.current;
  }

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  bool get _touch => const {TargetPlatform.android, TargetPlatform.iOS}.contains(Theme.of(context).platform);

  bool get _changed {
    if (_removed.isNotEmpty) return true;
    for (var i = 0; i < _order.length; i++) {
      if (_order[i] != i) return true;
    }
    return false;
  }

  Future<Uint8List?> _pictureOf(int page) => _pictures.putIfAbsent(page, () {
        final done = Completer<Uint8List?>();
        _queue = _queue.then((_) async {
          if (!mounted) return done.complete(null);
          try {
            done.complete(await widget.thumbnail(page));
          } catch (_) {
            done.complete(null);
          }
        });
        return done.future;
      });

  void _toggleRemoved(int page) {
    setState(() {
      if (!_removed.remove(page)) {
        // (a note keeps at least one page)
        if (_order.length - _removed.length < 2) return;
        _removed.add(page);
      }
    });
  }

  /// Puts the page [page] at place [to] (what is in between moves by one).
  void _move(int page, int to) {
    final from = _order.indexOf(page);
    to = to.clamp(widget.locked, _order.length - 1);
    if (from < widget.locked || from == to) return;
    setState(() {
      _order
        ..removeAt(from)
        ..insert(to, page);
      _selected = page;
    });
  }

  final GlobalKey _areaKey = GlobalKey();

  void _scrollWhileDragging(Offset global) {
    final box = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_scroll.hasClients) return;
    final top = box.localToGlobal(Offset.zero).dy, bottom = top + box.size.height;
    // (near the top or bottom edge of the pages shown: the closer to the edge, the faster)
    const zone = 80.0;
    final dy = global.dy < top + zone ? -(2 + 14 * ((top + zone - global.dy) / zone).clamp(0.0, 1.0)) : (global.dy > bottom - zone ? 2 + 14 * ((global.dy - (bottom - zone)) / zone).clamp(0.0, 1.0) : 0.0);
    _autoScroll?.cancel();
    if (dy == 0) return;
    _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo((_scroll.offset + dy).clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  /// A strip before the first and after the last page to drop on: to the very front or the very end.
  Widget _edge({required bool end, required double height}) {
    final scheme = Theme.of(context).colorScheme;
    final at = end ? _order.length : -1;
    return DragTarget<int>(
      key: ValueKey(end ? 'arrange-end' : 'arrange-front'),
      onWillAcceptWithDetails: (_) {
        setState(() => _hover = at);
        return true;
      },
      onLeave: (_) => setState(() => _hover = null),
      onAcceptWithDetails: (d) {
        _hover = null;
        _move(d.data, end ? _order.length - 1 : widget.locked);
      },
      builder: (_, _, _) => SizedBox(
        width: 36,
        height: height,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: _hover == at && _dragging != null ? 5 : 2,
            height: height,
            decoration: BoxDecoration(
              color: _hover == at && _dragging != null ? scheme.primary : scheme.outlineVariant.withValues(alpha: _dragging != null ? 0.8 : 0),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }

  void _stopScrolling() {
    _autoScroll?.cancel();
    _autoScroll = null;
  }

  Widget _tile(int place, double width) {
    final page = _order[place];
    final scheme = Theme.of(context).colorScheme;
    final fixed = place < widget.locked;
    final selected = _selected == page;
    final gone = _removed.contains(page);
    final number = place - _order.take(place).where(_removed.contains).length + 1;
    final height = width * widget.aspect;

    Widget face({bool lifted = false}) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 3 : 1),
            boxShadow: lifted ? const [BoxShadow(blurRadius: 12, color: Colors.black38)] : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<Uint8List?>(
            future: _pictureOf(page),
            builder: (_, snap) {
              final bytes = snap.data;
              if (bytes == null) {
                return Center(
                  child: snap.connectionState == ConnectionState.done
                      ? const Icon(Icons.description_outlined, color: Colors.black26)
                      : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }
              return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, errorBuilder: (_, _, _) => const Icon(Icons.description_outlined, color: Colors.black26));
            },
          ),
        );

    Widget label() => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.verbatim(
            gone ? '–' : '$number${page != number - 1 ? '  (${page + 1})' : ''}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontWeight: selected ? FontWeight.bold : null),
          ),
        );

    final shown = Column(mainAxisSize: MainAxisSize.min, children: [face(), label()]);
    final dropHere = _hover == place && _dragging != null && _dragging != page;

    Widget tile = SizedBox(
      width: width,
      child: GestureDetector(
        key: ValueKey('arrange-page-$page'),
        onTap: () => setState(() => _selected = _selected == page ? null : page),
        child: Stack(clipBehavior: Clip.none, children: [
          Opacity(opacity: _dragging == page ? 0.3 : (gone ? 0.35 : 1), child: shown),
          if (dropHere)
            Positioned(
              left: -6,
              top: 0,
              height: height,
              child: Container(width: 4, decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(2))),
            ),
          if (!fixed)
            Positioned(
              right: 2,
              top: 2,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  key: ValueKey('arrange-remove-$page'),
                  customBorder: const CircleBorder(),
                  onTap: () => _toggleRemoved(page),
                  child: Tooltip(
                    message: tr(gone ? 'Put the page back' : 'Remove the page'),
                    child: Padding(padding: const EdgeInsets.all(3), child: Icon(gone ? Icons.undo : Icons.close, size: 15, color: Colors.white)),
                  ),
                ),
              ),
            ),
          if (fixed) const Positioned(right: 4, top: 4, child: Icon(Icons.lock_outline, size: 16, color: Colors.black45)),
        ]),
      ),
    );

    if (!fixed && !gone) {
      void started() => setState(() {
        _dragging = page;
        _selected = page;
      });
      void ended() {
        _stopScrolling();
        setState(() {
          _dragging = null;
          _hover = null;
        });
      }

      final feedback = Transform.translate(
        offset: Offset(-width / 2, -height / 2),
        child: Material(color: Colors.transparent, child: Opacity(opacity: 0.9, child: SizedBox(width: width, child: face(lifted: true)))),
      );
      // (with a mouse a drag starts at once; on a touch screen it starts after a hold, so that a swipe still scrolls the pages)
      tile = _touch
          ? LongPressDraggable<int>(
              data: page,
              delay: const Duration(milliseconds: 150),
              dragAnchorStrategy: pointerDragAnchorStrategy,
              onDragStarted: started,
              onDragUpdate: (d) => _scrollWhileDragging(d.globalPosition),
              onDragEnd: (_) => ended(),
              feedback: feedback,
              child: tile,
            )
          : Draggable<int>(
              data: page,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              onDragStarted: started,
              onDragUpdate: (d) => _scrollWhileDragging(d.globalPosition),
              onDragEnd: (_) => ended(),
              feedback: feedback,
              child: tile,
            );
    }

    return DragTarget<int>(
      key: ValueKey('arrange-slot-$place'),
      onWillAcceptWithDetails: (_) {
        if (!fixed) setState(() => _hover = place);
        return !fixed;
      },
      onLeave: (_) => setState(() => _hover = null),
      onAcceptWithDetails: (d) {
        _hover = null;
        _move(d.data, place);
      },
      builder: (_, _, _) => tile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final selectedPlace = _selected == null ? -1 : _order.indexOf(_selected!);
    final canMove = selectedPlace >= widget.locked;
    final width = size.width < 520 ? 92.0 : 120.0;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 860, maxHeight: size.height - 32),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Arrange pages', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'Drag a page to where it should be. A tap chooses a page, to send it to the front or the end or to remove it. Nothing changes before Apply.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  key: _areaKey,
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 10,
                    children: [
                      if (widget.locked == 0) _edge(end: false, height: width * widget.aspect),
                      for (var place = 0; place < _order.length; place++) _tile(place, width),
                      _edge(end: true, height: width * widget.aspect),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                key: const ValueKey('arrange-to-front'),
                onPressed: canMove && selectedPlace > widget.locked ? () => _move(_selected!, widget.locked) : null,
                icon: const Icon(Icons.first_page, size: 18),
                label: const Text('To the front'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('arrange-to-end'),
                onPressed: canMove && selectedPlace < _order.length - 1 ? () => _move(_selected!, _order.length - 1) : null,
                icon: const Icon(Icons.last_page, size: 18),
                label: const Text('To the end'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('arrange-remove'),
                onPressed: canMove && !_removed.contains(_selected) && _order.length - _removed.length > 1 ? () => _toggleRemoved(_selected!) : null,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Remove'),
              ),
              OutlinedButton(
                key: const ValueKey('arrange-reset'),
                onPressed: _changed ? () => setState(() {
                  _order.sort();
                  _removed.clear();
                }) : null,
                child: const Text('Reset'),
              ),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('arrange-apply'),
                onPressed: _changed ? () => Navigator.pop(context, [for (final p in _order) if (!_removed.contains(p)) p]) : null,
                child: const Text('Apply'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
