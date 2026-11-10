import 'dart:ui';

import '../models/canvas_models.dart';
import '../models/rich_text.dart';
import 'diagram_layout.dart';

/// What a [DiagramLayout] becomes on a page: its boxes and labels as text boxes, its lines as strokes. [origin] is where the layout's
/// top left goes.
({List<TextBoxWidgetModel> boxes, List<DrawingStroke> strokes}) placeLayout(
  DiagramLayout layout,
  Offset origin, {
  String? author,
  String layer = baseLayerId,
}) {
  final boxes = <TextBoxWidgetModel>[];
  for (final b in layout.boxes) {
    final dark = b.fill.computeLuminance() < 0.3;
    final box = TextBoxWidgetModel(
      id: newElementId(),
      position: b.rect.topLeft + origin,
      size: b.rect.size,
      initialText: b.text,
      fontSize: b.fontSize,
      style: TextBoxStyle(background: b.fill, opacity: 1, borderColor: b.border, borderWidth: 2, radius: b.radius, textColor: dark ? const Color(0xFFFFFFFF) : const Color(0xDD000000)),
      author: author,
      layer: layer,
    );
    if (b.bold) box.controller.attributes.add(TextSpanAttribute(start: 0, end: b.text.length, type: AttributeType.bold));
    boxes.add(box);
  }
  for (final l in layout.labels) {
    final size = Size(l.text.length * 8.0 + 12 < 40 ? 40.0 : l.text.length * 8.0 + 12, 26);
    boxes.add(TextBoxWidgetModel(
      id: newElementId(),
      position: l.center - Offset(size.width / 2, size.height / 2) + origin,
      size: size,
      initialText: l.text,
      fontSize: 13,
      style: const TextBoxStyle(opacity: 0, borderWidth: 0),
      author: author,
      layer: layer,
    ));
  }
  final strokes = [
    for (final l in layout.lines) DrawingStroke(color: l.color, width: l.width, points: [for (final p in l.points) p + origin], author: author, layer: layer),
  ];
  return (boxes: boxes, strokes: strokes);
}
