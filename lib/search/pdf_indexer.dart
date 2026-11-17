import '../pdf/open_pdf.dart';
import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

import '../data/note_pdfs.dart';
import '../data/note_repository.dart';

/// Reads the text of the PDFs that are in the notes, so that the search can look in them. Reads one PDF after the other, each
/// whole or not at all, and stops when [stop] says so.
class PdfIndexer {
  final NoteRepository repository;
  PdfIndexer(this.repository);

  bool _running = false;

  /// How many PDFs are left to read.
  Future<int> pending() async => (await repository.text.pdfsToRead()).length;

  /// Reads what is not read yet; [progress] is told (done, all) after each PDF.
  Future<void> run({bool Function()? stop, void Function(int done, int all)? progress}) async {
    if (_running) return;
    _running = true;
    try {
      final todo = await repository.text.pdfsToRead();
      var done = 0;
      progress?.call(0, todo.length);
      for (final pdf in todo) {
        if (stop?.call() ?? false) return;
        await _read(pdf.id, pdf.path, stop, table: pdf.table);
        progress?.call(++done, todo.length);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _read(String id, String path, bool Function()? stop, {NotePdfs? table}) async {
    if (table != null) return _readTable(id, table, stop);
    if (!await File(path).exists()) return;
    PdfDocument? doc;
    try {
      doc = await openPdfFile(path);
      final pages = <String>[];
      for (final page in doc.pages) {
        if (stop?.call() ?? false) return;
        pages.add((await page.loadText())?.fullText ?? "");
      }
      await repository.text.savePdfText(id, pages);
    } catch (_) {
      // a PDF that cannot be read is left out; the next search tries again
    } finally {
      await doc?.dispose();
    }
  }

  /// A note with several PDFs: the text of each page of the note, from the file and page its table says (a blank page has none).
  Future<void> _readTable(String id, NotePdfs table, bool Function()? stop) async {
    final docs = <int, PdfDocument>{};
    try {
      final texts = <String>[];
      for (final ref in table.layout) {
        if (stop?.call() ?? false) return;
        if (ref.isBlank) {
          texts.add('');
          continue;
        }
        final path = table.files[ref.file].path;
        if (!docs.containsKey(ref.file)) {
          if (!await File(path).exists()) return;
          docs[ref.file] = await openPdfFile(path);
        }
        texts.add((await docs[ref.file]!.pages[ref.page].loadText())?.fullText ?? '');
      }
      await repository.text.savePdfText(id, texts);
    } catch (_) {
      // a PDF that cannot be read is left out; the next search tries again
    } finally {
      for (final d in docs.values) {
        await d.dispose();
      }
    }
  }
}
