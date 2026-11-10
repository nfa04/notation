import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'note_data.dart';
import 'note_repository.dart' show NoteRepository;

/// Templates the person saved: a note file kept under a name, to start new notes from.
class TemplateRepository {
  final Database _db;

  TemplateRepository(this._db);

  Future<List<SavedTemplate>> list() async {
    final rows = await _db.query('templates', columns: ['id', 'name', 'created_at'], orderBy: 'created_at DESC');
    return [for (final r in rows) SavedTemplate(r['id'] as String, r['name'] as String, DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int))];
  }

  Future<String> save(String name, Uint8List bytes) async {
    final id = NoteRepository.newId();
    await _db.insert('templates', {'id': id, 'name': name, 'created_at': DateTime.now().millisecondsSinceEpoch, 'data': bytes});
    return id;
  }

  Future<Uint8List?> bytes(String id) async {
    final rows = await _db.query('templates', columns: ['data'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Uint8List.fromList(rows.single['data'] as List<int>);
  }

  Future<void> delete(String id) => _db.delete('templates', where: 'id = ?', whereArgs: [id]);
}
