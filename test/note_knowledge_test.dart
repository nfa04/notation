import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/note_knowledge.dart';
import 'package:notes/automations/note_sorter.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'note_sorting_test.dart' show FakeEmbedder;

void main() {
  setUpAll(AppDatabase.initFfi);

  Future<(NoteRepository, String, String, String)> notes() async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    String id = '';
    Future<String> make(String title, List<String> boxes) async {
      id = await repo.createNote(title: title);
      final n = (await repo.loadNote(id))!;
      n.textBoxes[0] = [for (var i = 0; i < boxes.length; i++) TextBoxWidgetModel(id: '$title$i', position: Offset(10, 10.0 + i * 50), initialText: boxes[i])];
      await repo.saveNote(n);
      return id;
    }

    final bio = await make('Biology', ['Mitochondria produce the energy of the cell, they make ATP.', 'The nucleus holds the DNA of the cell.']);
    final law = await make('Contract law', ['An offer and its acceptance form a contract; consideration is needed.']);
    final trip = await make('Holiday', ['Pack the sunscreen and book the train to Lisbon for the summer.']);
    return (repo, bio, law, trip);
  }

  test('the closest note and its best passage are found for a question', () async {
    final (repo, bio, law, _) = await notes();
    final embedder = FakeEmbedder();
    final knowledge = NoteKnowledge(repo, embedder, NoteSorter(repo, embedder, ready: () => true), ready: () => true);

    final found = await knowledge.retrieve('Which organelle produces energy and ATP in the cell?', notes: 2);
    expect(found.notes.first.id, bio);
    expect(found.passages.first.text, contains('Mitochondria'));
    expect(found.render(2000), contains('[Biology - '));

    final other = await knowledge.retrieve('Is an acceptance of an offer binding as a contract?', notes: 1);
    expect(other.notes.single.id, law);
  });

  test('passages are made once and again only when the note changes', () async {
    final (repo, bio, _, _) = await notes();
    final embedder = FakeEmbedder();
    final knowledge = NoteKnowledge(repo, embedder, NoteSorter(repo, embedder, ready: () => true), ready: () => true);
    expect(await knowledge.analyse(bio), greaterThan(1));
    final asked = embedder.calls;
    await knowledge.analyse(bio);
    expect(embedder.calls, asked);
    final n = (await repo.loadNote(bio))!;
    n.textBoxes[0]!.first.controller.text = 'Ribosomes make proteins.';
    await repo.saveNote(n);
    await knowledge.analyse(bio);
    expect(embedder.calls, greaterThan(asked));
    expect((await repo.knowledge.chunksOf(bio)).any((c) => c.text.contains('Ribosomes')), isTrue);
  });

  test('without a sentence model the words find the passages, and a locked note is not read', () async {
    final (repo, bio, _, _) = await notes();
    final knowledge = NoteKnowledge(repo, const NoEmbedder(), NoteSorter(repo, const NoEmbedder(), ready: () => false), ready: () => false);
    final found = await knowledge.retrieve('Where does the nucleus keep the DNA?', notes: 1);
    expect(found.notes.single.id, bio);
    expect(found.passages.first.text, contains('nucleus'));
    expect((await repo.knowledge.chunksOf(bio)).every((c) => c.vector == null), isTrue);
  });
}
