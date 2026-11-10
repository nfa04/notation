part of 'fixed_page_note_editor.dart';

/// Something on a page a connector can be fixed to: a text box, a picture or a closed shape.
typedef _ConnectItem = ({String id, Rect rect});

/// A place on an item where a connector begins or ends: the item, the side, and the item's frame.
typedef _ConnectHit = ({String id, Anchor anchor, Rect rect});

/// How near (in page units) a pen must be to the dot of a side to take that side, and not leave the choice to the connector.
const _anchorReach = 18.0;

/// The dots on the sides of the items of a page while the connector tool is in use, and a frame round the one the line is over.
class _ConnectorHandles extends CustomPainter {
  final List<_ConnectItem> items;
  final String? Function() over;
  final Color color;

  /// The selected connector, whose two ends get a handle to pull (null: none).
  final DrawingStroke? Function()? ends;

  _ConnectorHandles(this.items, this.over, this.color, {required Listenable repaint, this.ends}) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final target = over();
    final fill = Paint()..color = Colors.white;
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final item in items) {
      if (item.id == target) {
        canvas.drawRRect(RRect.fromRectAndRadius(item.rect.inflate(3), const Radius.circular(6)), ring..strokeWidth = 2.5);
        ring.strokeWidth = 2;
      }
      for (final a in const [Anchor.top, Anchor.right, Anchor.bottom, Anchor.left]) {
        final at = a.on(item.rect);
        canvas.drawCircle(at, 6, fill);
        canvas.drawCircle(at, 6, ring);
      }
    }
    _paintEnds(canvas, ring);
  }

  void _paintEnds(Canvas canvas, Paint ring) {
    final link = ends?.call()?.link;
    if (link == null) return;
    final fill = Paint()..color = color;
    for (final p in [link.from.point, link.to.point]) {
      canvas.drawCircle(p, 8, fill);
      canvas.drawCircle(p, 8, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_ConnectorHandles old) => old.items != items || old.color != color;
}

/// Connectors: lines that are fixed to two items (text boxes, pictures, shapes) and follow them when they move, for mind maps and
/// flowcharts. A connector is a line of the page like any other (it is drawn, erased, selected and saved as one); its [DrawingStroke.link]
/// says what it is fixed to, and its points are made again from where the items are.
extension _EditorConnectors on _FixedPageNoteEditorState {
  /// The connector tool is chosen and the pen draws.
  bool get _connecting => _mode == CanvasInteractionMode.draw && _shape == ShapeTool.connector && !_erasing && !_lassoing && _activeDrawTool == null;

  /// A box was grown from the side of another one a moment ago: the tap that did it is still to be told apart from a double tap, and
  /// then reaches the page, which must not take the new box's selection away.
  bool get _justGrewBox => _grewBoxAt != null && DateTime.now().difference(_grewBoxAt!) < const Duration(seconds: 1);

  /// The items of [page] a connector can be fixed to, the top-most last: pictures, closed shapes, then text boxes.
  List<_ConnectItem> _connectItems(int page) {
    final out = <_ConnectItem>[];
    for (final m in _imagesPerPage[page] ?? const <ImageItem>[]) {
      out.add((id: m.id, rect: m.position & m.size));
    }
    for (final s in _strokesPerPage[page] ?? const <DrawingStroke>[]) {
      if (s.link != null || !s.isClosed || identical(s, _currentActiveStroke)) continue;
      var r = Rect.fromPoints(s.points.first, s.points.first);
      for (final p in s.points) {
        r = r.expandToInclude(Rect.fromPoints(p, p));
      }
      if (r.width >= smallestShape && r.height >= smallestShape) out.add((id: s.id, rect: r));
    }
    for (final b in _textBoxesPerPage[page] ?? const <TextBoxWidgetModel>[]) {
      if (!_inGutter(b)) out.add((id: b.id, rect: _boxRect(b)));
    }
    return out;
  }

  /// The connector that is the whole selection, on [page] (null: none, or the layer is locked).
  DrawingStroke? _selectedConnectorOn(int page) {
    if (_selectedStrokePage != page || _selection.length != 1 || _groupBoxes.isNotEmpty || _groupImages.isNotEmpty) return null;
    final s = _selection.first;
    return s.link != null && s.link!.isLinked && _layers.editable(s) ? s : null;
  }

  /// A handle on each end of the selected connector, to pull it to another item. They are above the text boxes and pictures, whose
  /// edges the ends lie on.
  List<Widget> _connectorEndHandles(int page) {
    final s = _selectedConnectorOn(page);
    if (s == null || _connecting) return const [];
    const half = 22.0;
    final link = s.link!;
    return [
      for (final start in const [true, false])
        () {
          final centre = start ? link.from.point : link.to.point;
          return Positioned(
            key: ValueKey('connector-end-${start ? 'from' : 'to'}'),
            left: centre.dx - half,
            top: centre.dy - half,
            width: half * 2,
            height: half * 2,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) {
                _endGrab = (stroke: s, start: start, link: s.link!, points: List.of(s.points));
                _connectOver = null;
              },
              onPointerMove: (e) => _connectorEndMove(page, centre + (e.localPosition - const Offset(half, half))),
              onPointerUp: (_) => _connectorEndUp(page),
              onPointerCancel: (_) => _connectorEndCancel(page),
            ),
          );
        }(),
    ];
  }

  /// The end follows the pen and snaps to the item it is over (not the one the other end is on).
  void _connectorEndMove(int page, Offset p) {
    final grab = _endGrab;
    if (grab == null) return;
    final other = grab.start ? grab.link.to : grab.link.from;
    final over = _connectHitAt(page, p, except: other.item);
    final end = over == null ? LinkEnd.free(p) : LinkEnd.to(over.id, anchor: over.anchor);
    final link = grab.start ? grab.link.copyWith(from: end) : grab.link.copyWith(to: end);
    final rects = {for (final i in _connectItems(page)) i.id: i.rect};
    final routed = routeLink(link, (id) => rects[id]);
    grab.stroke
      ..points.clear()
      ..points.addAll(routed.points)
      ..pressures = null
      ..link = routed.link;
    _connectOver = over;
    _connectorSeen.remove(grab.stroke.id);
    _inkTick.value++;
  }

  /// The pen is lifted: the new end stays (one step to take back). A line left with both ends free is a plain arrow.
  void _connectorEndUp(int page) {
    final grab = _endGrab;
    _endGrab = null;
    _connectOver = null;
    if (grab == null) return;
    final s = grab.stroke;
    if (s.link != null && !s.link!.isLinked) s.link = null;
    final link = s.link, points = List.of(s.points);
    if (link == grab.link && points.length == grab.points.length) {
      setState(() {});
      return;
    }
    void put(StrokeLink? l, List<Offset> pts) {
      s
        ..link = l
        ..points.clear()
        ..points.addAll(pts);
      s.pressures = null;
      _connectorSeen.remove(s.id);
    }

    setState(() => _undoStack.push(UndoStep(() => put(grab.link, grab.points), () => put(link, points))));
    _scheduleSave();
  }

  /// The pen was taken away by the system: the connector goes back to how it was.
  void _connectorEndCancel(int page) {
    final grab = _endGrab;
    if (grab == null) return;
    _endGrab = null;
    _connectOver = null;
    grab.stroke
      ..link = grab.link
      ..points.clear()
      ..points.addAll(grab.points);
    _connectorSeen.remove(grab.stroke.id);
    _inkTick.value++;
  }

  /// The side of [rect] whose dot is within reach of [p]; auto when none is (the connector then picks the side).
  Anchor _anchorNear(Rect rect, Offset p) {
    Anchor best = Anchor.auto;
    var bestDistance = _anchorReach;
    for (final a in const [Anchor.top, Anchor.right, Anchor.bottom, Anchor.left]) {
      final d = (a.on(rect) - p).distance;
      if (d <= bestDistance) {
        best = a;
        bestDistance = d;
      }
    }
    return best;
  }

  /// The top-most item of [page] at [p] (a little outside it counts, as the dots are on its edge), except [except].
  _ConnectHit? _connectHitAt(int page, Offset p, {String? except}) {
    final items = _connectItems(page);
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item.id == except) continue;
      if (item.rect.inflate(_anchorReach).contains(p)) return (id: item.id, anchor: _anchorNear(item.rect, p), rect: item.rect);
    }
    return null;
  }

  /// The line from [start] to [end] with the ends fixed to the items there (where the pen went down, kept in [_connectFrom], and
  /// at [end]). With no item at either end it is an arrow, with no link.
  ({List<Offset> points, StrokeLink? link, _ConnectHit? over}) _connectorBetween(int page, Offset start, Offset end) {
    final from = _connectFrom;
    final over = _connectHitAt(page, end, except: from?.id);
    if (from == null && over == null) {
      return (points: shapePoints(ShapeTool.arrow, start, end, constrain: HardwareKeyboard.instance.isShiftPressed), link: null, over: null);
    }
    final link = StrokeLink(
      from: from == null ? LinkEnd.free(start) : LinkEnd.to(from.id, anchor: from.anchor),
      to: over == null ? LinkEnd.free(end) : LinkEnd.to(over.id, anchor: over.anchor),
      route: _connectorRoute,
    );
    final rects = {for (final i in _connectItems(page)) i.id: i.rect};
    final routed = routeLink(link, (id) => rects[id]);
    return (points: routed.points, link: routed.link, over: over);
  }

  /// The pen moves with the connector tool: the line follows it, and snaps to the item it is over.
  void _previewConnector(int page, DrawingStroke stroke, Offset end) {
    final made = _connectorBetween(page, _shapeStart, end);
    _connectOver = made.over;
    stroke.points
      ..clear()
      ..addAll(made.points);
  }

  /// The pen is lifted: the line is a connector if it joins an item.
  void _finishConnector(int page, DrawingStroke stroke, Offset end) {
    final made = _connectorBetween(page, _shapeStart, end);
    stroke.points
      ..clear()
      ..addAll(made.points);
    stroke.link = made.link;
    _connectFrom = null;
    _connectOver = null;
  }

  /// A short tap on the dot of a side of an item with the connector tool: a new box grows out of that side, joined by a connector
  /// (mind maps are made by tapping the dot, typing, and tapping the next). One step to take back.
  void _growBoxFrom(int page, _ConnectHit from) {
    final source = _lastWhere(_textBoxesPerPage[page] ?? const <TextBoxWidgetModel>[], (b) => b.id == from.id);
    final width = source?.size.width ?? 200.0;
    const gap = 70.0, height = 44.0;
    final r = from.rect;
    final topLeft = switch (from.anchor) {
      Anchor.right => Offset(r.right + gap, r.center.dy - height / 2),
      Anchor.left => Offset(r.left - gap - width, r.center.dy - height / 2),
      Anchor.top => Offset(r.center.dx - width / 2, r.top - gap - height),
      _ => Offset(r.center.dx - width / 2, r.bottom + gap),
    };
    final position = Offset(
      topLeft.dx.clamp(0.0, math.max(0.0, _paperWidth - width)),
      topLeft.dy.clamp(0.0, math.max(0.0, _heightOf(page) - height)),
    );
    final box = TextBoxWidgetModel(
      id: newElementId(),
      position: position,
      size: Size(width, 0),
      fontSize: source?.fontSize ?? 16.0,
      style: source?.style ?? TextBoxStyle.defaults,
      author: Authorship.current,
      layer: source?.layer ?? _placeLayer,
    );
    _attachBox(box);
    final rects = {for (final i in _connectItems(page)) i.id: i.rect, box.id: position & Size(width, height)};
    final link = StrokeLink(from: LinkEnd.to(from.id, anchor: from.anchor), to: LinkEnd.to(box.id), route: _connectorRoute);
    final routed = routeLink(link, (id) => rects[id]);
    final line = DrawingStroke(color: _selectedPenColor, width: _strokeWidth, points: routed.points, author: Authorship.current, dash: _shapeDash, link: routed.link, layer: _placeLayer);
    _textBoxesPerPage.putIfAbsent(page, () => []).add(box);
    _strokesPerPage.putIfAbsent(page, () => []).add(line);
    // it is typed in at once
    _grewBoxAt = DateTime.now();
    _activeSelectedBox = box;
    box.focusNode.requestFocus();
    _undoStack.push(UndoStep(
      () {
        _textBoxesPerPage[page]?.remove(box);
        _strokesPerPage[page]?.remove(line);
        if (_activeSelectedBox == box) _activeSelectedBox = null;
      },
      () {
        _textBoxesPerPage.putIfAbsent(page, () => []).add(box);
        _strokesPerPage.putIfAbsent(page, () => []).add(line);
      },
    ));
    _scheduleSave();
  }

  /// Makes the connectors of [page] follow their items: those whose items are not where they were when the line was last made are
  /// routed again. (A line seen for the first time keeps its points, as saved: another device may have laid the text out a little
  /// differently, and the two would otherwise keep correcting each other.)
  void _syncConnectors(int page) {
    final strokes = _strokesPerPage[page];
    if (strokes == null) return;
    Map<String, Rect>? rects;
    for (final s in strokes) {
      final link = s.link;
      if (link == null || !link.isLinked || identical(s, _currentActiveStroke)) continue;
      rects ??= {for (final i in _connectItems(page)) i.id: i.rect};
      final key = Object.hashAll([for (final id in link.items) rects[id]]);
      final seen = _connectorSeen[s.id];
      _connectorSeen[s.id] = key;
      if (seen == null || seen == key) continue;
      final routed = routeLink(link, (id) => rects![id]);
      s.points
        ..clear()
        ..addAll(routed.points);
      s.pressures = null;
      s.link = routed.link;
    }
  }

  /// Makes the connector [s] again from where its items are now (after its route or arrowheads changed).
  void _rerouteConnector(int page, DrawingStroke s, StrokeLink link) {
    final rects = {for (final i in _connectItems(page)) i.id: i.rect};
    final routed = routeLink(link, (id) => rects[id]);
    s.points
      ..clear()
      ..addAll(routed.points);
    s.link = routed.link;
    _connectorSeen.remove(s.id);
  }

  /// Changes how the selected connectors run or end (one step to take back): [change] gives the new link for the old one.
  void _changeConnectors(StrokeLink Function(StrokeLink) change) {
    final page = _selectedStrokePage;
    final lines = [for (final s in _selection) if (s.link != null) s];
    if (lines.isEmpty) return;
    final before = [for (final s in lines) (link: s.link!, points: List.of(s.points))];
    final after = <({StrokeLink link, List<Offset> points})>[];
    setState(() {
      for (final s in lines) {
        _rerouteConnector(page, s, change(s.link!));
        after.add((link: s.link!, points: List.of(s.points)));
      }
      void put(List<({StrokeLink link, List<Offset> points})> to) {
        for (var i = 0; i < lines.length; i++) {
          lines[i]
            ..link = to[i].link
            ..points.clear()
            ..points.addAll(to[i].points);
          _connectorSeen.remove(lines[i].id);
        }
      }

      _undoStack.push(UndoStep(() => put(before), () => put(after)));
    });
    _scheduleSave();
  }

  /// The icon of a way for a connector to run.
  static IconData _routeIcon(ConnectorRoute route) => switch (route) {
        ConnectorRoute.straight => Icons.call_made,
        ConnectorRoute.elbow => Icons.subdirectory_arrow_right,
        ConnectorRoute.curve => Icons.moving,
      };

  /// Chooses how the next connectors run, or (for [forSelection]) how the selected ones do.
  Widget _routeButton({bool forSelection = false}) {
    final lines = [for (final s in _selection) if (s.link != null) s];
    final current = forSelection ? lines.first.link!.route : _connectorRoute;
    return PopupMenuButton<Object>(
      key: ValueKey(forSelection ? 'connector-route-selection' : 'connector-route'),
      tooltip: tr('Connector: {route}', {'route': tr(current.label)}),
      position: PopupMenuPosition.under,
      icon: Icon(_routeIcon(current), size: 20),
      onSelected: (v) {
        if (v is ConnectorRoute) {
          if (forSelection) {
            _changeConnectors((l) => l.copyWith(route: v));
          } else {
            setState(() => _connectorRoute = v);
          }
        } else if (v == 'end') {
          _changeConnectors((l) => l.copyWith(arrowAtEnd: !l.arrowAtEnd));
        } else if (v == 'start') {
          _changeConnectors((l) => l.copyWith(arrowAtStart: !l.arrowAtStart));
        }
      },
      itemBuilder: (context) => [
        for (final r in ConnectorRoute.values)
          PopupMenuItem<Object>(
            key: ValueKey('connector-route-${r.name}'),
            value: r,
            child: Row(children: [Icon(_routeIcon(r), size: 20), const SizedBox(width: 12), Text(tr(r.label))]),
          ),
        if (forSelection) ...[
          const PopupMenuDivider(),
          CheckedPopupMenuItem<Object>(key: const ValueKey('connector-arrow-end'), value: 'end', checked: lines.first.link!.arrowAtEnd, child: Text(tr('Arrowhead at the end'))),
          CheckedPopupMenuItem<Object>(key: const ValueKey('connector-arrow-start'), value: 'start', checked: lines.first.link!.arrowAtStart, child: Text(tr('Arrowhead at the start'))),
        ],
      ],
    );
  }
}
