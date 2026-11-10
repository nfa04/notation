part of 'fixed_page_note_editor.dart';

/// Guides and rulers: what is laid over the page, the handles that move it, and what a line does when it is drawn along it.
extension _EditorGuides on _FixedPageNoteEditorState {
  bool get _guidesOn => _on(Feature.guides);

  /// Whether anything is laid over the pages.
  bool get _guidesShown => _guidesOn && (_guideOverlay != GuideOverlay.none || _vanishing.isNotEmpty || _aid != null);

  /// The vanishing points on a page of [size], in page units.
  List<Offset> _vanishingOn(Size size) => [for (final v in _vanishing) Offset(v.dx * size.width, v.dy * size.height)];

  /// What the line that begins at [start] on [page] is to follow, or null: the edges of the ruler or set square if it is on this page,
  /// and the directions of the perspective drawing.
  GuideSnapper? _startSnapper(int page, Offset start, Size size) {
    if (!_guidesOn || !_snapToGuides || _shape != ShapeTool.freehand || _activeDrawTool != null) return null;
    final aid = _aid;
    final snapper = GuideSnapper(
      start,
      edges: aid != null && aid.page == page ? aid.edges : const [],
      arcs: aid != null && aid.page == page ? aid.arcs : const [],
      directions: _vanishing.isEmpty ? const [] : perspectiveDirections(start, _vanishingOn(size)),
    );
    return snapper.active ? snapper : null;
  }

  /// The point of the line for [pen], made to follow the guides. When the line only now takes up a direction, what it had is made
  /// again from its start.
  Offset _guided(DrawingStroke stroke, Offset pen) {
    final snapper = _snapper;
    if (snapper == null) return pen;
    final r = snapper.apply(pen);
    if (r.restart) {
      stroke.points
        ..clear()
        ..add(snapper.start);
      final pr = stroke.pressures;
      if (pr != null && pr.isNotEmpty) stroke.pressures = [pr.first];
      _remakeSymmetry(stroke);
    }
    return r.point;
  }

  /// Lays a ruler or set square on the page in view.
  void _placeAid(AidKind kind) {
    final (page, scrolled) = _visiblePage();
    setState(() {
      _aid = DrawingAid(kind, page, Offset(_paperWidth * 0.2, scrolled + 260), length: switch (kind) { AidKind.ruler => 420, AidKind.protractor || AidKind.circles => 180, _ => 300 });
    });
  }

  void _setPerspective(int points) => setState(() => _vanishing = defaultVanishingPoints(points));

  /// The handles above the page: one for each vanishing point, and the two of the ruler or set square (the pivot moves it, the end
  /// turns and resizes it). Everything else of the ruler is left to the pen, which draws along its edges.
  List<Widget> _guideHandles(int pageIndex, double pageHeight) {
    if (!_guidesOn || _mode != CanvasInteractionMode.draw || _currentActiveStroke != null) return const [];
    final size = Size(_paperWidth, pageHeight);
    final color = Theme.of(context).colorScheme.primary;
    final out = <Widget>[];
    Widget handle(Key key, Offset at, IconData icon, void Function(Offset delta) onDrag, {double radius = 16}) => Positioned(
          left: at.dx - radius,
          top: at.dy - radius,
          width: 2 * radius,
          height: 2 * radius,
          child: ElementDragDetector(
            key: key,
            onDragUpdate: (d) => setState(() => onDrag(d)),
            child: Container(
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle, border: Border.all(color: color.withValues(alpha: 0.8), width: 1.5)),
              child: Icon(icon, size: radius, color: color),
            ),
          ),
        );

    for (var i = 0; i < _vanishing.length; i++) {
      final at = Offset(_vanishing[i].dx * size.width, _vanishing[i].dy * size.height);
      out.add(handle(ValueKey('vanishing-$i'), at, Icons.adjust, (d) {
        final to = at + d;
        final moved = [..._vanishing];
        moved[i] = Offset((to.dx / size.width).clamp(0.0, 1.0), (to.dy / size.height).clamp(0.0, 1.0));
        _vanishing = moved;
      }, radius: 14));
    }
    final aid = _aid;
    if (aid != null && aid.page == pageIndex) {
      out.add(handle(const ValueKey('aid-pivot'), aid.origin, Icons.open_with, (d) {
        final to = aid.origin + d;
        _aid = aid.copyWith(origin: Offset(to.dx.clamp(0.0, size.width), to.dy.clamp(0.0, size.height)));
      }));
      out.add(handle(const ValueKey('aid-turn'), aid.handle, Icons.rotate_right, (d) {
        final to = aid.handle + d - aid.origin;
        _aid = aid.copyWith(angle: math.atan2(to.dy, to.dx), length: to.distance);
      }));
    }
    return out;
  }

  Widget _guidesLayer(int pageIndex, double pageHeight) {
    final size = Size(_paperWidth, pageHeight);
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: CustomPaint(
        key: const ValueKey('guides-layer'),
        painter: GuidesPainter(
          overlay: _guideOverlay,
          vanishing: _vanishingOn(size),
          aid: _aid != null && _aid!.page == pageIndex ? _aid : null,
          color: scheme.primary,
          paper: Colors.white,
        ),
        size: size,
      ),
    );
  }

  /// The menu of the drawing bar: what to lay over the pages, the ruler and set squares, and whether lines follow them.
  Widget _guidesButton() {
    final scheme = Theme.of(context).colorScheme;
    final on = _guidesShown;
    PopupMenuItem<String> header(String text) => PopupMenuItem(enabled: false, height: 32, child: Text(tr(text), style: Theme.of(context).textTheme.labelSmall));
    return PopupMenuButton<String>(
      key: const ValueKey('guides-picker'),
      tooltip: tr('Guides and rulers'),
      position: PopupMenuPosition.under,
      onSelected: (v) {
        if (v.startsWith('o:')) {
          setState(() => _guideOverlay = GuideOverlay.values.byName(v.substring(2)));
        } else if (v.startsWith('p:')) {
          _setPerspective(int.parse(v.substring(2)));
        } else if (v.startsWith('a:')) {
          final name = v.substring(2);
          if (name == 'none') {
            setState(() => _aid = null);
          } else {
            _placeAid(AidKind.values.byName(name));
          }
        } else if (v == 'snap') {
          setState(() => _snapToGuides = !_snapToGuides);
        }
      },
      itemBuilder: (context) => [
        header('Composition'),
        for (final o in GuideOverlay.values) CheckedPopupMenuItem(key: ValueKey('guide-overlay-${o.name}'), value: 'o:${o.name}', checked: _guideOverlay == o, child: Text(tr(o.label))),
        const PopupMenuDivider(),
        header('Perspective'),
        for (var n = 0; n <= 3; n++)
          CheckedPopupMenuItem(
              key: ValueKey('guide-perspective-$n'),
              value: 'p:$n',
              checked: _vanishing.length == n,
              child: Text(n == 0 ? tr('None') : tr(n == 1 ? '{n} vanishing point' : '{n} vanishing points', {'n': '$n'}))),
        const PopupMenuDivider(),
        header('Ruler and set squares'),
        CheckedPopupMenuItem(key: const ValueKey('guide-aid-none'), value: 'a:none', checked: _aid == null, child: Text(tr('None'))),
        for (final k in AidKind.values) CheckedPopupMenuItem(key: ValueKey('guide-aid-${k.name}'), value: 'a:${k.name}', checked: _aid?.kind == k, child: Text(tr(k.label))),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(key: const ValueKey('guide-snap'), value: 'snap', checked: _snapToGuides, child: Text(tr('Lines follow the guides'))),
      ],
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(shape: BoxShape.circle, color: on ? scheme.secondaryContainer : null),
        child: Icon(Icons.straighten, size: 20, color: on ? scheme.onSecondaryContainer : null),
      ),
    );
  }
}
