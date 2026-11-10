import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/note_knowledge.dart';
import 'package:notes/automations/note_sorter.dart';
import 'package:notes/citations/citation_repository.dart';
import 'package:notes/citations/citation_service.dart';
import 'package:notes/citations/source.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/graph/graph_builder.dart';
import 'package:notes/graph/graph_model.dart';
import 'package:notes/graph/graph_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'note_sorting_test.dart' show FakeEmbedder;

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository repo;
  late CitationService citations;
  late String smithNote, doeNote, otherNote;

  Future<String> make(String title, String text, {bool document = false}) async {
    final id = await repo.createNote(title: title);
    final n = (await repo.loadNote(id))!;
    if (document) {
      n.documentText = text;
    } else {
      n.textBoxes[0] = [TextBoxWidgetModel(id: '${title}0', position: const Offset(10, 10), initialText: text)];
    }
    await repo.saveNote(n);
    return id;
  }

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    repo = NoteRepository(db);
    citations = CitationService(CitationRepository(SettingsRepository(db)));
    await citations.add(const CitationSource(id: 'smith2020', type: SourceType.article, title: 'Neural networks for note taking', authors: [Person('Smith', 'John')], year: 2020, container: 'Journal of Notes'));
    await citations.add(const CitationSource(id: 'doe2019', title: 'The Book of Citing', authors: [Person('Doe', 'Jane')], year: 2019, publisher: 'Penguin'));
    smithNote = await make('Learning', 'Memory is built in layers [@smith2020, p. 4]. Also [@doe2019].');
    doeNote = await make('Writing', 'Always cite your sources [@doe2019].', document: true);
    otherNote = await make('Holiday', 'Pack the sunscreen and book the train to Lisbon.');
  });

  tearDown(() => db.close());

  test('the sources each note cites are found in text boxes and written documents', () async {
    expect(await repo.knowledge.noteCitations(), {
      smithNote: {'smith2020', 'doe2019'},
      doeNote: {'doe2019'},
    });
  });

  group('the graph', () {
    test('notes that cite the same source are joined, and told apart from similar ones', () {
      final inputs = [
        for (final id in ['a', 'b', 'c']) GraphInput(id: id, kind: GraphNodeKind.note, label: id, noteId: id),
      ];
      final g = buildGraph('notes', inputs, shared: [('a', 'b', 2)]);
      expect(g.edges, hasLength(1));
      expect(g.edges.single.kind, GraphEdgeKind.cites);
      expect(g.edges.single.weight, closeTo(0.85, 1e-9));
      // a graph that was kept is read again
      expect(KnowledgeGraph.decode(g.encode())!.edges.single.kind, GraphEdgeKind.cites);
    });

    test('pairs are counted by shared sources, and a source everybody cites joins nobody', () {
      final cited = {
        'a': {'x', 'y'},
        'b': {'x', 'y'},
        'c': {'x', 'common'},
        for (var i = 0; i < GraphService.commonSource; i++) 'n$i': {'common'},
      };
      final pairs = GraphService.sharedSources(cited, cited.keys.toSet());
      expect(pairs.toSet(), {('a', 'b', 2), ('a', 'c', 1), ('b', 'c', 1)});
      expect(GraphService.sharedSources(cited, {'a', 'c'}), [('a', 'c', 1)]); // only the notes in the graph
    });
  });

  group('the assistant', () {
    NoteKnowledge knowledge({CitationService? with_}) {
      final e = FakeEmbedder();
      return NoteKnowledge(repo, e, NoteSorter(repo, e, ready: () => true), ready: () => true, citations: with_);
    }

    test('"which note quotes Smith?" finds the note that cites Smith and says what it cites', () async {
      final found = await knowledge(with_: citations).retrieve('Which note quotes Smith?', notes: 1);
      expect(found.notes.map((n) => n.id), contains(smithNote));
      expect(found.notes.map((n) => n.id), isNot(contains(otherNote)));
      final rendered = found.render(4000);
      expect(rendered, contains('This note cites'));
      expect(rendered, contains('Smith, J. (2020). Neural networks for note taking'));
      expect(rendered, isNot(contains('Doe, J.'))); // only what the question is about
    });

    test('a title or a key names a source too, and every note that cites it is read', () async {
      final byTitle = await knowledge(with_: citations).retrieve('Where do I use the book of citing?', notes: 1);
      expect(byTitle.notes.map((n) => n.id).toSet(), {smithNote, doeNote});
      final byKey = await knowledge(with_: citations).retrieve('what cites smith2020', notes: 1);
      expect(byKey.notes.first.id, smithNote);
    });

    test('without the library nothing is added', () async {
      final found = await knowledge().retrieve('Which note quotes Smith?', notes: 1);
      expect(found.render(4000), isNot(contains('This note cites')));
    });
  });
}
