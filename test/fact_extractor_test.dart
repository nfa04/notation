import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/graph/fact_extractor.dart';
import 'package:notes/graph/graph_service.dart';
import 'package:notes/models/canvas_models.dart';

import 'fact_writer_fake.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('lines of the answer become facts; fragments, pointers to the slide and repeats do not', () {
    final facts = parseFacts('''
Here are the facts:
1. Heaps: Swim Function | Method | The Swim function restores the heap property by swapping a node with its parent. | heap, swim
- **Heaps: Sink Function** | Method | The Sink function restores the heap property by swapping a node with its larger child. | heap, sink
Heaps: Swim Function | Method | The Swim function restores the heap property by swapping a node with its parent. | heap
Heaps: Priority | Fact | It is used for priority queues in every operating system. | heap
Heaps: Example | Fact | In this example the node moves up to the root of the tree. | heap
Heaps: Short | Fact | Too short. | heap
Title | Tag | Sentence | keywords
''');
    expect(facts.map((f) => f.title), ['Heaps: Swim Function', 'Heaps: Sink Function']);
    expect(facts.first.tag, 'Method');
    expect(facts.first.keywords, ['heap', 'swim']);
  });

  Future<(NoteRepository, String)> noteWith(List<String> lines) async {
    final dir = await Directory.systemTemp.createTemp('facts_');
    addTearDown(() => dir.delete(recursive: true));
    final repo = NoteRepository(await AppDatabase.open(path: '${dir.path}/n.db')); // (a database of its own: the in-memory one is shared)
    final id = await repo.createNote(title: 'Algorithms');
    final n = (await repo.loadNote(id))!;
    n.textBoxes[0] = [for (var i = 0; i < lines.length; i++) TextBoxWidgetModel(id: 'b$i', position: Offset(10, 10.0 + i * 60), initialText: lines[i])];
    await repo.saveNote(n);
    return (repo, id);
  }

  test('without a model there are no facts (pieces of the slides are not facts), and the person is told', () async {
    final (repo, _) = await noteWith(['The Swim function restores the heap property by swapping a node with its parent.']);
    final service = GraphService(repo);
    await expectLater(service.generate('facts'), throwsA(isA<StateError>().having((e) => e.message, 'message', noFactWriterMessage)));
  });

  test('a window the model first answers badly is asked again; what is up to date is not asked for twice', () async {
    final (repo, _) = await noteWith(['The Swim function restores the heap property by swapping a node with its parent.']);
    final writer = FactWriter();
    var tries = 0;
    writer.answer = (doc) => ++tries < 3 ? 'Sorry, I cannot do that.' : 'Heaps: Swim Function | Method | The Swim function restores the heap property by swapping a node with its parent. | heap, swim';
    final service = GraphService(repo, ai: factWriterService(writer));
    final graph = await service.generate('facts');
    expect(graph, isNotNull);
    expect(writer.calls, 3);
    expect(graph!.nodes.where((n) => n.label == 'Heaps: Swim Function'), hasLength(1));
    await service.generate('facts');
    expect(writer.calls, 3); // (the note did not change)
  });

  test('a model that never answers usably gives no graph, and the run says how many parts were lost', () async {
    final (repo, _) = await noteWith(['The Swim function restores the heap property by swapping a node with its parent.']);
    final writer = FactWriter()..answer = (_) => 'no idea';
    final service = GraphService(repo, ai: factWriterService(writer));
    await service.start('facts');
    expect(service.lastMade, isNull);
    expect(service.problem, contains('did not write any facts'));
    expect(writer.calls, 3); // (once and twice again)
  });
}
