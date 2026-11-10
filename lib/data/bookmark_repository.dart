import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A page the person marked to come back to.
class PageBookmark {
  /// Zero-based.
  final int page;

  /// What the person called it; empty: shown as the page.
  final String label;

  const PageBookmark(this.page, this.label);

  @override
  bool operator ==(Object other) => other is PageBookmark && other.page == page && other.label == label;

  @override
  int get hashCode => Object.hash(page, label);
}

/// The bookmarked pages of notes (table `page_bookmarks`).
class BookmarkRepository {
  final Database _db;

  BookmarkRepository(this._db);

  final _changes = StreamController<void>.broadcast();

  /// Fires after a bookmark was added, renamed, moved or removed.
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// The bookmarks of the note, first page first.
  Future<List<PageBookmark>> list(String noteId) async {
    final rows = await _db.query('page_bookmarks', where: 'note_id = ?', whereArgs: [noteId], orderBy: 'page_index');
    return [for (final r in rows) PageBookmark(r['page_index'] as int, r['label'] as String)];
  }

  /// Marks the page, or takes the mark away when it is there. The answer is whether the page is marked now.
  Future<bool> toggle(String noteId, int page) async {
    final removed = await _db.delete('page_bookmarks', where: 'note_id = ? AND page_index = ?', whereArgs: [noteId, page]);
    if (removed == 0) {
      await _db.insert('page_bookmarks', {'note_id': noteId, 'page_index': page, 'label': '', 'created_at': DateTime.now().millisecondsSinceEpoch});
    }
    _changed();
    return removed == 0;
  }

  Future<void> setLabel(String noteId, int page, String label) async {
    await _db.update('page_bookmarks', {'label': label.trim()}, where: 'note_id = ? AND page_index = ?', whereArgs: [noteId, page]);
    _changed();
  }

  /// Replaces all bookmarks of the note by [bookmarks] (when pages were moved, added or deleted).
  Future<void> replace(String noteId, Iterable<PageBookmark> bookmarks) async {
    await _db.transaction((txn) async {
      await txn.delete('page_bookmarks', where: 'note_id = ?', whereArgs: [noteId]);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final b in bookmarks) {
        await txn.insert('page_bookmarks', {'note_id': noteId, 'page_index': b.page, 'label': b.label, 'created_at': now}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    _changed();
  }
}

/// The bookmarks after pages were reshaped: the bookmark on page `i` goes to page `to(i)`, and goes away when that is null. Two on
/// one page become one (the one that was there first keeps its label unless it has none).
List<PageBookmark> moveBookmarks(List<PageBookmark> bookmarks, int? Function(int page) to) {
  final byPage = <int, PageBookmark>{};
  for (final b in bookmarks) {
    final n = to(b.page);
    if (n == null) continue;
    final there = byPage[n];
    byPage[n] = there == null || there.label.isEmpty ? PageBookmark(n, b.label.isEmpty && there != null ? there.label : b.label) : there;
  }
  return [for (final k in byPage.keys.toList()..sort()) byPage[k]!];
}
