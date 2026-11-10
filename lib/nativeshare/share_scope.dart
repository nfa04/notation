import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'share_model.dart';

/// Which notes and folders of the library a share is about, kept in `native_share_items`.
///
/// A shared note is just that note. A shared folder is the folder, everything below it, and the notes in them. What belongs to it is
/// worked out from the library ([refresh]) each time, so a note put in the folder by anyone joins, and a note moved out (or locked)
/// leaves - which does not delete it, here or for the others. What once belonged is remembered as long as it exists, so that a deletion
/// told by a participant reaches it and nothing else.
class ShareScope {
  final Database _db;
  final String shareId;
  final ShareKind kind;

  /// The note, or the folder, that the share is about.
  final String rootId;

  ShareScope(this._db, {required this.shareId, required this.kind, required this.rootId});

  final Set<String> _noteMembers = {}, _folderMembers = {};
  final Set<String> _currentNotes = {}, _currentFolders = {};
  bool _loaded = false;

  /// What belongs to the share now (what exists and is in it), and what has belonged (and may be deleted by a participant).
  Set<String> get currentNotes => _currentNotes;
  Set<String> get currentFolders => _currentFolders;

  bool hasNote(String id) => _noteMembers.contains(id);
  bool hasFolder(String id) => _folderMembers.contains(id);

  bool get isFolder => kind == ShareKind.folder;

  Future<void> _load() async {
    if (_loaded) return;
    for (final r in await _db.query('native_share_items', where: 'share_id = ?', whereArgs: [shareId])) {
      ((r['kind'] == 'note') ? _noteMembers : _folderMembers).add(r['id'] as String);
    }
    _loaded = true;
  }

  Future<void> _remember(String kind, Iterable<String> ids) async {
    for (final id in ids) {
      await _db.insert('native_share_items', {'share_id': shareId, 'kind': kind, 'id': id}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _forget(String kind, Iterable<String> ids) async {
    for (final id in ids) {
      await _db.delete('native_share_items', where: 'share_id = ? AND kind = ? AND id = ?', whereArgs: [shareId, kind, id]);
    }
  }

  /// Works out what belongs to the share from the library as it is now.
  Future<void> refresh() async {
    await _load();
    final existingNotes = {for (final r in await _db.query('notes', columns: ['id', 'folder_id', 'lock_mode'])) r['id'] as String: r};
    _currentNotes.clear();
    _currentFolders.clear();
    if (!isFolder) {
      final r = existingNotes[rootId];
      if (r != null && r['lock_mode'] == 0) _currentNotes.add(rootId);
    } else {
      final children = <String?, List<String>>{};
      final existingFolders = <String>{};
      for (final r in await _db.query('folders', columns: ['id', 'parent_id'])) {
        existingFolders.add(r['id'] as String);
        (children[r['parent_id'] as String?] ??= []).add(r['id'] as String);
      }
      if (existingFolders.contains(rootId)) {
        final todo = [rootId];
        while (todo.isNotEmpty) {
          final f = todo.removeLast();
          if (!_currentFolders.add(f)) continue;
          todo.addAll(children[f] ?? const []);
        }
      }
      for (final e in existingNotes.entries) {
        if (e.value['lock_mode'] == 0 && _currentFolders.contains(e.value['folder_id'])) _currentNotes.add(e.key);
      }
      // a folder that is not below the root any more (moved out) is no longer a member; one that was deleted stays, for deletions
      for (final f in _folderMembers.toList()) {
        if (existingFolders.contains(f) && !_currentFolders.contains(f)) {
          _folderMembers.remove(f);
          await _forget('folder', [f]);
        }
      }
    }
    for (final n in _noteMembers.toList()) {
      if (existingNotes.containsKey(n) && !_currentNotes.contains(n)) {
        _noteMembers.remove(n);
        await _forget('note', [n]);
      }
    }
    final newNotes = _currentNotes.difference(_noteMembers);
    final newFolders = _currentFolders.difference(_folderMembers);
    _noteMembers.addAll(newNotes);
    _folderMembers.addAll(newFolders);
    await _remember('note', newNotes);
    await _remember('folder', newFolders);
  }

  /// A note or folder taken in from a participant belongs to the share.
  Future<void> addNote(String id) async {
    await _load();
    if (_noteMembers.add(id)) await _remember('note', [id]);
  }

  Future<void> addFolder(String id) async {
    await _load();
    if (_folderMembers.add(id)) await _remember('folder', [id]);
  }
}
