import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Where another note refers to a note.
class Backlink {
  final String noteId;
  final String title;

  /// The page (zero-based) with the reference; null when it is in the written document, which is not on a page.
  final int? page;

  /// A few words around the reference.
  final String snippet;

  /// The reference is a link; false: the title of the note is only written there, without a link ("unlinked mention").
  final bool linked;

  const Backlink({required this.noteId, required this.title, required this.page, required this.snippet, required this.linked});
}

/// A link to a note as the editor writes it (see `noteLink`): `[label](note:id)`.
RegExp noteLinkPattern(String id) => RegExp(r'\[([^\]]*)\]\(note:' + RegExp.escape(id) + r'\)');

/// The ids of the notes [text] links to.
Set<String> linkedNoteIds(String text) => {for (final m in RegExp(r'\]\(note:([^)\s]+)\)').allMatches(text)) m.group(1)!};

/// A few words around the first place in [text] that [match] finds, with links shown as their label.
String snippetAround(String text, Match match, {int radius = 48}) {
  final plain = text.replaceAllMapped(RegExp(r'\[([^\]]*)\]\(note:[^)\s]+\)'), (m) => m.group(1)!);
  // the match moved because links before it got shorter: find it again by its label or text
  final needle = match.groupCount >= 1 && match.group(1) != null ? match.group(1)! : match.group(0)!;
  var at = plain.indexOf(needle);
  if (at < 0) at = 0;
  final start = (at - radius).clamp(0, plain.length), end = (at + needle.length + radius).clamp(0, plain.length);
  final cut = plain.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
  return '${start > 0 ? '… ' : ''}$cut${end < plain.length ? ' …' : ''}';
}

/// Finds which notes refer to a note: the links written into their text boxes and written documents (the `@` mentions), and
/// the notes that only say its title. Notes in the trash and locked notes are left out (their text is not read).
class LinkRepository {
  final Database _db;

  LinkRepository(this._db);

  static String _escape(String s) => s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  /// The places that link to [noteId], the note most recently changed first.
  Future<List<Backlink>> linksTo(String noteId) async {
    final pattern = noteLinkPattern(noteId);
    final like = '%](note:${_escape(noteId)})%';
    final out = <Backlink>[];
    final boxes = await _db.rawQuery('''
      SELECT t.note_id AS id, n.title AS title, t.page_index AS page, t.text AS text
      FROM text_boxes t JOIN notes n ON n.id = t.note_id
      WHERE t.text LIKE ? ESCAPE '\\' AND n.deleted_at IS NULL AND n.lock_mode = 0 AND t.note_id != ?
      ORDER BY n.updated_at DESC, t.page_index, t.seq
    ''', [like, noteId]);
    for (final r in boxes) {
      final m = pattern.firstMatch(r['text'] as String);
      if (m == null) continue;
      out.add(Backlink(noteId: r['id'] as String, title: r['title'] as String, page: r['page'] as int, snippet: snippetAround(r['text'] as String, m), linked: true));
    }
    final docs = await _db.rawQuery('''
      SELECT id, title, document_text AS text FROM notes
      WHERE document_text LIKE ? ESCAPE '\\' AND deleted_at IS NULL AND lock_mode = 0 AND id != ?
      ORDER BY updated_at DESC
    ''', [like, noteId]);
    for (final r in docs) {
      final m = pattern.firstMatch(r['text'] as String);
      if (m == null) continue;
      out.add(Backlink(noteId: r['id'] as String, title: r['title'] as String, page: null, snippet: snippetAround(r['text'] as String, m), linked: true));
    }
    return out;
  }

  /// Places that write the title of [noteId] without linking to it. Titles that are too short or are the default are not looked for.
  Future<List<Backlink>> mentionsOf(String noteId, String title) async {
    final name = title.trim();
    if (name.length < 4 || name == 'Untitled Note') return const [];
    final pattern = RegExp(RegExp.escape(name), caseSensitive: false);
    final like = '%${_escape(name)}%';
    final already = {for (final b in await linksTo(noteId)) b.noteId};
    final out = <Backlink>[];
    bool plainMention(String text) => pattern.allMatches(text).any((m) {
          // inside a link of any note it is only the label
          final before = text.lastIndexOf('[', m.start), close = text.lastIndexOf(']', m.start);
          return before <= close;
        });
    final boxes = await _db.rawQuery('''
      SELECT t.note_id AS id, n.title AS title, t.page_index AS page, t.text AS text
      FROM text_boxes t JOIN notes n ON n.id = t.note_id
      WHERE t.text LIKE ? ESCAPE '\\' AND n.deleted_at IS NULL AND n.lock_mode = 0 AND t.note_id != ?
      ORDER BY n.updated_at DESC, t.page_index, t.seq
    ''', [like, noteId]);
    final docs = await _db.rawQuery('''
      SELECT id, title, NULL AS page, document_text AS text FROM notes
      WHERE document_text LIKE ? ESCAPE '\\' AND deleted_at IS NULL AND lock_mode = 0 AND id != ?
      ORDER BY updated_at DESC
    ''', [like, noteId]);
    final seen = <String>{};
    for (final r in [...boxes, ...docs]) {
      final id = r['id'] as String, text = r['text'] as String;
      if (already.contains(id) || !plainMention(text) || !seen.add('$id/${r['page']}')) continue;
      final m = pattern.firstMatch(text)!;
      out.add(Backlink(noteId: id, title: r['title'] as String, page: r['page'] as int?, snippet: snippetAround(text, m), linked: false));
    }
    return out;
  }
}
