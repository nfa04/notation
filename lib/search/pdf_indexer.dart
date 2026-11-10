import '../pdf/open_pdf.dart';
import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

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
        await _read(pdf.id, pdf.path, stop);
        progress?.call(++done, todo.length);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _read(String id, String path, bool Function()? stop) async {
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
}
