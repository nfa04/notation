import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/note_pdfs.dart';
import '../data/note_text_repository.dart';
import '../pdf/note_pdf_document.dart';
import '../pdf/open_pdf.dart';
import 'study_material.dart';

/// The table of contents of a note's PDF (its one file at `pdf_path`, or the files of its page table) with the note's page numbers, and
/// how many pages the note's PDF has.
typedef PdfOutlineReader = Future<({List<PageHeading> outline, int pages})> Function(String pdfPath, NotePdfs? table);

/// Reads the table of contents with the PDF engine; none (and no pages) when the files cannot be opened.
Future<({List<PageHeading> outline, int pages})> readPdfOutline(String pdfPath, NotePdfs? table) async {
  final docs = <PdfDocument>[];
  try {
    for (final path in table == null ? [pdfPath] : [for (final f in table.files) f.path]) {
      docs.add(await openPdfFile(path));
    }
    // (a table keeps its files open for whoever opened them: they are let go below)
    final note = table == null ? NotePdfDocument.table(docs, [for (var i = 0; i < docs.single.pages.length; i++) PdfPageRef(0, i)]) : NotePdfDocument.table(docs, table.layout);
    return (outline: [for (final h in await note.outline()) (title: h.title, level: h.level, page: h.page)], pages: note.pages.length);
  } catch (e) {
    debugPrint('reading the table of contents of a PDF failed: $e');
    return (outline: const <PageHeading>[], pages: 0);
  } finally {
    for (final d in docs) {
      d.dispose();
    }
  }
}

/// What can be read about a note to cut it into parts for a study plan: its title, its PDF's pages and table of contents, its
/// written document and how many of its pages have something on them. Null when the note is gone (or in the trash).
Future<NoteShape?> readNoteShape(Database db, String noteId, {PdfOutlineReader? outline = readPdfOutline}) async {
  final rows = await db.query('notes',
      columns: ['title', 'lock_mode', 'document_text', 'pdf_path', 'pdf_page_count', 'pdf_files'], where: 'id = ? AND deleted_at IS NULL', whereArgs: [noteId]);
  if (rows.isEmpty) return null;
  final r = rows.single;
  final title = r['title'] as String;
  if ((r['lock_mode'] as int) != 0) return NoteShape(noteId: noteId, title: title, locked: true);
  final pdfPath = r['pdf_path'] as String?;
  final table = NotePdfs.fromJsonText(r['pdf_files'] as String?);
  var pdfPages = pdfPath == null ? 0 : (r['pdf_page_count'] as int?) ?? 0;
  var lastPage = -1;
  for (final t in ['strokes', 'text_boxes', 'images']) {
    final m = await db.rawQuery('SELECT MAX(page_index) AS m FROM $t WHERE note_id = ?', [noteId]);
    final v = m.first['m'];
    if (v is int && v > lastPage) lastPage = v;
  }
  var headings = const <PageHeading>[];
  if (pdfPath != null && outline != null) {
    final read = await outline(pdfPath, table);
    headings = read.outline;
    if (read.pages > 0) pdfPages = read.pages;
  }
  return NoteShape(
    noteId: noteId,
    title: title,
    pdfPages: pdfPages,
    pdfOutline: headings,
    notebookPages: lastPage + 1,
    documentText: r['document_text'] as String,
  );
}

/// The words of each page of the note [noteId] that were read (zero-based page -> text): the text of its PDF and of its handwriting. What
/// the topics of a run of pages are told by (see StudyTopicSplitter); pages that were not read are not in it.
Future<Map<int, String>> readPageTexts(NoteTextRepository texts, String noteId) async {
  final out = <int, String>{};
  final pdf = await texts.pdfPages(noteId);
  for (var i = 0; i < (pdf?.length ?? 0); i++) {
    if (pdf![i].trim().isNotEmpty) out[i] = pdf[i];
  }
  for (final t in await texts.inkTexts(noteId)) {
    if (t.text.trim().isEmpty) continue;
    out[t.page] = out[t.page] == null ? t.text : '${out[t.page]}\n${t.text}';
  }
  return out;
}
