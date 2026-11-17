import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/assistant_chat.dart';
import 'package:notes/ai/note_agent.dart';
import 'package:notes/ai/note_knowledge.dart';
import 'package:notes/ai/notes_agent_api.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'support/fake_model.dart';
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

  test('notes that say something like a text are found by their kept vectors; the note itself is left out; gaps fill in over time', () async {
    final (repo, bio, law, trip) = await notes();
    final embedder = FakeEmbedder();
    final knowledge = NoteKnowledge(repo, embedder, NoteSorter(repo, embedder, ready: () => true), ready: () => true);
    const text = 'Mitochondria produce the energy of the cell, they make ATP. The nucleus holds the DNA.';

    // (the database is shared by the tests of this file: other notes are in it, and some have been read)
    expect((await knowledge.similarNotes(text, exceptNote: trip, learn: 0)).any((f) => f.noteId == bio), isFalse); // not read yet: not found
    final found = await knowledge.similarNotes(text, exceptNote: trip, learn: 50); // (the notes read now count at once)
    expect(found.map((f) => f.noteId), contains(bio));
    expect(found.any((f) => f.noteId == law), isFalse);
    expect(found.any((f) => f.noteId == trip), isFalse);

    // the note being written is never its own echo
    knowledge.forgetVectors(); // (and what was kept in the database is found again)
    final self = await knowledge.similarNotes(text, exceptNote: bio);
    expect(self.any((f) => f.noteId == bio), isFalse);

    // too short a text says nothing, and without the model there is nothing to read with
    expect(await knowledge.similarNotes('ATP', exceptNote: trip), isEmpty);
    final off = NoteKnowledge(repo, embedder, NoteSorter(repo, embedder, ready: () => false), ready: () => false);
    expect(await off.similarNotes(text, exceptNote: trip), isEmpty);
  });

  test('without a sentence model the words find the passages, and a locked note is not read', () async {
    final (repo, bio, _, _) = await notes();
    final knowledge = NoteKnowledge(repo, const NoEmbedder(), NoteSorter(repo, const NoEmbedder(), ready: () => false), ready: () => false);
    final found = await knowledge.retrieve('Where does the nucleus keep the DNA?', notes: 1);
    expect(found.notes.single.id, bio);
    expect(found.passages.first.text, contains('nucleus'));
    expect((await repo.knowledge.chunksOf(bio)).every((c) => c.vector == null), isTrue);
  });

  test('a question about the latest notes is answered from the notes changed last, with their dates', () async {
    final (repo, bio, law, trip) = await notes();
    final now = DateTime.now();
    // (the database is shared by the tests of this file: the notes of the others are made old)
    for (final n in await repo.listNotes()) {
      if (![bio, law, trip].contains(n.id)) await repo.setTimes(n.id, created: now.subtract(const Duration(days: 400)), edited: now.subtract(const Duration(days: 400)));
    }
    await repo.setTimes(bio, created: now.subtract(const Duration(days: 60)), edited: now.subtract(const Duration(days: 40)));
    await repo.setTimes(law, created: now.subtract(const Duration(days: 60)), edited: now.subtract(const Duration(days: 30)));
    await repo.setTimes(trip, created: now.subtract(const Duration(days: 2)), edited: now.subtract(const Duration(hours: 3)));
    final knowledge = NoteKnowledge(repo, const NoEmbedder(), NoteSorter(repo, const NoEmbedder(), ready: () => false), ready: () => false);
    expect(asksAboutRecent('Summarize my latest notes'), isTrue);
    expect(asksAboutRecent('Was habe ich gestern geschrieben?'), isTrue);
    expect(asksAboutRecent('What is ATP?'), isFalse);
    final found = await knowledge.retrieve('Summarize my latest notes', notes: 1);
    expect(found.notes.single.id, trip);
    expect(found.passages.map((p) => p.text).join(' '), contains('Lisbon'));
    expect(found.render(2000), contains('changed ${now.subtract(const Duration(hours: 3)).year}-'));
    // what the words say still counts among the recent ones
    final law2 = await knowledge.retrieve('What did I write about contracts recently?', notes: 1);
    expect(law2.notes.single.id, law);
  });

  test('the vectors kept for a note are handed out only for the model in use', () async {
    final (repo, bio, _, _) = await notes();
    final embedder = FakeEmbedder();
    final knowledge = NoteKnowledge(repo, embedder, NoteSorter(repo, embedder, ready: () => true), ready: () => true);
    expect(await knowledge.keptVectors(bio), isEmpty); // never read
    await knowledge.analyse(bio);
    final kept = await knowledge.keptVectors(bio);
    expect(kept.keys.join(), contains('Mitochondria'));
    final off = NoteKnowledge(repo, embedder, NoteSorter(repo, embedder, ready: () => false), ready: () => false);
    expect(await off.keptVectors(bio), isEmpty);
    expect(await off.embed('x'), isNull);
  });

  test('the assistant of all notes searches, asks before it files, and has no tools of an open note', () async {
    final (repo, bio, _, _) = await notes();
    final embedder = FakeEmbedder();
    final knowledge = NoteKnowledge(repo, embedder, NoteSorter(repo, embedder, ready: () => true), ready: () => true);
    final model = FakeModel();
    final replies = <String>[
      '<tool>{"name":"notes.search","args":{"query":"Mitochondria"}}</tool>',
      '<tool>{"name":"note.insertText","args":{"text":"x"}}</tool>',
      '<tool>{"name":"notes.favorite","args":{"id":"$bio","on":true}}</tool>',
      'Starred it.',
    ];
    model.respond = (_) => replies.removeAt(0);
    var changed = 0;
    final chat = AssistantChat(
      ai: AiService(providers: [model]),
      knowledge: knowledge,
      agent: NoteAgent(api: NotesAgentApi(repo, isOpen: (_) => false)),
      granted: const {ExtensionPermission.notesReadAll},
      onChanged: () => changed++,
    )..acting = true;
    final done = chat.ask('Star my biology note');
    // (real database work is going on: wait until it asks, not for a number of turns)
    for (var i = 0; i < 200 && !(chat.messages.last.steps.isNotEmpty && chat.messages.last.steps.last.state == AgentStepState.asking); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final steps = chat.messages.last.steps;
    expect(steps.map((s) => s.state), [AgentStepState.done, AgentStepState.failed, AgentStepState.asking], reason: 'reading is granted, the in-note tool does not exist, filing asks');
    expect(model.prompts.first.system, contains('no note is open'));
    expect(model.prompts.first.system, isNot(contains('note.insertText {')));
    chat.decide(AgentChoice.once);
    await done;
    expect(chat.messages.last.text, 'Starred it.');
    expect(changed, 1);
    expect((await repo.listNotes()).firstWhere((n) => n.id == bio).favorite, isTrue);
  });
}
