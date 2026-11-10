import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'fact_writer_fake.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/graph/graph_model.dart';
import 'package:notes/graph/graph_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/graph_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('the graph is made on request, from facts that a model wrote, and a node opens its note', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late GraphService service;
    late String bio;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      Future<String> make(String title, List<String> boxes) async {
        final id = await repo.createNote(title: title);
        final n = (await repo.loadNote(id))!;
        n.textBoxes[0] = [for (var i = 0; i < boxes.length; i++) TextBoxWidgetModel(id: '$title$i', position: Offset(10, 10.0 + i * 60), initialText: boxes[i])];
        await repo.saveNote(n);
        return id;
      }

      bio = await make('Biology', [
        'Mitochondria produce the energy of the cell and make ATP molecules for the cell.',
        'The cell nucleus holds the DNA and controls the cell activity of the organism.',
        'Ribosomes in the cell build proteins from the instructions of the DNA in the nucleus.',
      ]);
      await make('Contract law', [
        'An offer and its acceptance form a contract between the two parties of the contract.',
        'Consideration is needed to make the contract binding for both parties in contract law.',
        'A breach of contract gives the other party the right to damages under contract law.',
      ]);
      service = GraphService(repo, ai: factWriterService());
    });
    String? opened;
    await tester.pumpWidget(MaterialApp(home: GraphView(service: service, onOpen: (id, page) => opened = id)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-canvas')), findsNothing); // nothing is made on its own

    await tester.tap(find.byKey(const ValueKey('graph-generate')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-create-go')));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('graph-canvas')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('graph-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-lexical')), findsOneWidget);
    expect(find.text('Facts are written by: Fact writer'), findsOneWidget);
    final graph = (await tester.runAsync(() => service.load(service.lastMadeId!)))!;
    expect(graph.nodes.where((n) => n.kind == GraphNodeKind.fact), hasLength(6));
    expect(graph.clusters.length, greaterThanOrEqualTo(2));
    expect(find.byKey(const ValueKey('graph-topic-0')), findsOneWidget);

    // the notes graph is a kind of its own, made on request too, and kept next to the first one as a tab
    expect(find.byKey(const ValueKey('graph-tabs')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('graph-new')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-mode-notes')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-create-go')));
    for (var i = 0; i < 40 && service.graphs.length < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump();
    expect(service.graphs.map((g) => g.mode), ['facts', 'notes']);
    expect(service.selectedId, service.graphs.last.id, reason: 'the graph that was just made is in front');
    expect(find.byKey(const ValueKey('graph-canvas')), findsOneWidget);
    // going back to the first one does not make anything again
    final made = service.finished;
    await tester.tap(find.byKey(ValueKey('graph-tab-${service.graphs.first.id}')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(service.runningMode, isNull);
    expect(service.finished, made);
    expect(find.byKey(const ValueKey('graph-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-topic-0')), findsOneWidget);

    // a tap on a node shows it, and opens its note
    final canvas = find.byKey(const ValueKey('graph-canvas'));
    final node = graph.nodes.firstWhere((n) => n.kind == GraphNodeKind.fact && n.noteId == bio);
    final minX = graph.nodes.map((n) => n.x).reduce((a, b) => a < b ? a : b) - 80;
    final minY = graph.nodes.map((n) => n.y).reduce((a, b) => a < b ? a : b) - 80;
    final matrix = tester.widget<InteractiveViewer>(canvas).transformationController!.value;
    final at = tester.getTopLeft(canvas) + MatrixUtils.transformPoint(matrix, Offset(node.x - minX, node.y - minY));
    await tester.tapAt(at);
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-details')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('graph-open-note')));
    expect(opened, bio);

    // the search dims what does not match
    await tester.enterText(find.byKey(const ValueKey('graph-search')), 'contract');
    await tester.pump();
    expect(find.textContaining('matches'), findsOneWidget);
    // Enter goes to the first match and chooses it, and the nodes joined to it stand out
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-details')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a run goes on when the view is left, and the graph is there when it is opened again', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late GraphService service;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('saved_graphs'); // (the database is shared with the tests before: their graphs are not part of this one)
      final repo = NoteRepository(db);
      final id = await repo.createNote(title: 'Law');
      final n = (await repo.loadNote(id))!;
      n.textBoxes[0] = [TextBoxWidgetModel(id: 'law0', position: const Offset(10, 10), initialText: 'An offer and its acceptance form a contract between two parties.')];
      await repo.saveNote(n);
      service = GraphService(repo, ai: factWriterService());
    });
    await tester.pumpWidget(MaterialApp(home: GraphView(service: service, onOpen: (id, page) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-generate')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-create-go')));
    await tester.pump();
    expect(service.runningMode, 'facts');
    await tester.pumpWidget(const SizedBox()); // another tab
    for (var i = 0; i < 40 && service.runningMode != null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    expect(service.runningMode, isNull);
    expect(service.lastMade, isNotNull);

    await tester.pumpWidget(MaterialApp(home: GraphView(service: service, onOpen: (id, page) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-canvas')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kept graphs can be renamed, made again in place and deleted, and are there when the view is opened again', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late GraphService service;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['saved_graphs', 'facts', 'notes']) {
        await db.delete(t);
      }
      final repo = NoteRepository(db);
      final id = await repo.createNote(title: 'Law');
      final n = (await repo.loadNote(id))!;
      n.textBoxes[0] = [TextBoxWidgetModel(id: 'law0', position: const Offset(10, 10), initialText: 'An offer and its acceptance form a contract between two parties.')];
      await repo.saveNote(n);
      service = GraphService(repo, ai: factWriterService());
      await service.generate('notes');
      await service.generate('notes');
      await service.generate('facts');
    });
    expect(service.graphs.map((g) => g.name), ['Notes: All notes', 'Notes: All notes (2)', 'Facts: All notes']);

    Future<void> pumpView() async {
      await tester.pumpWidget(MaterialApp(home: GraphView(service: service, onOpen: (id, page) {})));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }

    await pumpView();
    expect(find.byKey(ValueKey('graph-tab-${service.graphs.last.id}')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-canvas')), findsOneWidget);

    // rename the one in front
    await tester.tap(find.byKey(const ValueKey('graph-tab-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('graph-tab-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('graph-rename-field')), 'Contracts');
    await tester.tap(find.byKey(const ValueKey('graph-rename-go')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Contracts'), findsOneWidget);

    // another tab, and the view is left and opened again: the tab that was in front still is
    final first = service.graphs.first.id;
    await tester.tap(find.byKey(ValueKey('graph-tab-$first')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await pumpView();
    expect(service.selectedId, first);
    expect(find.byKey(const ValueKey('graph-canvas')), findsOneWidget);

    // made again in place: the same tab, a newer picture
    final before = service.graphs.first.builtAt;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.tap(find.byKey(const ValueKey('graph-tab-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('graph-tab-again')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('graph-create-go')));
    for (var i = 0; i < 40 && service.finished == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump();
    expect(service.graphs, hasLength(3));
    expect(service.graphs.first.id, first);
    expect(service.graphs.first.builtAt.isAfter(before), isTrue);

    // deleting asks first, and goes to another tab
    await tester.tap(find.byKey(const ValueKey('graph-tab-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('graph-tab-delete')));
    await tester.pumpAndSettle();
    expect(service.graphs, hasLength(3));
    await tester.tap(find.byKey(const ValueKey('graph-delete-go')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(service.graphs.map((g) => g.name), ['Notes: All notes (2)', 'Contracts']);
    expect(find.byKey(ValueKey('graph-tab-$first')), findsNothing);
    expect(find.byKey(const ValueKey('graph-canvas')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with the AI switched off nothing is made and nothing is offered to write', (tester) async {
    late GraphService service;
    var on = true;
    await tester.runAsync(() async {
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final id = await repo.createNote(title: 'Law');
      final n = (await repo.loadNote(id))!;
      n.textBoxes[0] = [TextBoxWidgetModel(id: 'law0', position: const Offset(10, 10), initialText: 'An offer and its acceptance form a contract between two parties.')];
      await repo.saveNote(n);
      service = GraphService(repo, ai: factWriterService(), enabled: () => on);
    });
    expect(service.canWrite, isTrue);
    expect(service.canStudy, isTrue);
    on = false;
    expect(service.canWrite, isFalse);
    expect(service.canStudy, isFalse);
    await tester.runAsync(() => service.start('facts'));
    expect(service.runningMode, isNull);
    expect(service.lastMade, isNull);
    expect(service.problem, isNotNull);
    await tester.runAsync(() => expectLater(service.generate('notes'), throwsStateError));
    expect(() => service.studyComplete(const AiPrompt(system: '', user: '')), throwsStateError);
  });

  testWidgets('facts of two notes that give different numbers are marked, listed, and shown with the note that says otherwise', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late GraphService service;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      // (the database is shared with the tests before: their notes, facts and graphs are not part of this one)
      for (final t in ['saved_graphs', 'facts', 'notes']) {
        await db.delete(t);
      }
      final repo = NoteRepository(db);
      Future<void> make(String title, String text) async {
        final id = await repo.createNote(title: title);
        final n = (await repo.loadNote(id))!;
        n.textBoxes[0] = [TextBoxWidgetModel(id: '${title}0', position: const Offset(10, 10), initialText: text)];
        await repo.saveNote(n);
      }

      await make('Physics', 'The speed of sound in air at twenty degrees is 343 meters per second in dry air.');
      await make('Lecture 4', 'The speed of sound in air at twenty degrees is 330 meters per second in dry air.');
      await make('Cooking', 'Bake the bread for 40 minutes in an oven that is heated to 220 degrees.');
      service = GraphService(repo, ai: factWriterService());
    });
    await tester.pumpWidget(MaterialApp(home: GraphView(service: service, onOpen: (id, page) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-clashes')), findsNothing, reason: 'no graph yet');
    await tester.tap(find.byKey(const ValueKey('graph-generate')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-create-go')));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('graph-canvas')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-clashes')), findsOneWidget);
    final graph = service.lastMade!;
    expect(graph.edges.where((e) => e.kind == GraphEdgeKind.contradicts), hasLength(1));

    await tester.tap(find.byKey(const ValueKey('graph-clashes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('graph-clash-dialog')), findsOneWidget);
    expect(find.textContaining('343 meters'), findsOneWidget);
    expect(find.textContaining('330 meters'), findsOneWidget);
    expect(find.textContaining('40 minutes'), findsNothing);
    await tester.tap(find.textContaining('343 meters'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('graph-clash')), findsOneWidget);
    expect(find.text('Says something else in Lecture 4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
