import 'dart:math' as math;
import 'dart:typed_data';

import 'graph_model.dart';

/// Gives every node of [graph] a place. A force-directed layout (Fruchterman-Reingold) that starts from a seed in which each
/// topic has a place of its own on a spiral, so that it settles in few steps; the nodes push each other away only when they are
/// in neighbouring cells of a grid, which keeps a step linear in the number of nodes. Deterministic.
///
/// It stops early once the nodes hardly move, and ends with a pass that pushes apart nodes whose dots would touch.
///
/// [start] holds places from an earlier layout, by node id (see [placesOf]). A node found there begins where it was, one that is not
/// begins among its neighbours that are, and the run is gentle (it starts cool), so that a graph made again looks like the one it
/// replaces and only what is new finds its place. Topic hubs are not taken over: their ids are numbers that change between runs.
void layoutGraph(KnowledgeGraph graph, {int iterations = 150, Map<String, (double, double)>? start}) {
  final n = graph.nodes.length;
  if (n == 0) return;
  final xs = Float64List(n), ys = Float64List(n);
  final random = math.Random(7);
  final side = math.sqrt(n) * 110.0 + 200;
  final k = math.sqrt(side * side / n) * 0.9; // the natural distance of two joined nodes

  // seed: the centre of a topic on a spiral, its nodes around it
  final centres = <int, math.Point<double>>{};
  final clusterCount = graph.clusters.length;
  for (var c = 0; c < clusterCount; c++) {
    final r = k * 2.6 * math.sqrt(c + 0.5);
    final a = c * 2.399963; // the golden angle
    centres[c] = math.Point(r * math.cos(a), r * math.sin(a));
  }
  final inCluster = <int, int>{};
  for (final node in graph.nodes) {
    inCluster[node.cluster] = (inCluster[node.cluster] ?? 0) + 1;
  }
  for (var i = 0; i < n; i++) {
    final node = graph.nodes[i];
    final centre = centres[node.cluster] ?? math.Point(side * 0.6 * (random.nextDouble() - 0.5) * 2, side * 0.6 * (random.nextDouble() - 0.5) * 2);
    final spread = k * math.sqrt((inCluster[node.cluster] ?? 1).toDouble()) * 0.6 + k;
    final a = random.nextDouble() * 2 * math.pi;
    final r = spread * math.sqrt(random.nextDouble());
    xs[i] = centre.x + r * math.cos(a);
    ys[i] = centre.y + r * math.sin(a);
  }
  // (a graph that shares little with the old one is laid out afresh: nothing is worth keeping)
  var kept = 0;
  if (start != null) {
    for (final node in graph.nodes) {
      if (node.kind != GraphNodeKind.topic && start.containsKey(node.id)) kept++;
    }
  }
  final gentle = start != null && kept >= n * 0.5;
  if (gentle) {
    final placed = List<bool>.filled(n, false);
    for (var i = 0; i < n; i++) {
      final node = graph.nodes[i];
      final old = node.kind == GraphNodeKind.topic ? null : start[node.id];
      if (old == null) continue;
      xs[i] = old.$1;
      ys[i] = old.$2;
      placed[i] = true;
    }
    // what is new begins among the placed nodes it is joined to (a few rounds, so that a new node next to a new node follows)
    final next = List<List<int>>.generate(n, (_) => []);
    for (final e in graph.edges) {
      next[e.a].add(e.b);
      next[e.b].add(e.a);
    }
    for (var round = 0; round < 4; round++) {
      final now = List<bool>.of(placed);
      for (var i = 0; i < n; i++) {
        if (placed[i] || graph.nodes[i].kind == GraphNodeKind.topic) continue;
        var sx = 0.0, sy = 0.0, c = 0;
        for (final j in next[i]) {
          if (!now[j] || graph.nodes[j].kind == GraphNodeKind.topic) continue;
          sx += xs[j];
          sy += ys[j];
          c++;
        }
        if (c == 0) continue;
        final a = random.nextDouble() * 2 * math.pi;
        xs[i] = sx / c + k * 0.3 * math.cos(a);
        ys[i] = sy / c + k * 0.3 * math.sin(a);
        placed[i] = true;
      }
    }
  }
  // the hubs start in the middle of what they hold
  final hubSum = <int, (double, double, int)>{};
  for (final e in graph.edges) {
    for (final (hub, other) in [(e.a, e.b), (e.b, e.a)]) {
      if (graph.nodes[hub].kind == GraphNodeKind.topic || graph.nodes[hub].kind == GraphNodeKind.note) {
        if (graph.nodes[other].kind == GraphNodeKind.fact || graph.nodes[other].kind == GraphNodeKind.note) {
          final s = hubSum[hub] ?? (0.0, 0.0, 0);
          hubSum[hub] = (s.$1 + xs[other], s.$2 + ys[other], s.$3 + 1);
        }
      }
    }
  }
  for (final e in hubSum.entries) {
    xs[e.key] = e.value.$1 / e.value.$3;
    ys[e.key] = e.value.$2 / e.value.$3;
  }

  final dx = Float64List(n), dy = Float64List(n);
  var temperature = gentle ? k * 0.15 : k * 3;
  if (gentle) iterations = math.min(iterations, 70);
  final cell = k * 2.2;
  for (var step = 0; step < iterations; step++) {
    dx.fillRange(0, n, 0);
    dy.fillRange(0, n, 0);
    // repulsion between nodes in neighbouring cells
    final grid = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      grid.putIfAbsent(_cellKey((xs[i] / cell).floor(), (ys[i] / cell).floor()), () => []).add(i);
    }
    for (var i = 0; i < n; i++) {
      final cx = (xs[i] / cell).floor(), cy = (ys[i] / cell).floor();
      for (var gx = cx - 1; gx <= cx + 1; gx++) {
        for (var gy = cy - 1; gy <= cy + 1; gy++) {
          final bucket = grid[_cellKey(gx, gy)];
          if (bucket == null) continue;
          for (final j in bucket) {
            if (j <= i) continue;
            var ex = xs[i] - xs[j], ey = ys[i] - ys[j];
            var d2 = ex * ex + ey * ey;
            if (d2 < 0.01) {
              ex = random.nextDouble() - 0.5;
              ey = random.nextDouble() - 0.5;
              d2 = ex * ex + ey * ey + 0.01;
            }
            final d = math.sqrt(d2);
            final f = k * k / d / d; // force / distance, to scale the vector
            dx[i] += ex * f;
            dy[i] += ey * f;
            dx[j] -= ex * f;
            dy[j] -= ey * f;
          }
        }
      }
    }
    // attraction along edges
    for (final e in graph.edges) {
      final ex = xs[e.a] - xs[e.b], ey = ys[e.a] - ys[e.b];
      final d = math.sqrt(ex * ex + ey * ey) + 0.01;
      final f = d / k * (0.4 + e.weight) * (e.kind == GraphEdgeKind.member || e.kind == GraphEdgeKind.source ? 0.8 : 1.0);
      dx[e.a] -= ex * f;
      dy[e.a] -= ey * f;
      dx[e.b] += ex * f;
      dy[e.b] += ey * f;
    }
    // a little pull to the middle, so that nodes with no edges do not drift away
    for (var i = 0; i < n; i++) {
      dx[i] -= xs[i] * 0.01;
      dy[i] -= ys[i] * 0.01;
    }
    var moved = 0.0;
    for (var i = 0; i < n; i++) {
      final len = math.sqrt(dx[i] * dx[i] + dy[i] * dy[i]);
      if (len < 1e-9) continue;
      final move = math.min(len, temperature);
      xs[i] += dx[i] / len * move;
      ys[i] += dy[i] / len * move;
      moved += move;
    }
    temperature *= 0.965;
    // settled: on average a node moves less than a hundredth of the distance between two joined ones
    if (step >= 25 && moved / n < k * 0.01) break;
  }
  _pushApart(graph, xs, ys, k);
  // centred on the middle of the nodes
  var mx = 0.0, my = 0.0;
  for (var i = 0; i < n; i++) {
    mx += xs[i];
    my += ys[i];
  }
  mx /= n;
  my /= n;
  for (var i = 0; i < n; i++) {
    graph.nodes[i]
      ..x = xs[i] - mx
      ..y = ys[i] - my;
  }
}

/// The place of every node by id, to give to [layoutGraph] as `start` when the graph is made again.
Map<String, (double, double)> placesOf(KnowledgeGraph graph) => {for (final n in graph.nodes) n.id: (n.x, n.y)};

/// How near two dots (drawn with a radius of 5 times the node's size) may come: they do not touch, with a little air between.
double _clearance(GraphNode a, GraphNode b) => 5.0 * (a.size + b.size) + 4;

/// Moves nodes whose dots overlap apart, each by half of what is missing, until none does (or after 40 rounds). The forces leave
/// such pairs where many nodes crowd the same few cells; this makes the dots readable and the hit test of a tap unambiguous.
void _pushApart(KnowledgeGraph graph, Float64List xs, Float64List ys, double k) {
  final n = graph.nodes.length;
  if (n < 2) return;
  var biggest = 0.0;
  for (final node in graph.nodes) {
    biggest = math.max(biggest, node.size);
  }
  final cell = 10.0 * biggest + 4;
  for (var round = 0; round < 40; round++) {
    final grid = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      grid.putIfAbsent(_cellKey((xs[i] / cell).floor(), (ys[i] / cell).floor()), () => []).add(i);
    }
    var touching = 0;
    for (var i = 0; i < n; i++) {
      final cx = (xs[i] / cell).floor(), cy = (ys[i] / cell).floor();
      for (var gx = cx - 1; gx <= cx + 1; gx++) {
        for (var gy = cy - 1; gy <= cy + 1; gy++) {
          final bucket = grid[_cellKey(gx, gy)];
          if (bucket == null) continue;
          for (final j in bucket) {
            if (j <= i) continue;
            final need = _clearance(graph.nodes[i], graph.nodes[j]);
            var ex = xs[i] - xs[j], ey = ys[i] - ys[j];
            var d2 = ex * ex + ey * ey;
            if (d2 >= need * need) continue;
            if (d2 < 1e-6) {
              // exactly on top of each other: a fixed direction by index, so that it stays deterministic
              final a = (i * 2.399963) % (2 * math.pi);
              ex = math.cos(a);
              ey = math.sin(a);
              d2 = 1;
            }
            final d = math.sqrt(d2);
            final push = (need - d) / 2 + 0.01;
            xs[i] += ex / d * push;
            ys[i] += ey / d * push;
            xs[j] -= ex / d * push;
            ys[j] -= ey / d * push;
            touching++;
          }
        }
      }
    }
    if (touching == 0) break;
  }
}

int _cellKey(int x, int y) => (x + 100000) * 200003 + (y + 100000);
