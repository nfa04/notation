import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The locks of notes (see `NoteLockService`) and which locked notes are open now. What may be read is decided here and nowhere else:
/// a locked note's content is out of the lists, the search and the graph (they ask for `lock_mode = 0`), and out of export and sharing
/// ([isReadable]) unless it has been unlocked in this run of the app.
class LockRepository {
  final Database _db;

  LockRepository(this._db);

  /// The notes whose content may be read now: unlocked in this run of the app. (Exporting and sharing check it.)
  final Set<String> unlocked = {};

  /// 0 not locked, 1 passcode, 2 encrypted; 0 for a note that is not there.
  Future<int> lockModeOf(String id) async {
    final rows = await _db.query('notes', columns: ['lock_mode'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? 0 : rows.single['lock_mode'] as int;
  }

  /// Whether the note may be read, written out or shared now: it is not locked, or has been unlocked.
  Future<bool> isReadable(String id) async => await lockModeOf(id) == 0 || unlocked.contains(id);

  /// The lock of a note; null if it has none.
  Future<LockRow?> lockRow(String id) async {
    final rows = await _db.query('note_locks', where: 'note_id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    return LockRow(
      mode: r['mode'] as int,
      salt: Uint8List.fromList(r['salt'] as List<int>),
      iterations: r['iterations'] as int,
      verifier: r['verifier'] == null ? null : Uint8List.fromList(r['verifier'] as List<int>),
      nonce: r['nonce'] == null ? null : Uint8List.fromList(r['nonce'] as List<int>),
      data: r['data'] == null ? null : Uint8List.fromList(r['data'] as List<int>),
      open: (r['open'] as int) == 1,
    );
  }

  /// Keeps the lock of a note (and its mode, which the lists look at).
  Future<void> putLock(String id, LockRow lock) => _db.transaction((txn) async {
        await txn.insert(
          'note_locks',
          {
            'note_id': id,
            'mode': lock.mode,
            'salt': lock.salt,
            'iterations': lock.iterations,
            'verifier': lock.verifier,
            'nonce': lock.nonce,
            'data': lock.data,
            'open': lock.open ? 1 : 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.update('notes', {'lock_mode': lock.mode}, where: 'id = ?', whereArgs: [id]);
      });

  Future<void> removeLock(String id) => _db.transaction((txn) async {
        await txn.delete('note_locks', where: 'note_id = ?', whereArgs: [id]);
        await txn.update('notes', {'lock_mode': 0}, where: 'id = ?', whereArgs: [id]);
      });

  /// Takes everything of a note out of the database (its pen strokes, text, pictures, PDF, title, what was read from it) and
  /// gives back the files that held pictures and the PDF, for the caller to delete. The note itself stays, empty.
  Future<List<String>> purgeContent(String id) async {
    final files = <String>[];
    final rows = await _db.query('notes', columns: ['pdf_path', 'theme_image'], where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      for (final k in ['pdf_path', 'theme_image']) {
        if (rows.single[k] != null) files.add(rows.single[k] as String);
      }
    }
    for (final r in await _db.query('images', columns: ['path'], where: 'note_id = ?', whereArgs: [id])) {
      files.add(r['path'] as String);
    }
    await _db.transaction((txn) async {
      for (final t in ['strokes', 'text_boxes', 'highlights', 'images', 'pdf_text', 'ink_text', 'note_embeddings', 'note_chunks', 'note_chunk_state', 'note_ai', 'facts', 'fact_state']) {
        await txn.delete(t, where: 'note_id = ?', whereArgs: [id]);
      }
      await txn.update(
        'notes',
        {
          'title': '',
          'document_text': '',
          'document_spans': '[]',
          'theme_image': null,
          'pdf_name': null,
          'pdf_path': null,
          'pdf_sha256': null,
          'pdf_page_count': null,
          'native_pages': '[]',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
    return files;
  }
}

/// A row of `note_locks`.
class LockRow {
  final int mode;
  final Uint8List salt;
  final int iterations;
  final Uint8List? verifier;
  final Uint8List? nonce;
  final Uint8List? data;
  final bool open;

  const LockRow({required this.mode, required this.salt, required this.iterations, this.verifier, this.nonce, this.data, this.open = false});

  LockRow copyWith({Uint8List? nonce, Uint8List? data, bool? open}) =>
      LockRow(mode: mode, salt: salt, iterations: iterations, verifier: verifier, nonce: nonce ?? this.nonce, data: data ?? this.data, open: open ?? this.open);
}
