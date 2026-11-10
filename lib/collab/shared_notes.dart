import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How a note is shared, for the group symbol on notes.
enum SharedKind {
  none,

  /// The person shared it with others (copies were handed out, or a live session on it is running).
  byMe,

  /// It was shared with the person (a copy that was opened from a link, or a session that was joined).
  withMe,

  /// Both: a copy of someone's note that the person shared on.
  both;

  bool get isShared => this != none;
}

/// What the shares with people at a cloud service (`NativeShareService`) say about notes and folders, for the group symbol.
abstract class NativeMarks implements Listenable {
  SharedKind noteKind(String noteId);
  SharedKind folderKind(String folderId);

  /// Who a note that was shared with the person came from.
  String? noteFrom(String noteId);
}

/// Which notes are shared: the ones that came from other people are remembered here (they make the "Shared with
/// me" folder), the ones this person shared are asked of [byMe] (they follow the copies and sessions).
class SharedNotes extends ChangeNotifier {
  static const _key = 'shared_with_me';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  /// The notes this person shares with others right now.
  final Set<String> Function() byMe;

  SharedNotes(this._read, this._write, {required this.byMe});

  NativeMarks? _native;

  /// Adds what the shares with people say (null: nothing). Told of when they change.
  set native(NativeMarks? marks) {
    _native?.removeListener(notifyListeners);
    _native = marks;
    marks?.addListener(notifyListeners);
  }

  final Map<String, String> _withMe = {}; // note id -> who it is from (may be empty)
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final text = await _read(_key);
    try {
      if (text != null) _withMe.addAll((jsonDecode(text) as Map).cast<String, String>());
    } catch (_) {
      _withMe.clear();
    }
    notifyListeners();
  }

  /// The notes that were shared with the person.
  Set<String> get withMe => _withMe.keys.toSet();

  /// Who the note came from, if known.
  String? fromWhom(String noteId) {
    final who = _withMe[noteId] ?? _native?.noteFrom(noteId);
    return who == null || who.isEmpty ? null : who;
  }

  Future<void> markWithMe(String noteId, {String? from}) async {
    await load();
    if (_withMe[noteId] == (from ?? '')) return;
    _withMe[noteId] = from ?? '';
    await _write(_key, jsonEncode(_withMe));
    notifyListeners();
  }

  /// The note is not "shared with me" any more (it was deleted).
  Future<void> forget(String noteId) async {
    await load();
    if (_withMe.remove(noteId) == null) return;
    await _write(_key, jsonEncode(_withMe));
    notifyListeners();
  }

  /// How a folder is shared (only shares with people can be of a folder).
  SharedKind folderKind(String folderId) => _native?.folderKind(folderId) ?? SharedKind.none;

  SharedKind kindOf(String noteId) {
    final n = _native?.noteKind(noteId) ?? SharedKind.none;
    final mine = byMe().contains(noteId) || n == SharedKind.byMe || n == SharedKind.both;
    final theirs = _withMe.containsKey(noteId) || n == SharedKind.withMe || n == SharedKind.both;
    return mine && theirs ? SharedKind.both : (mine ? SharedKind.byMe : (theirs ? SharedKind.withMe : SharedKind.none));
  }
}
