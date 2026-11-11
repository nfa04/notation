import 'dart:ui';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../search/search_query.dart';

/// A reading of handwriting kept in `ink_reads`: the key of the strokes, the ids of a selection's strokes (comma-separated; empty for
/// a block), and its text or its formula.
typedef InkRead = ({String key, String ids, String? text, String? latex});

/// The words of notes as the search and the AI read them: titles, documents, text boxes, the text of PDF pages and of handwriting.
/// Locked notes are never in it.
class NoteTextRepository {
  final Database _db;

  NoteTextRepository(this._db);

  /// Counts up when text that was read out of PDFs or handwriting is kept (a screen that holds [searchSources] for a while compares it).
  int indexVersion = 0;

  /// The text of each page of a PDF (once read, see PdfIndexer), or null when the note is locked, has none or has not been read yet.
  Future<List<String>?> pdfPages(String id) async {
    final live = await _db.query('notes', columns: ['id'], where: 'id = ? AND lock_mode = 0 AND deleted_at IS NULL AND pdf_path IS NOT NULL', whereArgs: [id]);
    if (live.isEmpty) return null;
    final rows = await _db.query('pdf_text', columns: ['page_index', 'text'], where: 'note_id = ?', whereArgs: [id], orderBy: 'page_index');
    if (rows.isEmpty) return null;
    final pages = List.filled((rows.last['page_index'] as int) + 1, '');
    for (final r in rows) {
      pages[r['page_index'] as int] = r['text'] as String;
    }
    return pages;
  }

  /// The text of the first [pages] pages of an imported PDF (once read, see PdfIndexer): where a paper has its title and DOI.
  Future<String> pdfStartText(String id, {int pages = 3}) async {
    final rows = await _db.query('pdf_text', columns: ['text'], where: 'note_id = ? AND page_index < ?', whereArgs: [id, pages], orderBy: 'page_index');
    return rows.map((r) => r['text'] as String).join('\n');
  }

  /// The words of a note: its title, the name of its PDF, the written document and its
  /// text boxes and the text of its PDF pages (once read, see PdfIndexer), at most [limit] characters. Pen strokes are not text and are not in it.
  Future<String> noteText(String id, {int limit = 8000}) async {
    final notes = await _db.query('notes', columns: ['title', 'pdf_name', 'document_text'], where: 'id = ? AND lock_mode = 0', whereArgs: [id]);
    if (notes.isEmpty) return ''; // (a locked note is not read by anything else)
    final n = notes.single;
    final parts = <String>[
      n['title'] as String,
      if (n['pdf_name'] != null) (n['pdf_name'] as String).replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '').replaceAll(RegExp(r'[_\-]+'), ' '),
      n['document_text'] as String,
      for (final b in await _db.query('text_boxes', columns: ['text'], where: 'note_id = ?', whereArgs: [id], orderBy: 'page_index, seq')) b['text'] as String,
      for (final b in await _db.query('pdf_text', columns: ['text'], where: 'note_id = ?', whereArgs: [id], orderBy: 'page_index')) b['text'] as String,
    ].where((t) => t.trim().isNotEmpty).toList();
    final text = parts.join('\n');
    return text.length > limit ? text.substring(0, limit) : text;
  }

  /// Every piece of text there is to search: titles, the names of PDFs, written documents, text boxes and the text of PDF pages
  /// that has been read. Of one note if [noteId] is given.
  Future<List<SearchSource>> searchSources({String? noteId}) async {
    final where = noteId == null ? 'deleted_at IS NULL AND lock_mode = 0' : 'id = ?';
    final args = noteId == null ? <Object?>[] : [noteId];
    final sources = <SearchSource>[];
    for (final n in await _db.query('notes', columns: ['id', 'title', 'pdf_name', 'document_text'], where: where, whereArgs: args)) {
      final id = n['id'] as String;
      sources.add(SearchSource(id, SearchPlace.title, n['title'] as String));
      if (n['pdf_name'] != null) sources.add(SearchSource(id, SearchPlace.pdfName, n['pdf_name'] as String));
      if ((n['document_text'] as String).isNotEmpty) sources.add(SearchSource(id, SearchPlace.document, n['document_text'] as String, page: 0));
    }
    final live = noteId == null ? 'note_id IN (SELECT id FROM notes WHERE deleted_at IS NULL AND lock_mode = 0)' : 'note_id = ?';
    for (final b in await _db.query('text_boxes', columns: ['note_id', 'page_index', 'text'], where: live, whereArgs: args, orderBy: 'note_id, page_index, seq')) {
      if ((b['text'] as String).isEmpty) continue;
      sources.add(SearchSource(b['note_id'] as String, SearchPlace.textBox, b['text'] as String, page: b['page_index'] as int));
    }
    for (final b in await _db.query('pdf_text', columns: ['note_id', 'page_index', 'text'], where: live, whereArgs: args, orderBy: 'note_id, page_index')) {
      if ((b['text'] as String).isEmpty) continue;
      sources.add(SearchSource(b['note_id'] as String, SearchPlace.pdfText, b['text'] as String, page: b['page_index'] as int));
    }
    for (final b in await _db.query('ink_text', columns: ['note_id', 'page_index', 'text'], where: live, whereArgs: args, orderBy: 'note_id, page_index, top, left')) {
      if ((b['text'] as String).isEmpty) continue;
      sources.add(SearchSource(b['note_id'] as String, SearchPlace.handwriting, b['text'] as String, page: b['page_index'] as int));
    }
    return sources;
  }

  /// The notes (not in the trash, not locked) that have pen strokes.
  Future<List<String>> noteIdsWithInk() async => [
        for (final r in await _db.rawQuery(
            'SELECT DISTINCT note_id FROM strokes WHERE note_id IN (SELECT id FROM notes WHERE deleted_at IS NULL AND lock_mode = 0)'))
          r['note_id'] as String,
      ];

  /// What was read of the handwriting of a note (see `InkIndexer`), blocks that came out empty included.
  Future<List<InkText>> inkTexts(String noteId) async => [
        for (final r in await _db.query('ink_text', where: 'note_id = ?', whereArgs: [noteId], orderBy: 'page_index, top, left'))
          InkText(
            key: r['key'] as String,
            page: r['page_index'] as int,
            text: r['text'] as String,
            bounds: Rect.fromLTRB((r['left'] as num).toDouble(), (r['top'] as num).toDouble(), (r['right'] as num).toDouble(), (r['bottom'] as num).toDouble()),
          ),
      ];

  /// Keeps what was read of the handwriting of [noteId]: [read] are added or replaced, and what is not among [alive] (the keys of
  /// the blocks of strokes the note has now) is dropped, as its strokes are gone or have changed.
  Future<void> saveInkText(String noteId, Iterable<InkText> read, Set<String> alive) async {
    await _saveInkText(noteId, read, alive);
    indexVersion++;
  }

  Future<void> _saveInkText(String noteId, Iterable<InkText> read, Set<String> alive) => _db.transaction((txn) async {
        final batch = txn.batch();
        for (final r in await txn.query('ink_text', columns: ['key'], where: 'note_id = ?', whereArgs: [noteId])) {
          if (!alive.contains(r['key'])) batch.delete('ink_text', where: 'note_id = ? AND key = ?', whereArgs: [noteId, r['key']]);
        }
        for (final t in read) {
          batch.insert(
            'ink_text',
            {
              'note_id': noteId,
              'key': t.key,
              'page_index': t.page,
              'text': t.text,
              'left': t.bounds.left,
              'top': t.bounds.top,
              'right': t.bounds.right,
              'bottom': t.bounds.bottom,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });

  /// What was read of the handwriting of [noteId] that is not for the search (see `ink_reads`): formulas, and conversions of
  /// selections that are not a whole block.
  Future<List<InkRead>> inkReads(String noteId) async => [
        for (final r in await _db.query('ink_reads', where: 'note_id = ?', whereArgs: [noteId]))
          (key: r['key'] as String, ids: r['ids'] as String, text: r['text'] as String?, latex: r['latex'] as String?),
      ];

  /// Keeps [reads] of [noteId] in place of what was kept before (they are few: a note's formulas and conversions).
  Future<void> saveInkReads(String noteId, Iterable<InkRead> reads) => _db.transaction((txn) async {
        final batch = txn.batch()..delete('ink_reads', where: 'note_id = ?', whereArgs: [noteId]);
        for (final r in reads) {
          batch.insert('ink_reads', {'note_id': noteId, 'key': r.key, 'ids': r.ids, 'text': r.text, 'latex': r.latex}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });

  /// PDF notes whose text has not been read completely yet: id, the file and the number of pages.
  Future<List<({String id, String path, int pages})>> pdfsToRead() async {
    final rows = await _db.rawQuery('''
      SELECT n.id, n.pdf_path, n.pdf_page_count,
             (SELECT COUNT(*) FROM pdf_text t WHERE t.note_id = n.id) AS done
        FROM notes n
       WHERE n.deleted_at IS NULL AND n.lock_mode = 0 AND n.pdf_path IS NOT NULL AND COALESCE(n.pdf_page_count, 0) > 0
    ''');
    return [
      for (final r in rows)
        if ((r['done'] as int) < (r['pdf_page_count'] as int)) (id: r['id'] as String, path: r['pdf_path'] as String, pages: r['pdf_page_count'] as int),
    ];
  }

  /// Keeps the text of the pages of PDF note [noteId], page 0 first.
  Future<void> savePdfText(String noteId, List<String> pages) async {
    await _savePdfText(noteId, pages);
    indexVersion++;
  }

  Future<void> _savePdfText(String noteId, List<String> pages) => _db.transaction((txn) async {
        await txn.delete('pdf_text', where: 'note_id = ?', whereArgs: [noteId]);
        final batch = txn.batch();
        for (var i = 0; i < pages.length; i++) {
          batch.insert('pdf_text', {'note_id': noteId, 'page_index': i, 'text': pages[i]});
        }
        await batch.commit(noResult: true);
      });
}
