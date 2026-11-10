import 'dart:math' as math;
import 'dart:ui';

import 'automaton.dart';
import 'diagram_layout.dart';
import 'node_link.dart';

const _normal = (Color(0xFFE3F2FD), Color(0xFF1E88E5));
const _start = (Color(0xFFE8F5E9), Color(0xFF43A047));
const _accept = (Color(0xFFFFF3E0), Color(0xFFFB8C00));
const _stray = (Color(0xFFF5F5F5), Color(0xFF9E9E9E));

/// A state diagram: the states in columns by how many steps they are from the start, a ring round the states that accept, an arrow into the
/// start, the transitions as arrows with their symbols (one arrow for all the symbols between two states), loops over the states.
DiagramLayout layoutAutomaton(Automaton a) {
  if (a.isEmpty) return const DiagramLayout([], [], [], Size.zero);
  final n = a.states.length;
  final index = {for (var i = 0; i < n; i++) a.states[i]: i};
  final root = a.start != null ? index[a.start!]! : 0;

  // the column of a state: the fewest steps from the start (states nothing leads to, in a column of their own at the end)
  final depth = List<int?>.filled(n, null);
  depth[root] = 0;
  final queue = [root];
  for (var q = 0; q < queue.length; q++) {
    final u = queue[q];
    for (final t in a.transitions.where((t) => index[t.from] == u)) {
      final v = index[t.to]!;
      if (depth[v] == null) {
        depth[v] = depth[u]! + 1;
        queue.add(v);
      }
    }
  }
  final deepest = depth.whereType<int>().fold(0, math.max);
  final strays = [for (var i = 0; i < n; i++) if (depth[i] == null) i];
  for (final i in strays) {
    depth[i] = deepest + 1;
  }
  final columns = List.generate(deepest + (strays.isEmpty ? 1 : 2), (_) => <int>[]);
  for (var i = 0; i < n; i++) {
    columns[depth[i]!].add(i);
  }

  // the order in a column: by where the states that lead to them are (two sweeps)
  final row = List.filled(n, 0.0);
  for (final c in columns) {
    for (var k = 0; k < c.length; k++) {
      row[c[k]] = k.toDouble();
    }
  }
  for (var sweep = 0; sweep < 2; sweep++) {
    for (var d = 1; d < columns.length; d++) {
      final key = <int, double>{};
      for (final v in columns[d]) {
        final from = [for (final t in a.transitions) if (index[t.to] == v && depth[index[t.from]!]! < d) row[index[t.from]!]];
        key[v] = from.isEmpty ? row[v] : from.reduce((x, y) => x + y) / from.length;
      }
      columns[d].sort((x, y) => key[x]!.compareTo(key[y]!));
      for (var k = 0; k < columns[d].length; k++) {
        row[columns[d][k]] = k.toDouble();
      }
    }
  }

  final widths = [for (final s in a.states) nodeWidth(s)];
  final colWidth = [for (final c in columns) c.isEmpty ? 0.0 : c.map((i) => widths[i]).reduce(math.max)];
  const gapX = 96.0, gapY = 92.0;
  final colX = <double>[];
  var x = 0.0;
  for (var d = 0; d < columns.length; d++) {
    x += d == 0 ? colWidth[d] / 2 : colWidth[d - 1] / 2 + gapX + colWidth[d] / 2;
    colX.add(x);
  }
  final tallest = columns.map((c) => c.length).fold(1, math.max);
  final shapes = List<NodeShape?>.filled(n, null);
  for (var d = 0; d < columns.length; d++) {
    final c = columns[d];
    for (var k = 0; k < c.length; k++) {
      final y = (k - (c.length - 1) / 2) * gapY + (tallest - 1) * gapY / 2;
      shapes[c[k]] = NodeShape(Offset(colX[d], y), widths[c[k]] / 2, 26, ring: a.accepting.contains(a.states[c[k]]));
    }
  }
  final nodes = [for (final s in shapes) s!];

  final boxes = <PlacedBox>[];
  final lines = <PlacedLine>[];
  final labels = <PlacedLabel>[];
  for (var i = 0; i < n; i++) {
    final name = a.states[i];
    final accepts = a.accepting.contains(name);
    final isStart = i == root && a.start != null;
    final (fill, border) = depth[i] == deepest + 1 && strays.contains(i) ? _stray : (accepts ? _accept : (isStart ? _start : _normal));
    final s = nodes[i];
    boxes.add(PlacedBox(node: i, rect: s.rect, text: name, fill: fill, border: isStart && !accepts ? border : border, fontSize: 16, radius: s.ry));
    if (accepts) lines.add(PlacedLine(s.outline(grow: 5), border, width: 2));
  }
  if (a.start != null) {
    final s = nodes[root];
    final from = s.center - Offset(s.rx + s.pad + 48, 0), tip = s.edgeToward(from);
    lines.add(PlacedLine([from, tip, ...arrowheadPoints(from, tip)], const Color(0xFF43A047), width: 2.4));
  }

  final pairs = {for (final t in a.transitions) (t.from, t.to)};
  var alternate = 1;
  for (final t in a.transitions) {
    final u = index[t.from]!, v = index[t.to]!;
    var bend = 0.0;
    if (u != v) {
      if (pairs.contains((t.to, t.from))) {
        bend = 24;
      } else if ((depth[v]! - depth[u]!).abs() > 1 || depth[v] == depth[u] && (row[v] - row[u]).abs() > 1) {
        bend = 38.0 * alternate;
        alternate = -alternate;
      } else if (depth[v]! < depth[u]!) {
        bend = 36;
      }
    }
    routeLink(nodes, LinkSpec(u, v, label: t.symbols.join(','), bend: bend), lines, labels);
  }
  return framed(boxes, lines, labels);
}
