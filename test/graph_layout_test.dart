import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/graph/graph_layout.dart';
import 'package:notes/graph/graph_model.dart';

KnowledgeGraph _ring(int n, {int extra = 0}) {
  final nodes = [
    for (var i = 0; i < n + extra; i++) GraphNode(id: 'n$i', kind: GraphNodeKind.fact, label: 'n$i', cluster: i % 3, size: 1 + (i % 4) * 0.4),
  ];
  final edges = [
    for (var i = 0; i < n; i++) GraphEdge(i, (i + 1) % n, 0.8, GraphEdgeKind.similar),
    // the new nodes hang on the first ones
    for (var i = 0; i < extra; i++) GraphEdge(n + i, i, 0.8, GraphEdgeKind.similar),
  ];
  return KnowledgeGraph(mode: 'facts', builtAt: DateTime(2026), nodes: nodes, edges: edges, clusters: [for (var c = 0; c < 3; c++) GraphCluster(c, 'c$c', n ~/ 3)]);
}

double _gap(KnowledgeGraph g) {
  var worst = double.infinity;
  for (var i = 0; i < g.nodes.length; i++) {
    for (var j = i + 1; j < g.nodes.length; j++) {
      final a = g.nodes[i], b = g.nodes[j];
      final d = math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
      worst = math.min(worst, d - 5.0 * (a.size + b.size));
    }
  }
  return worst;
}

void main() {
  test('no two dots overlap, even when many nodes crowd together', () {
    // 400 nodes with no edges and one topic: the forces alone leave many on top of each other
    final g = KnowledgeGraph(
      mode: 'facts',
      builtAt: DateTime(2026),
      nodes: [for (var i = 0; i < 400; i++) GraphNode(id: 'n$i', kind: GraphNodeKind.fact, label: '', cluster: 0, size: 1 + (i % 5) * 0.5)],
      edges: const [],
      clusters: const [GraphCluster(0, 'a', 400)],
    );
    layoutGraph(g);
    expect(_gap(g), greaterThanOrEqualTo(0));
    expect(g.nodes.every((n) => n.x.isFinite && n.y.isFinite), isTrue);
  });

  test('it is the same every time', () {
    final a = _ring(60), b = _ring(60);
    layoutGraph(a);
    layoutGraph(b);
    expect([for (final n in a.nodes) (n.x, n.y)], [for (final n in b.nodes) (n.x, n.y)]);
  });

  test('a graph made again with a few new nodes keeps the old ones in place', () {
    final first = _ring(90);
    layoutGraph(first);
    final again = _ring(90, extra: 6);
    layoutGraph(again, start: placesOf(first));
    final fresh = _ring(90, extra: 6);
    layoutGraph(fresh);
    double drift(KnowledgeGraph g) {
      var sum = 0.0;
      for (var i = 0; i < 90; i++) {
        sum += math.sqrt(math.pow(g.nodes[i].x - first.nodes[i].x, 2) + math.pow(g.nodes[i].y - first.nodes[i].y, 2));
      }
      return sum / 90;
    }

    expect(drift(again), lessThan(drift(fresh) / 3), reason: 'again ${drift(again)} fresh ${drift(fresh)}');
    // each new node sits near the node it hangs on
    for (var i = 0; i < 6; i++) {
      final a = again.nodes[90 + i], b = again.nodes[i];
      expect(math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)), lessThan(250));
    }
    expect(_gap(again), greaterThanOrEqualTo(0));
  });

  test('a graph that has little in common with the old one is laid out afresh', () {
    final other = _ring(40);
    layoutGraph(other);
    final g = _ring(40);
    for (var i = 0; i < 40; i++) {
      g.nodes[i].x = 0;
    }
    final places = {for (final n in other.nodes) 'old${n.id}': (n.x, n.y)}; // no ids in common
    layoutGraph(g, start: places);
    final f = _ring(40);
    layoutGraph(f);
    expect([for (final n in g.nodes) (n.x, n.y)], [for (final n in f.nodes) (n.x, n.y)]);
  });
}
