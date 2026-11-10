import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('every setting kept through the notes repository is stamped with the time it was set, as the sync between devices needs', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    final repo = NoteRepository(db);
    final before = DateTime.now().millisecondsSinceEpoch;
    await repo.settings.set('translate_to', 'de');
    await repo.settings.setPenColors([Colors.red, Colors.blue]);

    expect(await repo.settings.get('translate_to'), 'de');
    expect((await repo.settings.penColors()).map((c) => c.toARGB32()), [Colors.red.toARGB32(), Colors.blue.toARGB32()]);
    final rows = await db.query('settings', where: "key IN ('translate_to', 'pen_colors')");
    expect(rows, hasLength(2));
    for (final r in rows) {
      expect(r['changed_at'] as int, greaterThanOrEqualTo(before), reason: r['key'] as String);
    }
    await db.close();
  });

  test('the lock state is one object: what the lock repository lets through, the others see', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    final repo = NoteRepository(db);
    final id = await repo.createNote(title: 'secret');
    expect(await repo.locks.isReadable(id), isTrue);
    await db.update('notes', {'lock_mode': 1}, where: 'id = ?', whereArgs: [id]);
    expect(await repo.locks.isReadable(id), isFalse);
    expect(await repo.text.noteText(id), '');
    repo.locks.unlocked.add(id);
    expect(await repo.locks.isReadable(id), isTrue);
    await db.close();
  });
}
