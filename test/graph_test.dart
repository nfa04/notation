import 'package:flutter_test/flutter_test.dart';
import 'package:notes/diagram/graph.dart';
import 'package:notes/diagram/graph_layout.dart';

Graph parse(String text) => parseGraph(text).graph;

const _weighted = '''
A -4- B
A -1- C
C -2- B
B -5- D
C -8- D
''';

void main() {
  group('reading', () {
    test('lines, arrows, chains and nodes on their own', () {
      final g = parse('A - B - C\nC -> D\nE, F');
      expect(g.nodes, ['A', 'B', 'C', 'D', 'E', 'F']);
      expect(g.edges.map((e) => '${e.from}${e.directed ? '>' : '-'}${e.to}').toList(), ['A-B', 'B-C', 'C>D']);
      expect(g.hasDirected, isTrue);
    });

    test('weights written three ways', () {
      final g = parse('A -3- B\nB -2.5-> C\nC - D : 7');
      expect(g.edges.map((e) => e.weight).toList(), [3, 2.5, 7]);
      expect(g.edges[1].directed, isTrue);
      expect(g.weighted, isTrue);
    });

    test('numbers can be names', () {
      final g = parse('1 - 2 - 3\n2 -5- 4');
      expect(g.nodes, ['1', '2', '3', '4']);
      expect(g.edges.map((e) => e.weight).toList(), [null, null, 5]);
    });

    test('arrows the other way and both ways', () {
      final g = parse('A <- B\nC <-> D');
      expect(g.edges.map((e) => '${e.from}>${e.to}').toList(), ['B>A', 'C>D', 'D>C']);
    });

    test('start, comments, mistakes', () {
      final r = parseGraph('# graph\nstart: B\nA - B // here\nA - B C');
      expect(r.graph.start, 'B');
      expect(r.graph.origin, 'B');
      expect(r.problems, ['line 4: A - B C']);
      expect(parse('A - B').origin, 'A');
      expect(parse('').isEmpty, isTrue);
    });
  });

  group('searching', () {
    const text = 'A - B\nA - C\nB - D\nC - D\nD - E';
    test('breadth first and depth first', () {
      final g = parse(text);
      expect(breadthFirst(g, 'A').order, ['A', 'B', 'C', 'D', 'E']);
      expect(depthFirst(g, 'A').order, ['A', 'B', 'D', 'C', 'E']);
      expect(breadthFirst(g, 'A').edges.length, 4);
    });

    test('arrows only go their way', () {
      final g = parse('A -> B\nB -> C\nD -> A');
      expect(breadthFirst(g, 'A').order, ['A', 'B', 'C']);
      expect(breadthFirst(g, 'D').order, ['D', 'A', 'B', 'C']);
    });
  });

  group('shortest paths', () {
    test('Dijkstra', () {
      final g = parse(_weighted);
      final p = shortestPaths(g, 'A')!;
      expect(p.distance, {'A': 0, 'C': 1, 'B': 3, 'D': 8});
      expect(pathTo(g, p, 'A', 'D'), ['A', 'C', 'B', 'D']);
      expect(pathTo(g, p, 'A', 'A'), ['A']);
    });

    test('without weights every edge is one', () {
      final p = shortestPaths(parse('A - B - C - D\nA - D'), 'A')!;
      expect(p.distance['C'], 2);
      expect(p.distance['D'], 1);
    });

    test('what cannot be reached is not there', () {
      final g = parse('A -> B\nC');
      final p = shortestPaths(g, 'B')!;
      expect(p.distance.containsKey('A'), isFalse);
      expect(pathTo(g, p, 'B', 'C'), isNull);
    });
  });

  group('structure', () {
    test('a minimum spanning tree', () {
      final t = spanningTree(parse(_weighted));
      expect(t.weight, 8); // A-C 1, C-B 2, B-D 5
      expect(t.edges.length, 3);
    });

    test('components', () {
      expect(components(parse('A - B\nC - D\nE')), [['A', 'B'], ['C', 'D'], ['E']]);
      expect(components(parse('A -> B\nC -> B')), [['A', 'B', 'C']]);
    });

    test('cycles in lines and in arrows', () {
      expect(hasCycle(parse('A - B\nB - C\nC - A')), isTrue);
      expect(hasCycle(parse('A - B\nB - C\nC - D')), isFalse);
      expect(hasCycle(parse('A - B\nA - B')), isTrue); // (two lines between the same two)
      expect(hasCycle(parse('A -> B\nB -> C\nA -> C')), isFalse);
      expect(hasCycle(parse('A -> B\nB -> C\nC -> A')), isTrue);
    });

    test('bipartite', () {
      expect(isBipartite(parse('A - B\nB - C\nC - D\nD - A')), isTrue);
      expect(isBipartite(parse('A - B\nB - C\nC - A')), isFalse);
    });

    test('topological order', () {
      expect(topologicalOrder(parse('A -> B\nA -> C\nB -> D\nC -> D')), ['A', 'B', 'C', 'D']);
      expect(topologicalOrder(parse('A -> B\nB -> A')), isNull);
      expect(topologicalOrder(parse('A - B')), isNull);
    });

    test('strongly connected components', () {
      final parts = stronglyConnected(parse('A -> B\nB -> C\nC -> A\nC -> D\nD -> E\nE -> D'));
      expect(parts, [['A', 'B', 'C'], ['D', 'E']]);
    });

    test('facts', () {
      String fact(String text, String name) => graphFacts(parse(text)).firstWhere((f) => f.$1 == name).$2;
      expect(fact(_weighted, 'Spanning tree'), '3 edges, total 8');
      expect(fact(_weighted, 'Shortest paths'), 'B 3, C 1, D 8');
      expect(fact(_weighted, 'Kind'), 'undirected, weighted');
      expect(fact('A -> B', 'Kind'), 'directed');
      expect(fact('A - B\nC', 'Components'), '2: {A, B} {C}');
      expect(fact('A -> B\nB -> A', 'Topological order'), 'none (there is a cycle)');
      expect(fact('A -3- B', 'Degrees'), 'A: 1, B: 1');
      expect(graphFacts(parse('')), isEmpty);
    });
  });

  group('layout', () {
    test('every node a box, every edge a line, none on another', () {
      for (final text in [_weighted, 'A - B - C - D - E - F', 'A - B\nB - C\nC - A', 'A -> B\nB -> A\nB -> C', 'A\nB\nC', 'A - B\nA - B']) {
        final g = parse(text);
        final l = layoutGraph(g);
        expect(l.boxes.length, g.nodes.length, reason: text);
        expect(l.lines.length, g.edges.length, reason: text);
        for (var i = 0; i < l.boxes.length; i++) {
          expect(l.boxes[i].rect.isFinite, isTrue);
          for (var j = i + 1; j < l.boxes.length; j++) {
            expect(l.boxes[i].rect.overlaps(l.boxes[j].rect), isFalse, reason: '$text ${l.boxes[i].text} ${l.boxes[j].text}');
          }
        }
      }
    });

    test('it comes out the same every time', () {
      final a = graphPositions(parse(_weighted)), b = graphPositions(parse(_weighted));
      expect(a, b);
    });

    test('a cycle comes out round', () {
      final g = parse('A - B\nB - C\nC - D\nD - E\nE - F\nF - A');
      final p = graphPositions(g);
      final centre = p.reduce((a, b) => a + b) / p.length.toDouble();
      final radii = [for (final x in p) (x - centre).distance];
      final mean = radii.reduce((a, b) => a + b) / radii.length;
      expect(radii.every((r) => (r - mean).abs() < mean * 0.2), isTrue, reason: '$radii');
    });

    test('arrows that never lead back go down the page', () {
      final g = parse('A -> B\nA -> C\nB -> D\nC -> D');
      final p = graphPositions(g);
      expect(p[0].dy < p[1].dy && p[1].dy < p[3].dy, isTrue);
      expect(p[1].dy, p[2].dy);
      expect(p[1].dx < p[2].dx, isTrue);
      // with a way round, or a line without an arrow, it is the force layout
      expect(graphPositions(parse('A -> B\nB -> A'))[0].dy, isNot(0.0));
    });

    test('weights are on the lines, arrows have heads', () {
      final l = layoutGraph(parse('A -3-> B\nB -4- C'));
      expect(l.labels.map((x) => x.text).toSet(), {'3', '4'});
      expect(l.lines[0].points.length > l.lines[1].points.length, isTrue); // (the head)
    });

    test('highlights', () {
      final g = parse(_weighted);
      final shortest = layoutGraph(g, highlight: GraphHighlight.shortest);
      expect(shortest.lines.where((x) => x.width > 3).length, 3);
      expect(shortest.labels.map((x) => x.text), containsAll(['0', '1', '3', '8']));
      final tree = layoutGraph(g, highlight: GraphHighlight.spanning);
      expect(tree.lines.where((x) => x.width > 3).length, 3);
      final bfs = layoutGraph(g, highlight: GraphHighlight.breadthFirst);
      expect(bfs.labels.map((x) => x.text), containsAll(['1', '2', '3', '4']));
    });

    test('nothing', () {
      expect(layoutGraph(parse('')).isEmpty, isTrue);
      expect(layoutGraph(parse('A')).boxes.length, 1);
    });
  });
}
