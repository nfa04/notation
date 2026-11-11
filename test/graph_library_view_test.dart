import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/llm/embedding_service.dart';
import 'package:notes/l10n/text.dart' as app;
import 'package:notes/graph/graph_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/graph_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fact_writer_fake.dart';

class _Embedder extends ChangeNotifier implements TextEmbedder {
  @override
  String get modelId => 'fake-model';
  @override
  Future<Float32List> embed(String text) async => Float32List(4)..[0] = 1;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a graph made before the sentence model came says so (not that it is missing), and offers to make it again', (tester) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late GraphService service;
    var ready = false;
    final embedder = _Embedder();
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['saved_graphs', 'graph_versions', 'sync_tombstones']) {
        await db.delete(t);
      }
      final repo = NoteRepository(db);
      final id = await repo.createNote(title: 'Biology');
      final n = (await repo.loadNote(id))!;
      n.textBoxes[0] = [
        TextBoxWidgetModel(id: 'b0', position: const Offset(10, 10), initialText: 'Mitochondria produce the energy of the cell and make ATP molecules for the cell.'),
        TextBoxWidgetModel(id: 'b1', position: const Offset(10, 70), initialText: 'The cell nucleus holds the DNA and controls the cell activity of the organism.'),
      ];
      await repo.saveNote(n);
      service = GraphService(repo, ai: factWriterService(), embedder: embedder, embedderReady: () => ready);
      await service.start('facts'); // made while the model is not there: lexical
    });
    await tester.pumpWidget(MaterialApp(home: GraphView(service: service, onOpen: (_, _) {})));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('graph-canvas')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('graph-lexical')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-lexical-stale')), findsNothing);
    // the model is downloaded: the bar changes without leaving the screen
    ready = true;
    embedder.notifyListeners();
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-lexical')), findsNothing);
    expect(find.byKey(const ValueKey('graph-lexical-stale')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('graph-lexical-again')));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('graph-create-dialog')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // (it reads the folders first)
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('graph-create-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-create-lexical')), findsNothing, reason: 'the dialog does not say the model is missing');
  });

  testWidgets('the library lists the graphs; making one again says what is new; an earlier picture can be compared and brought back', (tester) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late GraphService service;
    Future<void> settle([int ms = 150]) async {
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pump();
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 60 && !done(); i++) {
        await settle(100);
      }
    }

    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      for (final t in ['saved_graphs', 'graph_versions', 'sync_tombstones']) {
        await db.delete(t);
      }
      repo = NoteRepository(db);
      final id = await repo.createNote(title: 'Biology');
      final n = (await repo.loadNote(id))!;
      n.textBoxes[0] = [
        for (final (i, t) in [
          'Mitochondria produce the energy of the cell and make ATP molecules for the cell.',
          'The cell nucleus holds the DNA and controls the cell activity of the organism.',
          'Ribosomes in the cell build proteins from the instructions of the DNA in the nucleus.',
        ].indexed)
          TextBoxWidgetModel(id: 'b$i', position: Offset(10, 10.0 + i * 60), initialText: t),
      ];
      await repo.saveNote(n);
      service = GraphService(repo, ai: factWriterService());
      await service.start('facts');
    });
    await tester.pumpWidget(MaterialApp(home: GraphView(service: service, onOpen: (_, _) {})));
    await until(() => find.byKey(const ValueKey('graph-canvas')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('graph-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-compare-banner')), findsNothing);

    // the library: one graph, no earlier pictures yet
    await tester.tap(find.byKey(const ValueKey('graph-library')));
    await until(() => find.byKey(const ValueKey('graph-library-list')).evaluate().isNotEmpty);
    final graphId = service.graphs.single.id;
    expect(find.byKey(ValueKey('graph-library-$graphId')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('graph-library-$graphId')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No earlier pictures'), findsOneWidget);
    await tester.pageBack();
    await settle();

    // a note is added and the graph made again: the view says what is new, and rings the new nodes
    await tester.runAsync(() async {
      final id = await repo.createNote(title: 'Chemistry');
      final n = (await repo.loadNote(id))!;
      n.textBoxes[0] = [TextBoxWidgetModel(id: 'c0', position: const Offset(10, 10), initialText: 'Covalent bonds share electron pairs between the atoms of a molecule.')];
      await repo.saveNote(n);
      await service.start('facts', replace: graphId);
    });
    await until(() => find.byKey(const ValueKey('graph-compare-banner')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('graph-compare-banner')), findsOneWidget);
    expect(tester.widget<app.Text>(find.byKey(const ValueKey('graph-compare-summary'))).data, contains('1 new, 0 gone, 0 changed'));
    await tester.tap(find.byKey(const ValueKey('graph-compare-changes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('graph-changes')), findsOneWidget);
    expect(find.textContaining('New (1)'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // the sheet's barrier
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('graph-compare-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-compare-banner')), findsNothing);

    // the library now has the earlier picture; compare it with the graph as it is
    await tester.tap(find.byKey(const ValueKey('graph-library')));
    await until(() => find.byKey(const ValueKey('graph-library-list')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(ValueKey('graph-library-$graphId')));
    await tester.pumpAndSettle();
    final version = (await tester.runAsync(() => service.versionsOf(service.graphs.single.uid)))!.single;
    expect(find.byKey(ValueKey('graph-version-${version.id}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('graph-version-compare-${version.id}')));
    await until(() => find.byKey(const ValueKey('graph-compare-banner')).evaluate().isNotEmpty);
    await tester.pumpAndSettle(); // (the library is still sliding away)
    expect(find.byKey(const ValueKey('graph-library-list')), findsNothing);
    expect(tester.widget<app.Text>(find.byKey(const ValueKey('graph-compare-summary'))).data, contains('1 new'));

    // and bring it back: the graph has three facts again, and the one that was there is the earlier picture
    await tester.tap(find.byKey(const ValueKey('graph-library')));
    await until(() => find.byKey(const ValueKey('graph-library-list')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(ValueKey('graph-library-$graphId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('graph-version-restore-${version.id}')));
    await until(() => find.byKey(const ValueKey('graph-library-list')).evaluate().isEmpty);
    await tester.pumpAndSettle();
    await until(() => find.byKey(const ValueKey('graph-canvas')).evaluate().isNotEmpty);
    final now = (await tester.runAsync(() => service.load(graphId)))!;
    expect(now.nodes.where((n) => n.detail.contains('Covalent')), isEmpty);
    expect((await tester.runAsync(() => service.versionsOf(service.graphs.single.uid)))!, hasLength(1));
    expect(find.byKey(const ValueKey('graph-compare-banner')), findsNothing);
  });
}
