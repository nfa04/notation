import 'dart:math' as math;
import 'dart:typed_data';

import 'graph_model.dart';

/// Gives every node of [graph] a place. A force-directed layout (Fruchterman-Reingold) that starts from a seed in which each
/// topic has a place of its own on a spiral, so that it settles in few steps; the nodes push each other away only when they are
/// in neighbouring cells of a grid, which keeps a step linear in the number of nodes. Deterministic.
void layoutGraph(KnowledgeGraph graph, {int iterations = 150}) {
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
  var temperature = k * 3;
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
    for (var i = 0; i < n; i++) {
      final len = math.sqrt(dx[i] * dx[i] + dy[i] * dy[i]);
      if (len < 1e-9) continue;
      final move = math.min(len, temperature);
      xs[i] += dx[i] / len * move;
      ys[i] += dy[i] / len * move;
    }
    temperature *= 0.965;
  }
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

int _cellKey(int x, int y) => (x + 100000) * 200003 + (y + 100000);
