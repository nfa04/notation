import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/graph/graph_model.dart';
import 'package:notes/graph/graph_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fact_writer_fake.dart';

/// Writes facts as the standard fake does, and names the topics it is asked about (what [name] says, or fails).
class _Writer extends FactWriter {
  int namingCalls = 0;
  String Function(int number)? name = (n) => 'Topic name $n';
  bool failNaming = false;

  _Writer() {
    answer = (document) {
      if (document.contains('(words:')) {
        namingCalls++;
        if (failNaming) throw StateError('the service said 429');
        return [
          for (final m in RegExp(r'^(\d+) \(words:', multiLine: true).allMatches(document)) '${m[1]} | ${name!(int.parse(m[1]!))}',
        ].join('\n');
      }
      return [
        for (final line in document.split('\n'))
          if (line.trim().length > 30) '${line.split(' ').take(4).join(' ')}: Mechanism | Fact | ${line.trim()} | ${line.split(RegExp(r'\W+')).where((w) => w.length > 3).take(8).join(', ')}',
      ].join('\n');
    };
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  Future<(GraphService, _Writer, NoteRepository)> setup() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['saved_graphs', 'graph_versions', 'sync_tombstones']) {
      await db.delete(t);
    }
    final repo = NoteRepository(db);
    Future<void> make(String title, List<String> boxes) async {
      final id = await repo.createNote(title: title);
      final n = (await repo.loadNote(id))!;
      n.textBoxes[0] = [for (var i = 0; i < boxes.length; i++) TextBoxWidgetModel(id: '$title$i', position: Offset(10, 10.0 + i * 60), initialText: boxes[i])];
      await repo.saveNote(n);
    }

    await make('Biology', [
      'Mitochondria produce the energy of the cell and make ATP molecules for the cell.',
      'The cell nucleus holds the DNA and controls the cell activity of the organism.',
      'Ribosomes in the cell build proteins from the instructions of the DNA in the nucleus.',
    ]);
    await make('Contract law', [
      'An offer and its acceptance form a contract between the two parties of the contract.',
      'Consideration is needed to make the contract binding for both parties in contract law.',
      'A breach of contract gives the other party the right to damages under contract law.',
    ]);
    final writer = _Writer();
    return (GraphService(repo, ai: factWriterService(writer)), writer, repo);
  }

  test('a model names the topics, the names land on the topics and their hubs, and the names are marked as the model\'s', () async {
    final (service, writer, _) = await setup();
    service.nameTopics = true;
    final g = (await service.generate('facts'))!;
    expect(g.clusters, isNotEmpty);
    expect(g.clusters.every((c) => c.named && c.label == 'Topic name ${c.id + 1}'), isTrue, reason: '${g.clusters.map((c) => c.label)}');
    final hubs = g.nodes.where((n) => n.kind == GraphNodeKind.topic).toList();
    for (final h in hubs) {
      expect(h.label, g.clusters[h.cluster].label);
    }
    expect(writer.namingCalls, 1);
    // the same names come back out of the kept picture
    final kept = (await service.load(service.lastMadeId!))!;
    expect(kept.clusters.map((c) => (c.label, c.named)), g.clusters.map((c) => (c.label, c.named)));
  });

  test('without the option, or without a ready model, no request is made and the words stay', () async {
    final (service, writer, _) = await setup();
    final g = (await service.generate('facts'))!;
    expect(writer.namingCalls, 0);
    expect(g.clusters.any((c) => c.named), isFalse);
  });

  test('made again, topics with the same members keep their names, and no request is made for them', () async {
    final (service, writer, _) = await setup();
    service.nameTopics = true;
    final first = (await service.generate('facts'))!;
    final id = service.lastMadeId!;
    expect(writer.namingCalls, 1);
    writer.name = (n) => 'Other $n'; // if it were asked again the names would differ
    final again = (await service.generate('facts', replace: id))!;
    expect(writer.namingCalls, 1, reason: 'nothing new to name');
    expect(again.clusters.map((c) => c.label).toSet(), first.clusters.map((c) => c.label).toSet());
  });

  test('a model that fails leaves the words, still gives a graph, and says why', () async {
    final (service, writer, _) = await setup();
    service.nameTopics = true;
    writer.failNaming = true;
    await service.start('facts');
    expect(service.graphs, isNotEmpty);
    final g = (await service.load(service.lastMadeId!))!;
    expect(g.clusters.any((c) => c.named), isFalse);
    expect(service.notice, contains('429'));
    expect(service.problem, isNull);
  });

  test('making a graph over keeps the picture before it, and the service can compare, restore and delete it', () async {
    final (service, _, _) = await setup();
    await service.generate('facts');
    final id = service.lastMadeId!;
    final uid = service.graphs.single.uid;
    expect(await service.versionsOf(uid), isEmpty);
    await service.start('facts', replace: id);
    expect(service.lastReplaced, id);
    final versions = await service.versionsOf(uid);
    expect(versions, hasLength(1));
    final old = (await service.loadVersion(versions.single.id))!;
    expect(old.nodes, isNotEmpty);
    expect(await service.restoreVersion(versions.single.id), id);
    expect(service.graphs.single.id, id);
    final after = await service.versionsOf(uid);
    expect(after, hasLength(1));
    await service.deleteVersion(after.single.id);
    expect(await service.versionsOf(uid), isEmpty);
    // a new graph is not "made over"
    await service.start('facts');
    expect(service.lastReplaced, isNull);
  });
}
