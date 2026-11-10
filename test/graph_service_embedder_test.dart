import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'fact_writer_fake.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/graph/graph_service.dart';
import 'package:notes/llm/embedding_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Like the real sentence model: it holds things that cannot be sent to another isolate (a port).
class _ModelLikeEmbedder implements TextEmbedder {
  final ReceivePort _port = ReceivePort();

  @override
  String get modelId => 'model-like';

  @override
  Future<Float32List> embed(String text) async {
    final v = Float32List(8);
    for (final c in text.codeUnits) {
      v[c % 8] += 1;
    }
    return v;
  }

  void close() => _port.close();
}

void main() {
  setUpAll(AppDatabase.initFfi);

  test('the graph is built with an embedder that cannot be sent to an isolate (the real sentence model)', () async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final id = await repo.createNote(title: 'Biology');
    final n = (await repo.loadNote(id))!;
    n.textBoxes[0] = [
      TextBoxWidgetModel(id: 'a', position: Offset.zero, initialText: 'Mitochondria produce the energy of the cell and make ATP molecules for the cell.'),
      TextBoxWidgetModel(id: 'b', position: const Offset(0, 60), initialText: 'The cell nucleus holds the DNA and controls the cell activity of the organism.'),
    ];
    await repo.saveNote(n);
    final embedder = _ModelLikeEmbedder();
    addTearDown(embedder.close);
    final service = GraphService(repo, embedder: embedder, embedderReady: () => true, ai: factWriterService());
    final graph = await service.generate('facts');
    expect(graph, isNotNull);
    expect(graph!.nodes, isNotEmpty);
    expect(graph.embedder, 'model-like');
  });
}
