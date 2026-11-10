import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/graph/graph_export.dart';
import 'package:notes/graph/graph_model.dart';
import 'package:xml/xml.dart';

KnowledgeGraph _graph({int extra = 0}) => KnowledgeGraph(
      mode: 'facts',
      builtAt: DateTime(2026, 11, 8, 10),
      embedder: 'lexical',
      nodes: [
        GraphNode(id: 'f1', kind: GraphNodeKind.fact, label: 'Heaps <Swim> & "Sink"', detail: 'It swaps\nwith a parent.', noteId: 'n1', page: 2, tag: 'Method', cluster: 0, x: 10, y: 20, size: 1.2),
        GraphNode(id: 'f2', kind: GraphNodeKind.fact, label: 'Queues', cluster: 0, x: 110.456, y: -40, size: 1),
        GraphNode(id: 't0', kind: GraphNodeKind.topic, label: 'data structures', cluster: 0, x: 60, y: 0, size: 2),
        GraphNode(id: 'nA', kind: GraphNodeKind.note, label: 'Algorithms', noteId: 'n1', cluster: -1, x: -30, y: 10, size: 1.5),
        for (var i = 0; i < extra; i++) GraphNode(id: 'x$i', kind: GraphNodeKind.fact, label: 'Extra $i', cluster: 1, x: i * 3.0, y: i * 2.0),
      ],
      edges: const [
        GraphEdge(0, 1, 0.81, GraphEdgeKind.similar),
        GraphEdge(2, 0, 1, GraphEdgeKind.member),
        GraphEdge(3, 0, 1, GraphEdgeKind.source),
        GraphEdge(0, 1, 1, GraphEdgeKind.contradicts),
      ],
      clusters: const [GraphCluster(0, 'data structures', 3), GraphCluster(1, 'extra', 5)],
    );

void main() {
  test('the JSON says what the graph is: nodes with their topic and note, edges by node id', () {
    final json = jsonDecode(graphToJson(_graph(), name: 'Facts: All notes', noteTitles: {'n1': 'Algorithms'})) as Map;
    expect(json['format'], 'notation-graph');
    expect(json['version'], 1);
    expect(json['name'], 'Facts: All notes');
    expect(json['kind'], 'facts');
    expect(json['embedder'], 'lexical');
    expect(DateTime.parse(json['madeAt'] as String), DateTime(2026, 11, 8, 10));
    expect(json['topics'], [
      {'id': 0, 'label': 'data structures', 'size': 3},
      {'id': 1, 'label': 'extra', 'size': 5},
    ]);
    final nodes = (json['nodes'] as List).cast<Map>();
    expect(nodes.first, {
      'id': 'f1',
      'type': 'fact',
      'label': 'Heaps <Swim> & "Sink"',
      'detail': 'It swaps\nwith a parent.',
      'tag': 'Method',
      'topic': 0,
      'note': {'id': 'n1', 'title': 'Algorithms', 'page': 3},
      'x': 10,
      'y': 20,
      'size': 1.2,
    });
    expect(nodes[1].containsKey('detail'), isFalse);
    expect(nodes[1].containsKey('note'), isFalse);
    expect(nodes[1]['x'], 110.46);
    expect(nodes[3]['topic'], isNull, reason: 'a node in no topic');
    expect(nodes[3]['type'], 'note');
    final edges = (json['edges'] as List).cast<Map>();
    expect(edges.first, {'source': 'f1', 'target': 'f2', 'type': 'similar', 'weight': 0.81});
    expect(edges.map((e) => e['type']), ['similar', 'member', 'source', 'contradicts']);
    expect(edges[1], {'source': 't0', 'target': 'f1', 'type': 'member', 'weight': 1});
  });

  test('an edge that points outside the nodes is left out, an empty graph still writes', () {
    final broken = KnowledgeGraph(mode: 'notes', builtAt: DateTime(2026), nodes: [GraphNode(id: 'a', kind: GraphNodeKind.note, label: 'A')], edges: const [GraphEdge(0, 5, 1, GraphEdgeKind.link)], clusters: const []);
    expect((jsonDecode(graphToJson(broken, name: 'x'))['edges'] as List), isEmpty);
    final empty = KnowledgeGraph(mode: 'notes', builtAt: DateTime(2026), nodes: [], edges: [], clusters: []);
    expect(jsonDecode(graphToJson(empty, name: 'x'))['nodes'], isEmpty);
    expect(XmlDocument.parse(graphToSvg(empty, name: 'x')).rootElement.name.local, 'svg');
  });

  test('the SVG is well-formed XML with a shape for every node, a line for every edge, and the text escaped', () {
    final svg = graphToSvg(_graph(), name: 'Facts & "more" <all>');
    final doc = XmlDocument.parse(svg); // (throws when it is not well-formed)
    final root = doc.rootElement;
    expect(root.name.local, 'svg');
    expect(root.getAttribute('xmlns'), 'http://www.w3.org/2000/svg');
    expect(root.getAttribute('viewBox'), isNotNull);
    expect(root.findAllElements('line'), hasLength(4));
    // 4 nodes + the 2 swatches of the list of topics
    expect(root.findAllElements('circle'), hasLength(3 + 2));
    expect(root.findAllElements('rect').where((r) => r.getAttribute('fill') != '#ffffff'), hasLength(1), reason: 'a note among facts is a square');
    expect(svg, contains('Heaps &lt;Swim&gt; &amp; &quot;Sink&quot;'));
    expect(root.findAllElements('title').map((t) => t.innerText), contains('Heaps <Swim> & "Sink"\nIt swaps\nwith a parent.'));
    expect(root.findElements('title').single.innerText, 'Facts & "more" <all>');
    // the contradiction is red and dashed
    expect(svg, contains('stroke="#b3261e"'));
    expect(svg, contains('stroke-dasharray'));
    // the nodes are drawn inside the picture
    final box = root.getAttribute('viewBox')!.split(' ').map(double.parse).toList();
    for (final c in root.findAllElements('circle').take(3)) {
      expect(double.parse(c.getAttribute('cx')!), inInclusiveRange(0, box[2]));
      expect(double.parse(c.getAttribute('cy')!), inInclusiveRange(0, box[3]));
    }
  });

  test('a big graph names the topics and notes but not every fact; characters XML cannot hold are dropped', () {
    final big = _graph(extra: 400);
    final texts = XmlDocument.parse(graphToSvg(big, name: 'Big')).rootElement.findAllElements('text').map((t) => t.innerText).toList();
    expect(texts, contains('data structures'));
    expect(texts, contains('Algorithms'));
    expect(texts, isNot(contains('Extra 3')));
    final small = XmlDocument.parse(graphToSvg(_graph(), name: 'Small')).rootElement.findAllElements('text').map((t) => t.innerText).toList();
    expect(small.any((t) => t.startsWith('Queues')), isTrue);

    final odd = KnowledgeGraph(mode: 'facts', builtAt: DateTime(2026), nodes: [GraphNode(id: 'a', kind: GraphNodeKind.fact, label: 'a\u0001b\u0008c')], edges: const [], clusters: const []);
    expect(XmlDocument.parse(graphToSvg(odd, name: 'x')).rootElement.findAllElements('text').first.innerText, 'abc');
  });

  test('topic colours: the same for a topic every time, grey for none, valid hex', () {
    expect(topicColor(-1), '#80868b');
    for (var i = 0; i < 30; i++) {
      expect(topicColor(i), matches(RegExp(r'^#[0-9a-f]{6}$')));
    }
    expect(topicColor(3), topicColor(3));
    expect(topicColor(0), isNot(topicColor(1)));
  });
}
