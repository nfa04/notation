import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/graph/graph_diff.dart';
import 'package:notes/graph/graph_model.dart';
import 'package:notes/graph/topic_namer.dart';

GraphNode _fact(String id, String label, {String detail = '', int cluster = 0}) => GraphNode(id: id, kind: GraphNodeKind.fact, label: label, detail: detail, cluster: cluster);

KnowledgeGraph _graph(List<GraphNode> nodes, List<(int, int, GraphEdgeKind)> edges, {List<String> topics = const ['a']}) => KnowledgeGraph(
      mode: 'facts',
      builtAt: DateTime(2026),
      nodes: nodes,
      edges: [for (final e in edges) GraphEdge(e.$1, e.$2, 0.8, e.$3)],
      clusters: [for (var i = 0; i < topics.length; i++) GraphCluster(i, topics[i], 3)],
    );

void main() {
  group('diff', () {
    test('what is new, changed and gone, by id', () {
      final before = _graph([_fact('f1', 'One', detail: 'x'), _fact('f2', 'Two'), _fact('f3', 'Three')], const []);
      final after = _graph([_fact('f2', 'Two'), _fact('f3', 'Three', detail: 'now with text'), _fact('f4', 'Four'), _fact('f1', 'One renamed', detail: 'x')], const []);
      final d = diffGraphs(before, after);
      expect([for (final i in d.added) after.nodes[i].id], ['f4']);
      expect([for (final i in d.changed) after.nodes[i].id], ['f3', 'f1']);
      expect(d.removed, isEmpty);
      final back = diffGraphs(after, before);
      expect([for (final n in back.removed) n.id], ['f4']);
      expect(back.added, isEmpty);
    });

    test('the same graph differs in nothing', () {
      final g = _graph([_fact('f1', 'One'), _fact('f2', 'Two')], [(0, 1, GraphEdgeKind.similar)]);
      expect(diffGraphs(g, g).isEmpty, isTrue);
    });

    test('hubs of topics are not nodes of the comparison, nor are the lines that join them', () {
      GraphNode hub(int c) => GraphNode(id: 'topic:$c', kind: GraphNodeKind.topic, label: 'T$c', cluster: c);
      final before = _graph([_fact('f1', 'One'), _fact('f2', 'Two'), hub(0)], [(0, 1, GraphEdgeKind.similar), (2, 0, GraphEdgeKind.member), (2, 1, GraphEdgeKind.member)]);
      final after = _graph([_fact('f1', 'One'), _fact('f2', 'Two'), hub(5)], [(0, 1, GraphEdgeKind.similar), (2, 0, GraphEdgeKind.member)]);
      final d = diffGraphs(before, after);
      expect(d.added, isEmpty);
      expect(d.removed, isEmpty);
      expect(d.linesAdded + d.linesRemoved, 0);
    });

    test('lines count only between nodes both graphs have, and either way round', () {
      final before = _graph([_fact('f1', 'One'), _fact('f2', 'Two'), _fact('f3', 'Three')], [(0, 1, GraphEdgeKind.similar)]);
      // f1-f2 is gone, f2-f3 is new, and f1-f4 does not count (f4 is new)
      final after = _graph([_fact('f3', 'Three'), _fact('f2', 'Two'), _fact('f1', 'One'), _fact('f4', 'Four')], [(1, 0, GraphEdgeKind.similar), (2, 3, GraphEdgeKind.similar)]);
      final d = diffGraphs(before, after);
      expect(d.linesAdded, 1);
      expect(d.linesRemoved, 1);
    });

    test('topics that came and went are told by their names', () {
      final before = _graph([_fact('f1', 'One')], const [], topics: ['cells', 'law']);
      final after = _graph([_fact('f1', 'One')], const [], topics: ['law', 'energy']);
      final d = diffGraphs(before, after);
      expect(d.topicsNew, ['energy']);
      expect(d.topicsGone, ['cells']);
    });

    test('a name written by a model is kept in the saved picture, an old picture without the mark still reads', () {
      final g = KnowledgeGraph(mode: 'facts', builtAt: DateTime(2026), nodes: [_fact('f1', 'One')], edges: const [], clusters: const [GraphCluster(0, 'Cells', 3, named: true), GraphCluster(1, 'words here', 2)]);
      final back = KnowledgeGraph.decode(g.encode())!;
      expect(back.clusters.map((c) => c.named), [true, false]);
      final old = KnowledgeGraph.decode('{"v":1,"mode":"facts","at":1,"emb":"","nodes":[],"edges":[],"clusters":[[0,"x",2]]}')!;
      expect(old.clusters.single.named, isFalse);
    });
  });

  group('topic names', () {
    test('the request lists every topic with its words and titles, and asks for a fixed form', () {
      final p = topicNamePrompt(const [TopicSample(1, 'cell, atp', ['Mitochondria', 'Nucleus']), TopicSample(2, 'contract', ['Offer'])]);
      expect(p.user, '1 (words: cell, atp): Mitochondria; Nucleus\n2 (words: contract): Offer');
      expect(p.system, contains('number | name'));
      expect(p.exact, isTrue);
      expect(p, isA<AiPrompt>());
    });

    test('names are read by number; noise, doubles and numbers nobody asked for are ignored', () {
      final names = parseTopicNames(
        'Here are the names:\n1 | Cell Biology\n2: "Contract law."\n- 3) **Energy transfer**\n9 | Not asked\n1 | Second try\n4 | \n5 | ${'long ' * 20}\n6 | one two three four five six seven eight nine',
        {1, 2, 3, 4, 5, 6},
      );
      expect(names, {1: 'Cell Biology', 2: 'Contract law', 3: 'Energy transfer'});
    });

    test('an answer in no form at all gives nothing', () {
      expect(parseTopicNames('I cannot do that.', {1}), isEmpty);
      expect(parseTopicNames('', {1}), isEmpty);
    });
  });
}
