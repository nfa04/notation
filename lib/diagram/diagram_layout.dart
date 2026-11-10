import 'dart:math' as math;
import 'dart:ui';

import 'diagram.dart';

/// A box placed by the layout.
class PlacedBox {
  final int node;
  final Rect rect;
  final String text;
  final Color fill, border;
  final bool bold;
  final double fontSize;
  final double radius;

  const PlacedBox({required this.node, required this.rect, required this.text, required this.fill, required this.border, this.bold = false, this.fontSize = 16, this.radius = 10});

  PlacedBox scaled(double k) => PlacedBox(node: node, rect: Rect.fromLTRB(rect.left * k, rect.top * k, rect.right * k, rect.bottom * k), text: text, fill: fill, border: border, bold: bold, fontSize: fontSize * k, radius: radius * k);
}

/// A line placed by the layout: a path to draw, optionally ending in an arrowhead.
class PlacedLine {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool arrow;

  const PlacedLine(this.points, this.color, {this.width = 2.5, this.arrow = false});

  PlacedLine scaled(double k) => PlacedLine([for (final p in points) p * k], color, width: math.max(1.5, width * k), arrow: arrow);
}

/// A label on a line, placed in the middle of it.
class PlacedLabel {
  final Offset center;
  final String text;

  const PlacedLabel(this.center, this.text);
}

/// Where everything of a diagram goes; the top left of what it covers is (0, 0).
class DiagramLayout {
  final List<PlacedBox> boxes;
  final List<PlacedLine> lines;
  final List<PlacedLabel> labels;
  final Size size;

  const DiagramLayout(this.boxes, this.lines, this.labels, this.size);

  bool get isEmpty => boxes.isEmpty;

  /// The same diagram scaled to fit in [maxWidth] (never larger than it is, never below [minScale]).
  DiagramLayout fitted(double maxWidth, {double minScale = 0.45}) {
    final k = size.width <= maxWidth ? 1.0 : math.max(minScale, maxWidth / size.width);
    if (k == 1.0) return this;
    return DiagramLayout(
      [for (final b in boxes) b.scaled(k)],
      [for (final l in lines) l.scaled(k)],
      [for (final l in labels) PlacedLabel(l.center * k, l.text)],
      size * k,
    );
  }
}

const _fontSize = 16.0;
const _branchColors = <(Color, Color)>[
  (Color(0xFFE3F2FD), Color(0xFF1E88E5)),
  (Color(0xFFE8F5E9), Color(0xFF43A047)),
  (Color(0xFFFFF3E0), Color(0xFFFB8C00)),
  (Color(0xFFF3E5F5), Color(0xFF8E24AA)),
  (Color(0xFFFFEBEE), Color(0xFFE53935)),
  (Color(0xFFE0F7FA), Color(0xFF00ACC1)),
  (Color(0xFFFFFDE7), Color(0xFFC0A100)),
  (Color(0xFFEFEBE9), Color(0xFF6D4C41)),
];

/// How big a box for [text] is: its words wrapped at about 22 characters, a line [fontSize] * 1.4 high.
Size boxSize(String text, {double fontSize = _fontSize, int wrapAt = 22, double minWidth = 90, double maxWidth = 240}) {
  final lines = wrapLabel(text, wrapAt);
  final longest = lines.fold<int>(1, (m, l) => math.max(m, l.length));
  final width = (longest * fontSize * 0.56 + 28).clamp(minWidth, maxWidth).toDouble();
  return Size(width, lines.length * fontSize * 1.4 + 22);
}

/// [text] cut into lines of at most [width] characters at spaces (a word longer than that is left whole).
List<String> wrapLabel(String text, int width) {
  final lines = <String>[];
  var current = '';
  for (final word in text.split(' ')) {
    if (current.isEmpty) {
      current = word;
    } else if (current.length + 1 + word.length <= width) {
      current = '$current $word';
    } else {
      lines.add(current);
      current = word;
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines.isEmpty ? [''] : lines;
}

/// A curve from [a] to [b] that leaves and arrives horizontally, as points.
List<Offset> _curve(Offset a, Offset b, {int steps = 16}) {
  final mid = (b.dx - a.dx) / 2;
  final c1 = Offset(a.dx + mid, a.dy), c2 = Offset(b.dx - mid, b.dy);
  return [
    for (var i = 0; i <= steps; i++)
      () {
        final t = i / steps, u = 1 - t;
        return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
      }(),
  ];
}

/// The points that draw an arrowhead at [tip] for a line arriving from [from].
List<Offset> _arrowhead(Offset from, Offset tip, {double length = 12}) {
  final d = tip - from;
  if (d.distance < 1e-6) return const [];
  final u = d / d.distance;
  Offset wing(double angle) => tip - Offset(u.dx * math.cos(angle) - u.dy * math.sin(angle), u.dx * math.sin(angle) + u.dy * math.cos(angle)) * length;
  return [wing(0.5), tip, wing(-0.5)];
}

/// A mind map: the centre in the middle, its branches going left and right, each branch in a colour of its own. The branches are
/// divided between the sides so that both are about as tall.
DiagramLayout layoutMindMap(Diagram d, {double gapX = 56, double gapY = 14}) {
  if (d.isEmpty) return const DiagramLayout([], [], [], Size.zero);
  final root = d.nodes.first;
  final sizes = {for (final n in d.nodes) n.id: boxSize(n.label, fontSize: n.id == root.id ? 18 : _fontSize)};
  final children = {for (final n in d.nodes) n.id: d.childrenOf(n.id)};

  // how tall the subtree of a node is when its children are in a column
  final heights = <int, double>{};
  double heightOf(int id) => heights[id] ??= () {
        final kids = children[id]!;
        final own = sizes[id]!.height;
        if (kids.isEmpty) return own;
        final stacked = kids.fold<double>(0, (s, k) => s + heightOf(k)) + gapY * (kids.length - 1);
        return math.max(own, stacked);
      }();

  // the branches of the root go to the side that is shorter so far
  final left = <int>[], right = <int>[];
  var hl = 0.0, hr = 0.0;
  for (final k in children[root.id]!) {
    final h = heightOf(k);
    if (hr <= hl) {
      right.add(k);
      hr += h + gapY;
    } else {
      left.add(k);
      hl += h + gapY;
    }
  }

  final boxes = <PlacedBox>[];
  final lines = <PlacedLine>[];
  final rootSize = sizes[root.id]!;

  // the widest box of each depth, so that a depth is a column
  final colWidth = <int, double>{};
  void measure(int id, int depth) {
    colWidth[depth] = math.max(colWidth[depth] ?? 0, sizes[id]!.width);
    for (final k in children[id]!) {
      measure(k, depth + 1);
    }
  }

  for (final k in children[root.id]!) {
    measure(k, 1);
  }

  // x of the left edge of a column going right (sign 1) or left (sign -1), the root's box being centred on x = 0
  final colLeft = <int, double>{};
  var x = rootSize.width / 2 + gapX;
  for (var depth = 1; colWidth.containsKey(depth); depth++) {
    colLeft[depth] = x;
    x += colWidth[depth]! + gapX;
  }

  void place(int id, int depth, double top, int side, int branch) {
    final size = sizes[id]!;
    final h = heightOf(id);
    final cy = top + h / 2;
    final w = size.width;
    final x0 = side > 0 ? colLeft[depth]! : -colLeft[depth]! - w;
    final (fill, border) = _branchColors[branch % _branchColors.length];
    final rect = Rect.fromLTWH(x0, cy - size.height / 2, w, size.height);
    boxes.add(PlacedBox(node: id, rect: rect, text: d.nodes[id].label, fill: fill, border: border, radius: 10));
    var y = top + (h - (children[id]!.fold<double>(0, (s, k) => s + heightOf(k)) + gapY * math.max(0, children[id]!.length - 1))) / 2;
    if (children[id]!.isEmpty) y = top;
    for (final k in children[id]!) {
      place(k, depth + 1, y, side, branch);
      y += heightOf(k) + gapY;
    }
  }

  void side(List<int> branches, int sign) {
    final total = branches.fold<double>(0, (s, k) => s + heightOf(k)) + gapY * math.max(0, branches.length - 1);
    var y = -total / 2;
    for (final k in branches) {
      place(k, 1, y, sign, children[root.id]!.indexOf(k));
      y += heightOf(k) + gapY;
    }
  }

  side(right, 1);
  side(left, -1);

  boxes.add(PlacedBox(
    node: root.id,
    rect: Rect.fromCenter(center: Offset.zero, width: rootSize.width, height: rootSize.height),
    text: root.label,
    fill: const Color(0xFF37474F),
    border: const Color(0xFF263238),
    bold: true,
    fontSize: 18,
    radius: 16,
  ));

  final byNode = {for (final b in boxes) b.node: b};
  for (final e in d.edges) {
    final a = byNode[e.from]!, b = byNode[e.to]!;
    final goingRight = b.rect.center.dx > a.rect.center.dx;
    final from = goingRight ? a.rect.centerRight : a.rect.centerLeft;
    final to = goingRight ? b.rect.centerLeft : b.rect.centerRight;
    lines.add(PlacedLine(_curve(from, to), b.border, width: e.from == root.id ? 3.5 : 2.5));
  }

  var bounds = boxes.first.rect;
  for (final b in boxes) {
    bounds = bounds.expandToInclude(b.rect);
  }
  final shift = Offset(-bounds.left, -bounds.top);
  return DiagramLayout(
    [for (final b in boxes) PlacedBox(node: b.node, rect: b.rect.shift(shift), text: b.text, fill: b.fill, border: b.border, bold: b.bold, fontSize: b.fontSize, radius: b.radius)],
    [for (final l in lines) PlacedLine([for (final p in l.points) p + shift], l.color, width: l.width)],
    const [],
    bounds.size,
  );
}

/// A flowchart: boxes in rows from top to bottom, every arrow going down (an arrow that would go back up is drawn to the side). The
/// row of a box is the longest way to it from a start; boxes in a row are ordered to keep the arrows from crossing much.
DiagramLayout layoutFlow(Diagram d, {double gapX = 40, double gapY = 56}) {
  if (d.isEmpty) return const DiagramLayout([], [], [], Size.zero);
  final n = d.nodes.length;
  final out = List.generate(n, (_) => <int>[]);
  final indegree = List.filled(n, 0);
  for (final e in d.edges) {
    if (e.from == e.to) continue;
    out[e.from].add(e.to);
  }

  // edges that go back (cycles) are left out of the ranking: depth-first, an edge to a node still being visited goes back
  final state = List.filled(n, 0); // 0 new, 1 on the stack, 2 done
  final back = <(int, int)>{};
  void visit(int u) {
    state[u] = 1;
    for (final v in out[u]) {
      if (state[v] == 1) {
        back.add((u, v));
      } else if (state[v] == 0) {
        visit(v);
      }
    }
    state[u] = 2;
  }

  // start from nodes nothing points to, else from the first
  final hasIn = List.filled(n, false);
  for (final e in d.edges) {
    if (e.from != e.to) hasIn[e.to] = true;
  }
  for (var i = 0; i < n; i++) {
    if (!hasIn[i] && state[i] == 0) visit(i);
  }
  for (var i = 0; i < n; i++) {
    if (state[i] == 0) visit(i);
  }

  final forward = [for (final e in d.edges) if (e.from != e.to && !back.contains((e.from, e.to))) e];
  for (final e in forward) {
    indegree[e.to]++;
  }
  final rank = List.filled(n, 0);
  final order = <int>[];
  final queue = [for (var i = 0; i < n; i++) if (indegree[i] == 0) i];
  final remaining = List.of(indegree);
  while (queue.isNotEmpty) {
    final u = queue.removeAt(0);
    order.add(u);
    for (final e in forward.where((e) => e.from == u)) {
      rank[e.to] = math.max(rank[e.to], rank[u] + 1);
      if (--remaining[e.to] == 0) queue.add(e.to);
    }
  }

  final rows = <List<int>>[];
  for (final u in order) {
    while (rows.length <= rank[u]) {
      rows.add([]);
    }
    rows[rank[u]].add(u);
  }
  // order within the rows by the mean position of the boxes pointing to them
  final posIn = List.filled(n, 0.0);
  for (var sweep = 0; sweep < 3; sweep++) {
    for (var r = 0; r < rows.length; r++) {
      if (r > 0) {
        final key = <int, double>{};
        for (final u in rows[r]) {
          final from = [for (final e in forward) if (e.to == u) posIn[e.from]];
          key[u] = from.isEmpty ? posIn[u] : from.reduce((a, b) => a + b) / from.length;
        }
        rows[r].sort((a, b) => key[a]!.compareTo(key[b]!));
      }
      for (var i = 0; i < rows[r].length; i++) {
        posIn[rows[r][i]] = i.toDouble();
      }
    }
  }

  final sizes = [for (final node in d.nodes) boxSize(node.label)];
  final rowWidth = [for (final row in rows) row.fold<double>(0, (s, u) => s + sizes[u].width) + gapX * (row.length - 1)];
  final width = rowWidth.fold<double>(0, math.max);
  final boxes = List<PlacedBox?>.filled(n, null);
  var y = 0.0;
  for (var r = 0; r < rows.length; r++) {
    final rowHeight = rows[r].fold<double>(0, (m, u) => math.max(m, sizes[u].height));
    var x = (width - rowWidth[r]) / 2;
    for (final u in rows[r]) {
      final node = d.nodes[u];
      final s = sizes[u];
      boxes[u] = PlacedBox(
        node: u,
        rect: Rect.fromLTWH(x, y + (rowHeight - s.height) / 2, s.width, s.height),
        text: node.label,
        fill: node.decision ? const Color(0xFFFFF3C4) : (rank[u] == 0 ? const Color(0xFFE8F5E9) : const Color(0xFFE3F2FD)),
        border: node.decision ? const Color(0xFFF9A825) : (rank[u] == 0 ? const Color(0xFF43A047) : const Color(0xFF1E88E5)),
        radius: node.decision ? 24 : 8,
      );
      x += s.width + gapX;
    }
    y += rowHeight + gapY;
  }

  const lineColor = Color(0xFF546E7A);
  final lines = <PlacedLine>[];
  final labels = <PlacedLabel>[];
  var extra = width; // width taken by arrows that go back, on the right
  for (final e in d.edges) {
    if (e.from == e.to) continue;
    final a = boxes[e.from]!.rect, b = boxes[e.to]!.rect;
    final isBack = back.contains((e.from, e.to));
    final List<Offset> path;
    if (isBack) {
      // out of the right side, down the right of everything, into the right side of the target
      extra += 22;
      final far = extra;
      path = [a.centerRight, Offset(far, a.centerRight.dy), Offset(far, b.centerRight.dy), b.centerRight];
    } else {
      // from the bottom of the one to the top of the other, spread along the edge when several leave or arrive
      final outs = forward.where((x) => x.from == e.from).toList(), ins = forward.where((x) => x.to == e.to).toList();
      final fx = a.left + a.width * (outs.indexOf(e) + 1) / (outs.length + 1);
      final tx = b.left + b.width * (ins.indexOf(e) + 1) / (ins.length + 1);
      final from = Offset(fx, a.bottom), to = Offset(tx, b.top);
      final bendY = b.top - gapY / 2;
      path = (to.dy - from.dy).abs() < 1 || (fx - tx).abs() < 1 ? [from, to] : [from, Offset(fx, bendY), Offset(tx, bendY), to];
    }
    final head = _arrowhead(path[path.length - 2], path.last);
    lines.add(PlacedLine([...path, ...head], lineColor, width: 2.2));
    if (e.label != null) {
      final mid = path.length == 2 ? (path.first + path.last) / 2 : (path[1] + path[2]) / 2;
      labels.add(PlacedLabel(mid, e.label!));
    }
  }
  return DiagramLayout(
    [for (final b in boxes) b!],
    lines,
    labels,
    Size(math.max(width, extra) + 8, math.max(0, y - gapY)),
  );
}

/// The layout of [d] for its kind.
DiagramLayout layoutDiagram(Diagram d) => d.kind == DiagramKind.flow ? layoutFlow(d) : layoutMindMap(d);
