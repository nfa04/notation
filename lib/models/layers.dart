import 'dart:convert';
import 'dart:ui' show Offset;

import 'canvas_models.dart';

/// The most layers a note may have.
const int maxLayers = 24;

/// One layer of a note: lines are drawn on the layer that is chosen, and a layer can be hidden, locked (what is on it cannot be
/// erased, selected or moved) and made see-through.
class NoteLayer {
  final String id;
  final String name;
  final bool visible;
  final bool locked;

  /// 0 to 1: how much of what is under it shows through the whole layer (not line by line).
  final double opacity;

  const NoteLayer(this.id, this.name, {this.visible = true, this.locked = false, this.opacity = 1});

  NoteLayer copyWith({String? name, bool? visible, bool? locked, double? opacity}) =>
      NoteLayer(id, name ?? this.name, visible: visible ?? this.visible, locked: locked ?? this.locked, opacity: (opacity ?? this.opacity).clamp(0.0, 1.0));

  /// Whether the pen, the eraser and the lasso can work on what is on it.
  bool get editable => visible && !locked;

  Map<String, Object?> toJson() => {
        'id': id,
        'n': name,
        if (!visible) 'v': false,
        if (locked) 'l': true,
        if (opacity < 1) 'o': opacity,
      };

  @override
  bool operator ==(Object other) => other is NoteLayer && other.id == id && other.name == name && other.visible == visible && other.locked == locked && other.opacity == opacity;

  @override
  int get hashCode => Object.hash(id, name, visible, locked, opacity);
}

/// The layers of a note, from the bottom one to the top one. The base layer is always among them; a line whose layer is not (it was
/// deleted, or another device has not sent it yet) is on the base layer.
class LayerStack {
  final List<NoteLayer> layers;

  const LayerStack._(this.layers);

  /// The layers of a note that has only the base layer.
  static const plain = LayerStack._([NoteLayer(baseLayerId, 'Layer 1')]);

  /// A stack of [layers]: the base layer is added at the bottom if it is not among them, and a layer named twice is kept once.
  factory LayerStack(Iterable<NoteLayer> layers) {
    final seen = <String>{};
    final list = [for (final l in layers) if (seen.add(l.id)) l];
    if (!seen.contains(baseLayerId)) list.insert(0, plain.layers.first);
    return LayerStack._(List.unmodifiable(list.take(maxLayers)));
  }

  /// Reads the layers as [toJsonText] wrote them; anything that cannot be read is the plain stack.
  factory LayerStack.fromJsonText(String? text) {
    if (text == null || text.isEmpty) return plain;
    try {
      final list = jsonDecode(text);
      if (list is! List) return plain;
      return LayerStack([
        for (final e in list)
          if (e is Map && e['id'] is String)
            NoteLayer(e['id'] as String, e['n'] is String ? e['n'] as String : '',
                visible: e['v'] != false, locked: e['l'] == true, opacity: e['o'] is num ? (e['o'] as num).toDouble().clamp(0.0, 1.0) : 1),
      ]);
    } catch (_) {
      return plain;
    }
  }

  /// The text kept in the note (null for a note with the plain stack, which is how notes from before layers are).
  String? toJsonText() => isPlain ? null : jsonEncode([for (final l in layers) l.toJson()]);

  /// Whether this is what every note has: the base layer, shown, unlocked and opaque, and nothing else (so that nothing has to be
  /// worked out when drawing).
  bool get isPlain => layers.length == 1 && layers.first == plain.layers.first;

  int get length => layers.length;

  /// The place of the layer called [id] in the stack, 0 for the bottom one; the base layer's for a layer that is not here.
  int indexOf(String id) {
    final i = layers.indexWhere((l) => l.id == id);
    return i >= 0 ? i : layers.indexWhere((l) => l.id == baseLayerId);
  }

  NoteLayer byId(String id) => layers[indexOf(id)];

  NoteLayer of(DrawingStroke s) => byId(s.layer);

  /// Whether the line can be worked on: its layer is shown and not locked.
  bool editable(DrawingStroke s) => isPlain || of(s).editable;

  bool get anySeeThrough => layers.any((l) => l.visible && l.opacity < 1);

  /// A fingerprint of everything about the layers that changes how the lines look.
  int get fingerprint => Object.hashAll(layers);

  /// [strokes] of the shown layers, the bottom layer's first (the order of drawing is kept within a layer).
  ///
  /// With [only], just those of the layers at these places in the stack.
  List<DrawingStroke> ordered(Iterable<DrawingStroke> strokes, {Set<int>? only}) {
    if (isPlain) return strokes.toList();
    final buckets = [for (final _ in layers) <DrawingStroke>[]];
    for (final s in strokes) {
      final i = indexOf(s.layer);
      if (layers[i].visible && (only == null || only.contains(i))) buckets[i].add(s);
    }
    return [for (final b in buckets) ...b];
  }

  /// The lines grouped by layer, for each shown layer that has any: the layer and its lines, bottom first.
  List<(NoteLayer, List<DrawingStroke>)> grouped(Iterable<DrawingStroke> strokes, {Set<int>? only}) {
    final buckets = [for (final _ in layers) <DrawingStroke>[]];
    for (final s in strokes) {
      buckets[indexOf(s.layer)].add(s);
    }
    return [
      for (var i = 0; i < layers.length; i++)
        if (layers[i].visible && buckets[i].isNotEmpty && (only == null || only.contains(i))) (layers[i], buckets[i]),
    ];
  }

  /// What an export draws: the lines of the shown layers in order, those of a see-through layer with the layer's opacity
  /// multiplied into their colour (an export has no groups to make see-through as a whole).
  List<DrawingStroke> forExport(Iterable<DrawingStroke> strokes) {
    if (isPlain) return strokes.toList();
    return [
      for (final (layer, list) in grouped(strokes))
        for (final s in list) layer.opacity >= 1 ? s : _faded(s, layer.opacity),
    ];
  }

  static DrawingStroke _faded(DrawingStroke s, double opacity) {
    final copy = s.copyAt(Offset.zero, author: s.author);
    return DrawingStroke(
      id: s.id,
      color: s.color.withValues(alpha: s.color.a * opacity),
      width: s.width,
      points: copy.points,
      author: s.author,
      dash: s.dash,
      fill: s.fill?.withValues(alpha: s.fill!.a * opacity),
      pressures: copy.pressures,
      brush: s.brush,
      layer: s.layer,
      gradient: s.gradient?.copyWith(end: s.gradient!.end.withValues(alpha: s.gradient!.end.a * opacity)),
      // (the text keeps the colour it is drawn in, as faint as the layer)
      label: s.label?.copyWith(color: s.label!.colorFor(s.color, s.fill).withValues(alpha: s.label!.colorFor(s.color, s.fill).a * opacity)),
    );
  }

  // ---- changes: each gives the new stack

  LayerStack added(NoteLayer layer, {int? above}) {
    if (layers.length >= maxLayers) return this;
    final list = List.of(layers);
    list.insert(above == null ? list.length : (indexOf(layers[above].id) + 1).clamp(0, list.length), layer);
    return LayerStack(list);
  }

  /// Without the layer [id] (the base layer cannot go): its lines are on the base layer from then on.
  LayerStack without(String id) => id == baseLayerId ? this : LayerStack([for (final l in layers) if (l.id != id) l]);

  LayerStack replaced(NoteLayer layer) => LayerStack([for (final l in layers) l.id == layer.id ? layer : l]);

  /// The layer [id] moved [by] places up (negative: down) the stack.
  LayerStack moved(String id, int by) {
    final from = layers.indexWhere((l) => l.id == id);
    if (from < 0) return this;
    final to = (from + by).clamp(0, layers.length - 1);
    if (to == from) return this;
    final list = List.of(layers);
    list.insert(to, list.removeAt(from));
    return LayerStack(list);
  }

  @override
  bool operator ==(Object other) => other is LayerStack && other.layers.length == layers.length && Iterable<int>.generate(layers.length).every((i) => other.layers[i] == layers[i]);

  @override
  int get hashCode => fingerprint;
}

/// What a page is made of, for putting it in order.
enum StackKind { picture, ink, box }

/// The pictures, the lines and the text boxes of one layer, in the order they lie on the page: within a layer the pictures are at
/// the bottom, the lines over them and the boxes on top.
typedef StackPart = ({StackKind kind, int layer});

/// How the things on a page lie over each other when the note has layers: the pictures, lines and boxes of the bottom layer first,
/// then those of the layer above, and so on.
///
/// Most pages need nothing special: all pictures under all lines under all boxes is the order of the layers as well, and that is
/// how a page is built (the pictures, then the lines as one picture, then the boxes, which can be touched). Only where a layer's
/// picture is over a lower layer's lines (or a box under a higher layer's lines) the rest, from there on, has to be put in order
/// one part after the other: [above].
class PageStacking {
  /// All the parts, the bottom one first (only those of shown layers that have something on this page).
  final List<StackPart> parts;

  /// How many of the first [parts] are where a page puts them without any ordering.
  final int usualCount;

  PageStacking._(this.parts, this.usualCount);

  /// The order for a page whose pictures, lines and boxes are on the layers at the places [pictures], [ink] and [boxes] of the [layers].
  factory PageStacking(LayerStack layers, {required Set<int> pictures, required Set<int> ink, required Set<int> boxes}) {
    final parts = <StackPart>[
      for (var i = 0; i < layers.length; i++)
        if (layers.layers[i].visible) ...[
          if (pictures.contains(i)) (kind: StackKind.picture, layer: i),
          if (ink.contains(i)) (kind: StackKind.ink, layer: i),
          if (boxes.contains(i)) (kind: StackKind.box, layer: i),
        ],
    ];
    var usual = 0;
    while (usual < parts.length && (usual == 0 || parts[usual].kind.index >= parts[usual - 1].kind.index)) {
      usual++;
    }
    return PageStacking._(parts, usual);
  }

  /// Whether nothing has to be put in order.
  bool get isUsual => usualCount == parts.length;

  /// The parts that are put in order, one after the other, over everything a page has in its usual places.
  late final List<StackPart> above = parts.sublist(usualCount);

  /// The layers whose [kind] of thing is in the usual place.
  Set<int> usualLayers(StackKind kind) => {
        for (final p in parts.take(usualCount))
          if (p.kind == kind) p.layer,
      };

  /// Whether the [kind] of thing of the layer at [layer] is where a page usually puts it.
  bool isUsualFor(StackKind kind, int layer) => !above.any((p) => p.kind == kind && p.layer == layer);
}
