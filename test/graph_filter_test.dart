import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/graph/graph_filter.dart';
import 'package:notes/graph/graph_model.dart';
import 'package:notes/graph/graph_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/graph_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fact_writer_fake.dart';

GraphNode _n(String id, GraphNodeKind kind, {String? tag, String? note, int cluster = 0}) => GraphNode(id: id, kind: kind, label: id, tag: tag, noteId: note, cluster: cluster);

/// 0 topic, 1 definition (note a), 2 data (note a), 3 definition (note b), 4 data (note b, no lines), 5 note hub a.
KnowledgeGraph _graph() => KnowledgeGraph(
      mode: 'facts',
      builtAt: DateTime(2026),
      clusters: const [GraphCluster(0, 'Topic', 4)],
      nodes: [
        _n('topic', GraphNodeKind.topic),
        _n('d1', GraphNodeKind.fact, tag: 'Definition', note: 'a'),
        _n('x1', GraphNodeKind.fact, tag: 'Data', note: 'a'),
        _n('d2', GraphNodeKind.fact, tag: 'Definition', note: 'b'),
        _n('x2', GraphNodeKind.fact, tag: 'Data', note: 'b'),
        _n('hub', GraphNodeKind.note, note: 'a'),
      ],
      edges: const [
        GraphEdge(0, 1, 1, GraphEdgeKind.member),
        GraphEdge(0, 2, 1, GraphEdgeKind.member),
        GraphEdge(0, 3, 1, GraphEdgeKind.member),
        GraphEdge(1, 2, 0.9, GraphEdgeKind.similar),
        GraphEdge(1, 3, 0.4, GraphEdgeKind.similar),
        GraphEdge(5, 1, 1, GraphEdgeKind.source),
      ],
    );

void main() {
  setUpAll(AppDatabase.initFfi);

  group('GraphFilter', () {
    test('without a setting everything shows', () {
      final f = const GraphFilter().apply(_graph());
      expect(f.nodes, isNull);
      expect(f.edges, hasLength(6));
      expect(const GraphFilter().active, isFalse);
    });

    test('kinds of fact leave out the other facts, and the lines to them, but not the hubs', () {
      final f = const GraphFilter(tags: {'Definition'}).apply(_graph());
      expect(f.nodes, {0, 1, 3, 5});
      expect(f.edges.map((e) => (e.a, e.b)), containsAll([(0, 1), (0, 3), (1, 3), (5, 1)]));
      expect(f.edges.any((e) => e.a == 2 || e.b == 2), isFalse);
    });

    test('notes keep their own facts; a topic stays while one of its nodes does', () {
      final f = const GraphFilter(notes: {'b'}).apply(_graph());
      expect(f.nodes, {0, 3, 4}); // (x2 has no line, but is shown: only [hideLoose] drops it)
      expect(const GraphFilter(notes: {'b'}).apply(_graph()).edges, hasLength(1));
    });

    test('a topic with nothing left to join goes without being asked', () {
      final f = const GraphFilter(notes: {'zzz'}).apply(_graph());
      expect(f.nodes, isEmpty);
    });

    test('weak similarity and kinds of line can be left out', () {
      final weak = const GraphFilter(minWeight: 0.5).apply(_graph());
      expect(weak.edges.where((e) => e.kind == GraphEdgeKind.similar), hasLength(1));
      final none = const GraphFilter(hiddenEdges: {GraphEdgeKind.similar}).apply(_graph());
      expect(none.edges.where((e) => e.kind == GraphEdgeKind.similar), isEmpty);
      expect(none.edges, hasLength(4)); // the topic and the note hub still join their facts
    });

    test('hiding the hubs leaves the facts, and hiding the loose ones the nodes that have no line', () {
      expect(const GraphFilter(hideHubs: true).apply(_graph()).nodes, {1, 2, 3, 4});
      final loose = const GraphFilter(hideLoose: true).apply(_graph());
      expect(loose.nodes, {0, 1, 2, 3, 5});
      expect(loose.shows(4), isFalse);
    });

    test('count and equality', () {
      expect(const GraphFilter(tags: {'Data'}, hideLoose: true).count, 2);
      expect(const GraphFilter(tags: {'Data'}), const GraphFilter(tags: {'Data'}));
      expect(const GraphFilter(tags: {'Data'}), isNot(const GraphFilter(tags: {'Result'})));
    });
  });

  testWidgets('the filter button narrows the graph and the count says so; another graph starts unfiltered', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late GraphService service;
    await tester.runAsync(() async {
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      Future<void> make(String title, List<String> boxes) async {
        final id = await repo.createNote(title: title);
        final n = (await repo.loadNote(id))!;
        n.textBoxes[0] = [for (var i = 0; i < boxes.length; i++) TextBoxWidgetModel(id: '$title$i', position: Offset(10, 10.0 + i * 60), initialText: boxes[i])];
        await repo.saveNote(n);
      }

      await make('Biology', [
        'Mitochondria produce the energy of the cell and make ATP molecules for the cell.',
        'The cell nucleus holds the DNA and controls the cell activity of the organism.',
      ]);
      await make('Contract law', [
        'An offer and its acceptance form a contract between the two parties of the contract.',
        'A breach of contract gives the other party the right to damages under contract law.',
      ]);
      service = GraphService(repo, ai: factWriterService());
      await service.generate('facts');
    });
    await tester.pumpWidget(MaterialApp(home: GraphView(service: service, onOpen: (id, page) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    final total = (await tester.runAsync(() => service.load(service.lastMadeId!)))!.nodes.length;
    expect(find.textContaining('$total nodes'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('graph-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('graph-filter-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-filter-reset')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('graph-filter-loose')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('/ $total'), findsOneWidget, reason: 'the nodes shown of all');
    expect(find.byType(Badge), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
