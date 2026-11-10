import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../tags/tag_names.dart';

/// The tags of notes (table `note_tags`): free words a person files notes under, nested with `/` ("school/maths"). A note with
/// a tag is also found under the tags it is nested in. Names are kept as [normalizeTag] makes them.
class TagRepository {
  final Database _db;

  TagRepository(this._db);

  final _changes = StreamController<void>.broadcast();

  /// Fires after a tag was given, taken away, renamed or deleted.
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// The tags of every note that has any (note id -> tags).
  Future<Map<String, Set<String>>> all() async {
    final out = <String, Set<String>>{};
    for (final r in await _db.query('note_tags')) {
      (out[r['note_id'] as String] ??= {}).add(r['tag'] as String);
    }
    return out;
  }

  Future<List<String>> tagsOf(String noteId) async {
    final rows = await _db.query('note_tags', columns: ['tag'], where: 'note_id = ?', whereArgs: [noteId], orderBy: 'tag');
    return [for (final r in rows) r['tag'] as String];
  }

  /// Every tag in use, with the number of notes that have exactly this tag.
  Future<Map<String, int>> counts() async {
    final rows = await _db.rawQuery('SELECT tag, COUNT(*) AS n FROM note_tags GROUP BY tag ORDER BY tag');
    return {for (final r in rows) r['tag'] as String: r['n'] as int};
  }

  /// Makes [tags] the tags of the note (the ones that are not names are dropped).
  Future<void> setTags(String noteId, Iterable<String> tags) async {
    final wanted = {for (final t in tags) ?normalizeTag(t)};
    await _db.transaction((txn) async {
      await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [noteId]);
      for (final t in wanted) {
        await txn.insert('note_tags', {'note_id': noteId, 'tag': t});
      }
    });
    _changed();
  }

  /// Gives every note of [noteIds] the tag.
  Future<void> add(Iterable<String> noteIds, String tag) async {
    final t = normalizeTag(tag);
    if (t == null) return;
    await _db.transaction((txn) async {
      for (final id in noteIds) {
        await txn.insert('note_tags', {'note_id': id, 'tag': t}, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
    _changed();
  }

  /// Takes the tag away from every note of [noteIds].
  Future<void> remove(Iterable<String> noteIds, String tag) async {
    await _db.transaction((txn) async {
      for (final id in noteIds) {
        await txn.delete('note_tags', where: 'note_id = ? AND tag = ?', whereArgs: [id, tag]);
      }
    });
    _changed();
  }

  /// The notes that have [tag] or a tag nested under it.
  Future<Set<String>> notesWith(String tag) async {
    final rows = await _db.query(
      'note_tags',
      columns: ['note_id'],
      where: "tag = ? OR tag LIKE ? ESCAPE '\\'",
      whereArgs: [tag, '${_like(tag)}/%'],
    );
    return {for (final r in rows) r['note_id'] as String};
  }

  static String _like(String s) => s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  /// Renames [from] and the tags nested under it to [to] ("a" -> "b" turns "a/x" into "b/x"). If a note then has the same tag
  /// twice (or [to] existed), they become one: that is how two tags are merged. The answer is how many notes were touched.
  Future<int> rename(String from, String to) async {
    final target = normalizeTag(to);
    if (target == null || target == from) return 0;
    final touched = <String>{};
    await _db.transaction((txn) async {
      final rows = await txn.query('note_tags', where: "tag = ? OR tag LIKE ? ESCAPE '\\'", whereArgs: [from, '${_like(from)}/%']);
      for (final r in rows) {
        final id = r['note_id'] as String, old = r['tag'] as String;
        await txn.delete('note_tags', where: 'note_id = ? AND tag = ?', whereArgs: [id, old]);
        await txn.insert('note_tags', {'note_id': id, 'tag': target + old.substring(from.length)}, conflictAlgorithm: ConflictAlgorithm.ignore);
        touched.add(id);
      }
    });
    if (touched.isNotEmpty) _changed();
    return touched.length;
  }

  /// Takes [tag] from every note. With [nested] the tags under it go too; without, they stay (and the levels in between remain).
  Future<void> delete(String tag, {bool nested = true}) async {
    await _db.delete(
      'note_tags',
      where: nested ? "tag = ? OR tag LIKE ? ESCAPE '\\'" : 'tag = ?',
      whereArgs: [tag, if (nested) '${_like(tag)}/%'],
    );
    _changed();
  }
}
