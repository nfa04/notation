import 'dart:math' as math;
import 'dart:ui';

import 'diagram_layout.dart';
import 'graph.dart';
import 'node_link.dart';

/// What to show on a graph beyond its shape.
enum GraphHighlight {
  none,

  /// The shortest ways from the start, with each node's distance.
  shortest,

  /// A minimum spanning tree.
  spanning,

  /// The edges a breadth-first search uses, with the order the nodes are reached in.
  breadthFirst,

  /// The same for depth first.
  depthFirst,
}

/// Where the nodes of [g] go: a force-directed drawing (every node pushes the others away, every edge pulls its two nodes together) that
/// always comes out the same. A path or a cycle comes out a line or a ring. [spacing] is about how far apart connected nodes are.
List<Offset> graphPositions(Graph g, {double spacing = 120}) {
  final n = g.nodes.length;
  if (n == 0) return const [];
  if (n == 1) return [Offset.zero];
  final layered = _layered(g, spacing);
  if (layered != null) return layered;
  final index = {for (var i = 0; i < n; i++) g.nodes[i]: i};
  // start on a circle (a little off, so that nodes do not sit exactly on each other's lines)
  final radius = spacing * n / (2 * math.pi) + spacing / 2;
  final pos = [
    for (var i = 0; i < n; i++) Offset(math.cos(2 * math.pi * i / n + 0.3) * radius * (1 + 0.04 * (i % 3)), math.sin(2 * math.pi * i / n + 0.3) * radius * (1 + 0.04 * (i % 3))),
  ];
  final pairs = <(int, int)>{
    for (final e in g.edges)
      if (e.from != e.to) (math.min(index[e.from]!, index[e.to]!), math.max(index[e.from]!, index[e.to]!)),
  };
  final k = spacing;
  var temperature = spacing;
  for (var iteration = 0; iteration < 300; iteration++) {
    final move = List.filled(n, Offset.zero);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var d = pos[i] - pos[j];
        var dist = d.distance;
        if (dist < 1e-3) {
          d = Offset(0.01 * (i + 1), 0.01 * (j + 1));
          dist = d.distance;
        }
        final push = d / dist * (k * k / dist);
        move[i] += push;
        move[j] -= push;
      }
    }
    for (final (i, j) in pairs) {
      final d = pos[i] - pos[j];
      final dist = math.max(d.distance, 1e-3);
      final pull = d / dist * (dist * dist / k);
      move[i] -= pull;
      move[j] += pull;
    }
    for (var i = 0; i < n; i++) {
      final len = move[i].distance;
      if (len > 1e-9) pos[i] += move[i] / len * math.min(len, temperature);
    }
    temperature *= 0.985;
  }
  return pos;
}

/// Arrows that never lead back (a DAG: dependencies, a schedule): in rows from top to bottom, every arrow pointing down; a node's row is the
/// longest way to it, and the order in a row follows the nodes that lead to it. Null when there is a way round or an edge without an arrow.
List<Offset>? _layered(Graph g, double spacing) {
  final order = topologicalOrder(g);
  if (order == null) return null;
  final rank = {for (final v in order) v: 0};
  for (final v in order) {
    for (final e in g.edges.where((e) => e.from == v)) {
      rank[e.to] = math.max(rank[e.to]!, rank[v]! + 1);
    }
  }
  final rows = <List<String>>[];
  for (final v in order) {
    while (rows.length <= rank[v]!) {
      rows.add([]);
    }
    rows[rank[v]!].add(v);
  }
  final place = <String, double>{};
  for (final row in rows) {
    for (var i = 0; i < row.length; i++) {
      place[row[i]] = i.toDouble();
    }
  }
  for (var sweep = 0; sweep < 4; sweep++) {
    for (var r = 1; r < rows.length; r++) {
      final key = <String, double>{};
      for (final v in rows[r]) {
        final from = [for (final e in g.edges) if (e.to == v) place[e.from]!];
        key[v] = from.isEmpty ? place[v]! : from.reduce((a, b) => a + b) / from.length;
      }
      rows[r].sort((a, b) => key[a]!.compareTo(key[b]!));
      for (var i = 0; i < rows[r].length; i++) {
        place[rows[r][i]] = i.toDouble();
      }
    }
  }
  return [
    for (final v in g.nodes) Offset((rows[rank[v]!].indexOf(v) - (rows[rank[v]!].length - 1) / 2) * spacing * 1.1, rank[v]! * spacing * 0.8),
  ];
}

const _plain = (Color(0xFFE3F2FD), Color(0xFF1E88E5));
const _origin = (Color(0xFFE8F5E9), Color(0xFF43A047));

/// A graph drawn with [graphPositions]: round nodes, lines or arrows between them with their weights. With [highlight] the edges that matter
/// are drawn thick and orange, and the nodes carry a number (the distance, or the place in the order).
DiagramLayout layoutGraph(Graph g, {GraphHighlight highlight = GraphHighlight.none}) {
  if (g.isEmpty) return const DiagramLayout([], [], [], Size.zero);
  final positions = graphPositions(g);
  final index = {for (var i = 0; i < g.nodes.length; i++) g.nodes[i]: i};
  final from = g.origin!;
  var marked = <int>{};
  final notes = <String, String>{};
  switch (highlight) {
    case GraphHighlight.none:
      break;
    case GraphHighlight.shortest:
      final paths = shortestPaths(g, from);
      if (paths != null) {
        marked = paths.via.values.toSet();
        paths.distance.forEach((node, d) => notes[node] = weightText(d));
      }
    case GraphHighlight.spanning:
      marked = spanningTree(g).edges;
    case GraphHighlight.breadthFirst:
      final r = breadthFirst(g, from);
      marked = r.edges;
      for (var i = 0; i < r.order.length; i++) {
        notes[r.order[i]] = '${i + 1}';
      }
    case GraphHighlight.depthFirst:
      final r = depthFirst(g, from);
      marked = r.edges;
      for (var i = 0; i < r.order.length; i++) {
        notes[r.order[i]] = '${i + 1}';
      }
  }

  final shapes = [for (var i = 0; i < g.nodes.length; i++) NodeShape(positions[i], nodeWidth(g.nodes[i], minDiameter: 44) / 2, 22)];
  final boxes = <PlacedBox>[];
  final lines = <PlacedLine>[];
  final labels = <PlacedLabel>[];

  // two edges between the same nodes (and arrows that go both ways) are bent apart
  final between = <(int, int), List<int>>{};
  for (var e = 0; e < g.edges.length; e++) {
    final a = index[g.edges[e].from]!, b = index[g.edges[e].to]!;
    between.putIfAbsent((math.min(a, b), math.max(a, b)), () => []).add(e);
  }
  for (var e = 0; e < g.edges.length; e++) {
    final edge = g.edges[e];
    final a = index[edge.from]!, b = index[edge.to]!;
    final group = between[(math.min(a, b), math.max(a, b))]!;
    var bend = 0.0;
    if (group.length > 1) {
      final k = group.indexOf(e);
      bend = (k - (group.length - 1) / 2) * 30 * (a <= b ? 1 : -1);
    }
    final hot = marked.contains(e);
    routeLink(
      shapes,
      LinkSpec(a, b, label: edge.weight == null ? null : weightText(edge.weight!), arrow: edge.directed, bend: bend, color: hot ? const Color(0xFFEF6C00) : const Color(0xFF546E7A), width: hot ? 4 : 2.2),
      lines,
      labels,
    );
  }
  for (var i = 0; i < g.nodes.length; i++) {
    final (fill, border) = g.nodes[i] == from && highlight != GraphHighlight.none ? _origin : _plain;
    boxes.add(PlacedBox(node: i, rect: shapes[i].rect, text: g.nodes[i], fill: fill, border: border, radius: shapes[i].ry));
    final note = notes[g.nodes[i]];
    if (note != null) labels.add(PlacedLabel(shapes[i].center + Offset(shapes[i].rx + 6, -shapes[i].ry - 6), note));
  }
  return framed(boxes, lines, labels);
}
