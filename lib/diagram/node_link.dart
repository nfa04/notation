import 'dart:math' as math;
import 'dart:ui';

import 'diagram_layout.dart';

/// Drawing nodes and the links between them, for automata, trees and graphs: round nodes, links that end at their edge, curved when two
/// links would lie on each other, loops on a node, and arrowheads.

/// A node as drawn: an ellipse (a circle when [rx] = [ry]) round [center]. [ring] is an outer outline (a state that accepts).
class NodeShape {
  final Offset center;
  final double rx, ry;
  final bool ring;

  const NodeShape(this.center, this.rx, this.ry, {this.ring = false});

  /// How far out the outline of the node is, where links end.
  double get pad => ring ? 5 : 0;

  Rect get rect => Rect.fromCenter(center: center, width: rx * 2, height: ry * 2);

  /// The point on the outline of the node in the direction of [toward].
  Offset edgeToward(Offset toward) {
    final d = toward - center;
    if (d.distance < 1e-6) return center;
    final u = d / d.distance;
    final a = rx + pad, b = ry + pad;
    final r = 1 / math.sqrt(u.dx * u.dx / (a * a) + u.dy * u.dy / (b * b));
    return center + u * r;
  }

  /// The outline of the node as a closed path of points, [grow] larger.
  List<Offset> outline({double grow = 0, int steps = 36}) => [
        for (var i = 0; i <= steps; i++) center + Offset(math.cos(2 * math.pi * i / steps) * (rx + grow), math.sin(2 * math.pi * i / steps) * (ry + grow)),
      ];
}

/// A link from node [from] to node [to]. [bend] is how far the middle of the link is moved sideways (it is a curve then); two links between
/// the same nodes have different ones. [arrow]: an arrowhead at [to].
class LinkSpec {
  final int from, to;
  final String? label;
  final bool arrow;
  final double bend;
  final Color color;
  final double width;

  const LinkSpec(this.from, this.to, {this.label, this.arrow = true, this.bend = 0, this.color = const Color(0xFF546E7A), this.width = 2.2});
}

/// The points of the arrowhead at [tip] for a line that comes from [from].
List<Offset> arrowheadPoints(Offset from, Offset tip, {double length = 11}) {
  final d = tip - from;
  if (d.distance < 1e-6) return const [];
  final u = d / d.distance;
  Offset wing(double angle) => tip - Offset(u.dx * math.cos(angle) - u.dy * math.sin(angle), u.dx * math.sin(angle) + u.dy * math.cos(angle)) * length;
  return [wing(0.5), tip, wing(-0.5)];
}

List<Offset> _quadratic(Offset a, Offset c, Offset b, {int steps = 16}) => [
      for (var i = 0; i <= steps; i++)
        () {
          final t = i / steps, u = 1 - t;
          return a * (u * u) + c * (2 * u * t) + b * (t * t);
        }(),
    ];

List<Offset> _cubic(Offset a, Offset c1, Offset c2, Offset b, {int steps = 20}) => [
      for (var i = 0; i <= steps; i++)
        () {
          final t = i / steps, u = 1 - t;
          return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
        }(),
    ];

/// Adds the line (and the label) of [link] between the [nodes] to [lines] and [labels].
void routeLink(List<NodeShape> nodes, LinkSpec link, List<PlacedLine> lines, List<PlacedLabel> labels) {
  final a = nodes[link.from], b = nodes[link.to];
  if (link.from == link.to) {
    // a loop over the node
    Offset at(double degrees) {
      final t = degrees * math.pi / 180;
      return a.center + Offset(math.cos(t) * (a.rx + a.pad), math.sin(t) * (a.ry + a.pad));
    }

    final p0 = at(-128), p1 = at(-52);
    final c1 = p0 + const Offset(-18, -38), c2 = p1 + const Offset(18, -38);
    final points = _cubic(p0, c1, c2, p1);
    final top = p0 * 0.125 + c1 * 0.375 + c2 * 0.375 + p1 * 0.125;
    lines.add(PlacedLine([...points, if (link.arrow) ...arrowheadPoints(points[points.length - 2], p1)], link.color, width: link.width));
    if (link.label != null && link.label!.isNotEmpty) labels.add(PlacedLabel(top + const Offset(0, -12), link.label!));
    return;
  }
  final mid = (a.center + b.center) / 2;
  final dir = (b.center - a.center) / (b.center - a.center).distance;
  final normal = Offset(-dir.dy, dir.dx);
  final control = mid + normal * (2 * link.bend);
  final p0 = a.edgeToward(control), p1 = b.edgeToward(control);
  final points = link.bend == 0 ? [p0, p1] : _quadratic(p0, control, p1);
  lines.add(PlacedLine([...points, if (link.arrow) ...arrowheadPoints(points[points.length - 2], p1)], link.color, width: link.width));
  if (link.label != null && link.label!.isNotEmpty) {
    final middle = link.bend == 0 ? (p0 + p1) / 2 : p0 * 0.25 + control * 0.5 + p1 * 0.25;
    // beside the link, on the side it bends to (above a straight one)
    final side = link.bend != 0 ? (link.bend > 0 ? normal : -normal) : (normal.dy > 0 ? -normal : normal);
    labels.add(PlacedLabel(middle + side * 12, link.label!));
  }
}

/// [layout] moved so that its top left is (margin, margin), grown to hold [lines] and [labels] that lie outside the boxes.
DiagramLayout framed(List<PlacedBox> boxes, List<PlacedLine> lines, List<PlacedLabel> labels, {double margin = 12}) {
  Rect? bounds;
  void grow(Rect r) => bounds = bounds == null ? r : bounds!.expandToInclude(r);
  for (final b in boxes) {
    grow(b.rect);
  }
  for (final l in lines) {
    for (final p in l.points) {
      grow(Rect.fromLTWH(p.dx, p.dy, 0, 0));
    }
  }
  for (final l in labels) {
    grow(Rect.fromCenter(center: l.center, width: math.max(24, l.text.length * 8.0), height: 20));
  }
  final r = bounds ?? Rect.zero;
  final shift = Offset(margin - r.left, margin - r.top);
  return DiagramLayout(
    [for (final b in boxes) PlacedBox(node: b.node, rect: b.rect.shift(shift), text: b.text, fill: b.fill, border: b.border, bold: b.bold, fontSize: b.fontSize, radius: b.radius)],
    [for (final l in lines) PlacedLine([for (final p in l.points) p + shift], l.color, width: l.width, arrow: l.arrow)],
    [for (final l in labels) PlacedLabel(l.center + shift, l.text)],
    Size(r.width + 2 * margin, r.height + 2 * margin),
  );
}

/// How wide a node for [text] is: at least a circle of [minDiameter].
double nodeWidth(String text, {double fontSize = 16, double minDiameter = 52}) => math.max(minDiameter, text.length * fontSize * 0.56 + 24);
