part of 'fixed_page_note_editor.dart';

/// One thing that is lined up: a text box, a picture, the drawings that lie over each other (a shape with its lines is one thing), or
/// everything that is in one group.
class _ArrangeUnit {
  Rect bounds;
  final List<DrawingStroke> strokes;
  final List<TextBoxWidgetModel> boxes;
  final List<ImageItem> images;

  _ArrangeUnit(this.bounds, {List<DrawingStroke>? strokes, List<TextBoxWidgetModel>? boxes, List<ImageItem>? images})
      : strokes = strokes ?? [],
        boxes = boxes ?? [],
        images = images ?? [];

  Set<String> get groups => {
        for (final s in strokes)
          if (s.group != noGroup) s.group,
        for (final b in boxes)
          if (b.group != noGroup) b.group,
        for (final m in images)
          if (m.group != noGroup) m.group,
      };
}

/// Aligning and distributing what is selected.
extension _EditorArrange on _FixedPageNoteEditorState {
  /// Whether anything can be lined up: the selection has more than one thing in it.
  bool get _mayArrange => _on(Feature.arrange) && _selection.length + _groupBoxes.length + _groupImages.length >= 2;

  /// The things of the selection, each with the box it fills. (A connector goes with what it joins: it is not lined up itself.)
  List<_ArrangeUnit> _arrangeUnits() {
    final strokes = [for (final s in _selection) if (s.points.isNotEmpty && s.link == null) s];
    Rect boxOf(DrawingStroke s) {
      var r = Rect.fromPoints(s.points.first, s.points.first);
      for (final p in s.points) {
        r = r.expandToInclude(Rect.fromPoints(p, p));
      }
      return r;
    }

    final rects = [for (final s in strokes) boxOf(s)];
    final units = [
      for (final group in overlapGroups(rects))
        _ArrangeUnit(group.map((i) => rects[i]).reduce((a, b) => a.expandToInclude(b)), strokes: [for (final i in group) strokes[i]]),
      for (final b in _groupBoxes) _ArrangeUnit(_boxRect(b), boxes: [b]),
      for (final m in _groupImages) _ArrangeUnit(m.position & m.size, images: [m]),
    ];
    // the members of a group are one thing, wherever they lie
    final merged = <_ArrangeUnit>[];
    for (final u in units) {
      final same = merged.where((m) => m.groups.intersection(u.groups).isNotEmpty).toList();
      if (same.isEmpty) {
        merged.add(u);
        continue;
      }
      final into = same.first;
      for (final other in [...same.skip(1), u]) {
        into.bounds = into.bounds.expandToInclude(other.bounds);
        into.strokes.addAll(other.strokes);
        into.boxes.addAll(other.boxes);
        into.images.addAll(other.images);
        merged.remove(other);
      }
    }
    return merged;
  }

  /// Lines the things of the selection up ([to]) or spaces them evenly ([horizontal]: in a row, else in a column), as one step to take back.
  void _arrangeSelection({AlignTo? to, bool? horizontal}) {
    final units = _arrangeUnits();
    final rects = [for (final u in units) u.bounds];
    final deltas = to != null ? alignDeltas(rects, to) : distributeDeltas(rects, horizontal: horizontal ?? true);
    if (deltas.every((d) => d == Offset.zero)) return;
    final strokes = [for (final u in units) ...u.strokes];
    final boxes = [for (final u in units) ...u.boxes];
    final images = [for (final u in units) ...u.images];
    final before = (points: [for (final s in strokes) List.of(s.points)], boxes: [for (final b in boxes) b.position], images: [for (final m in images) m.position]);
    setState(() {
      for (var i = 0; i < units.length; i++) {
        final d = deltas[i];
        for (final s in units[i].strokes) {
          for (var k = 0; k < s.points.length; k++) {
            s.points[k] += d;
          }
        }
        for (final b in units[i].boxes) {
          b.position += d;
        }
        for (final m in units[i].images) {
          m.position += d;
        }
      }
    });
    final after = (points: [for (final s in strokes) List.of(s.points)], boxes: [for (final b in boxes) b.position], images: [for (final m in images) m.position]);
    void put(({List<List<Offset>> points, List<Offset> boxes, List<Offset> images}) at) {
      setState(() {
        for (var i = 0; i < strokes.length; i++) {
          strokes[i].points
            ..clear()
            ..addAll(at.points[i]);
        }
        for (var i = 0; i < boxes.length; i++) {
          boxes[i].position = at.boxes[i];
        }
        for (var i = 0; i < images.length; i++) {
          images[i].position = at.images[i];
        }
      });
    }

    _undoStack.push(UndoStep(() => put(before), () => put(after)));
    _scheduleSave();
  }

  /// The button of the selection's tools that opens the menu of aligning and distributing.
  Widget _arrangeButton() {
    PopupMenuEntry<String> item(String name, IconData icon, String label, {bool enabled = true}) => PopupMenuItem(
          key: ValueKey('arrange-$name'),
          value: name,
          enabled: enabled,
          child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Flexible(child: Text(tr(label), overflow: TextOverflow.ellipsis))]),
        );
    return PopupMenuButton<String>(
      key: const ValueKey('arrange-selection'),
      tooltip: tr('Align and distribute'),
      icon: const Icon(Icons.align_horizontal_left),
      padding: EdgeInsets.zero,
      iconSize: 24,
      onSelected: (name) {
        final to = AlignTo.values.where((a) => a.name == name).firstOrNull;
        if (to != null) return _arrangeSelection(to: to);
        _arrangeSelection(horizontal: name == 'spaceAcross');
      },
      itemBuilder: (context) {
        final units = _arrangeUnits().length;
        return [
          item('left', Icons.align_horizontal_left, 'Align left', enabled: units >= 2),
          item('centre', Icons.align_horizontal_center, 'Align centres', enabled: units >= 2),
          item('right', Icons.align_horizontal_right, 'Align right', enabled: units >= 2),
          item('top', Icons.align_vertical_top, 'Align tops', enabled: units >= 2),
          item('middle', Icons.align_vertical_center, 'Align middles', enabled: units >= 2),
          item('bottom', Icons.align_vertical_bottom, 'Align bottoms', enabled: units >= 2),
          const PopupMenuDivider(),
          item('spaceAcross', Icons.horizontal_distribute, 'Space evenly across', enabled: units >= 3),
          item('spaceDown', Icons.vertical_distribute, 'Space evenly down', enabled: units >= 3),
        ];
      },
    );
  }
}
