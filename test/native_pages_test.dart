import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository repo;
  late String id;

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    repo = NoteRepository(db);
    id = await repo.createNote();
  });
  tearDown(() => db.close());

  test('the pages of a PDF that are notebook pages are kept, in any order they were given', () async {
    final note = (await repo.loadNote(id))!;
    expect(note.nativePages, isEmpty);
    note.nativePages = {4, 0, 2};
    await repo.saveNote(note);
    expect((await repo.loadNote(id))!.nativePages, {0, 2, 4});
  });

  test('a damaged column does not keep the note from opening', () async {
    for (final bad in ['not json', '{"a":1}', '[1,"x",-3,2.5,7]', 'null']) {
      await db.update('notes', {'native_pages': bad}, where: 'id = ?', whereArgs: [id]);
      final note = await repo.loadNote(id);
      expect(note, isNotNull, reason: bad);
      expect(note!.nativePages, bad == '[1,"x",-3,2.5,7]' ? {1, 7} : isEmpty, reason: bad);
    }
  });
}
