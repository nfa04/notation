
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'note_data.dart';
import '../util/whole_number.dart';

/// What the AI made of a note (a summary, a presentation, ...), kept with the note (see `NoteAi`).
class NoteAiRepository {
  final Database _db;

  NoteAiRepository(this._db);

  Future<List<NoteAiRow>> of(String noteId, {String? kind}) async {
    final rows = await _db.query('note_ai',
        where: kind == null ? 'note_id = ?' : 'note_id = ? AND kind = ?', whereArgs: kind == null ? [noteId] : [noteId, kind], orderBy: 'created_at DESC');
    return [
      for (final r in rows)
        NoteAiRow(
          noteId: noteId,
          kind: r['kind'] as String,
          key: r['key'] as String,
          content: r['content'] as String,
          sourceHash: wholeNumber( r['source_hash']),
          model: r['model'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        ),
    ];
  }

  Future<NoteAiRow?> get(String noteId, String kind, [String key = '']) async =>
      (await of(noteId, kind: kind)).where((r) => r.key == key).firstOrNull;

  Future<void> put(NoteAiRow row) => _db.insert(
        'note_ai',
        {
          'note_id': row.noteId,
          'kind': row.kind,
          'key': row.key,
          'content': row.content,
          'source_hash': row.sourceHash,
          'model': row.model,
          'created_at': row.createdAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace
      );

  Future<void> delete(String noteId, String kind, [String key = '']) =>
      _db.delete('note_ai', where: 'note_id = ? AND kind = ? AND key = ?', whereArgs: [noteId, kind, key]);
}
