import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/note_knowledge.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('the text of a note, and the passages the AI works on, include the text of its PDF pages', () async {
    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final id = await repo.createNote(title: 'Lecture');
    await repo.text.savePdfText(id, ['Mitochondria make energy', 'Ribosomes build proteins']);
    final text = await repo.text.noteText(id);
    expect(text, contains('Mitochondria'));
    expect(text, contains('Ribosomes'));
    expect((await chunksOfNote(repo, id)).map((c) => c.text).join('\n'), contains('Ribosomes'));
  });
}
