/// Finds a file or a note from the way another note names it: a path relative to that note, a path from the root, just a name, or
/// the end of a path (Obsidian lets a link say only as much as is needed to tell two files apart).
class PathIndex<T> {
  final _exact = <String, T>{};
  final _byName = <String, List<String>>{};
  final _byNotionId = <String, T>{};

  /// How a path is looked up: lower case, `/` between the parts, a Markdown ending (`.md`) taken off (a link to a note does not need
  /// it, a link to a PDF does).
  static String key(String path) {
    var k = path.replaceAll('\\', '/').toLowerCase();
    while (k.startsWith('./')) {
      k = k.substring(2);
    }
    k = k.replaceFirst(RegExp(r'^/+'), '');
    if (k.endsWith('.md')) k = k.substring(0, k.length - 3);
    if (k.endsWith('.markdown')) k = k.substring(0, k.length - 9);
    return k;
  }

  static String _name(String key) => key.substring(key.lastIndexOf('/') + 1);

  void add(String path, T value) {
    final k = key(path);
    if (_exact.containsKey(k)) return;
    _exact[k] = value;
    (_byName[_name(k)] ??= []).add(k);
    final id = notionId(path);
    if (id != null) _byNotionId[id] = value;
  }

  /// The 32 hex digits Notion puts at the end of a page's name (before the ending), or null.
  static String? notionId(String text) {
    final m = RegExp(r'([0-9a-fA-F]{32})(?:\.[A-Za-z0-9]+)?/?(?:[?#].*)?$').firstMatch(text.replaceAll('-', ''));
    return m?.group(1)?.toLowerCase();
  }

  /// Where [target] (as a note at [from] writes it) points, or null when nothing is there.
  T? find(String target, String from) {
    var t = target.trim().replaceAll('\\', '/');
    if (t.isEmpty) return null;
    final fromDir = from.contains('/') ? from.substring(0, from.lastIndexOf('/')) : '';
    // next to the note, then from the root
    final beside = _normalised(fromDir.isEmpty ? t : '$fromDir/$t');
    if (beside != null) {
      final hit = _exact[key(beside)];
      if (hit != null) return hit;
    }
    final fromRoot = _normalised(t.replaceFirst(RegExp(r'^/+'), ''));
    if (fromRoot != null) {
      final hit = _exact[key(fromRoot)];
      if (hit != null) return hit;
    }
    final k = key(t);
    if (!k.contains('/')) {
      final names = _byName[k];
      if (names != null && names.isNotEmpty) return _exact[_nearest(names, fromDir.toLowerCase())];
    } else {
      // "folder/note" for "vault/school/folder/note"
      final matches = [for (final e in _exact.keys) if (e.endsWith('/$k')) e];
      if (matches.isNotEmpty) return _exact[_nearest(matches, fromDir.toLowerCase())];
    }
    final id = notionId(t);
    return id == null ? null : _byNotionId[id];
  }

  /// Of [keys] the one that shares the most folders with [dir] (the first by name if none does).
  static String _nearest(List<String> keys, String dir) {
    final here = dir.isEmpty ? <String>[] : dir.split('/');
    var best = keys.first, bestScore = -1;
    final sorted = [...keys]..sort();
    for (final k in sorted) {
      final parts = k.split('/');
      var shared = 0;
      while (shared < here.length && shared < parts.length - 1 && here[shared] == parts[shared]) {
        shared++;
      }
      if (shared > bestScore) {
        best = k;
        bestScore = shared;
      }
    }
    return best;
  }

  /// [path] with `.` and `..` resolved; null when it leaves the root.
  static String? _normalised(String path) {
    final out = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isEmpty) return null;
        out.removeLast();
      } else {
        out.add(part);
      }
    }
    return out.join('/');
  }
}
