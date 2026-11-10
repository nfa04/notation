/// A tag as it is kept: lower case, no `#`, words joined with `-`, levels of a nested tag separated by `/` ("School/Maths 1" is
/// "school/maths-1"). Null when nothing is left of [input].
String? normalizeTag(String input) {
  final levels = <String>[];
  for (final part in input.trim().replaceFirst(RegExp(r'^#+'), '').split('/')) {
    final level = part.trim().toLowerCase().replaceAll(RegExp(r'[\s#,;]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (level.isNotEmpty) levels.add(level);
  }
  return levels.isEmpty ? null : levels.join('/');
}

/// The tags in [text], separated by commas, semicolons or spaces-after-`#` ("#work, school/maths"); duplicates once, in order.
List<String> parseTags(String text) {
  final out = <String>[];
  for (final piece in text.split(RegExp(r'[,;\n]'))) {
    // several "#a #b" in one piece
    final pieces = piece.contains('#') ? piece.split('#') : [piece];
    for (final p in pieces) {
      final t = normalizeTag(p);
      if (t != null && !out.contains(t)) out.add(t);
    }
  }
  return out;
}

/// [tag] and the tags it is nested in, shortest first: "a/b/c" -> a, a/b, a/b/c.
List<String> tagPath(String tag) {
  final parts = tag.split('/');
  return [for (var i = 1; i <= parts.length; i++) parts.sublist(0, i).join('/')];
}

/// Whether [tag] is [ancestor] or is nested somewhere under it.
bool tagIsUnder(String tag, String ancestor) => tag == ancestor || tag.startsWith('$ancestor/');

/// The last level of a tag ("a/b/c" -> "c").
String tagLeaf(String tag) => tag.substring(tag.lastIndexOf('/') + 1);

/// A tag in the tree of tags: [notes] is how many notes carry it or a tag nested under it.
class TagNode {
  final String tag;
  final int notes;
  final List<TagNode> children;

  const TagNode(this.tag, this.notes, this.children);

  int get depth => '/'.allMatches(tag).length;
}

/// The tree of [noteTags] (note id -> its tags). A note is counted once in a node even when it has several tags under it; the
/// levels in between exist even if no note has them itself. Children are sorted by name.
List<TagNode> buildTagTree(Map<String, Set<String>> noteTags) {
  final notesOf = <String, Set<String>>{};
  for (final e in noteTags.entries) {
    for (final tag in e.value) {
      for (final level in tagPath(tag)) {
        (notesOf[level] ??= {}).add(e.key);
      }
    }
  }
  List<TagNode> under(String? parent) {
    final names = [
      for (final t in notesOf.keys)
        if (parent == null ? !t.contains('/') : t.startsWith('$parent/') && !t.substring(parent.length + 1).contains('/')) t,
    ]..sort();
    return [for (final t in names) TagNode(t, notesOf[t]!.length, under(t))];
  }

  return under(null);
}
