import '../pdf/open_pdf.dart';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'file_digest.dart';
import 'note_repository.dart';

/// Makes a new note around the PDF at [source]: the file is copied to the app's own folder (the original may be moved or
/// deleted later), the note is named after it. Returns the id of the note. [directory] is where the copy goes (the app's folder for PDFs by default).
Future<String> createNoteFromPdf(NoteRepository repository, String source, {String? folderId, Directory? directory}) async {
  final dir = directory ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'pdfs'));
  await dir.create(recursive: true);
  final id = await repository.createNote(title: p.basenameWithoutExtension(source), folderId: folderId);
  final copy = p.join(dir.path, '$id-${DateTime.now().millisecondsSinceEpoch}.pdf');
  try {
    // (copied by the system and hashed in pieces on another isolate: a PDF of scans is hundreds of MB, which are not read into memory)
    await File(source).copy(copy);
    final sha = await sha256OfFile(copy);
    final PdfDocument doc = await openPdfFile(copy);
    final pages = doc.pages.length;
    await doc.dispose();
    final note = (await repository.loadNote(id))!;
    note
      ..pdfName = p.basename(source)
      ..pdfPath = copy
      ..pdfSha256 = sha
      ..pdfPageCount = pages;
    await repository.saveNote(note);
    return id;
  } catch (_) {
    await File(copy).delete().catchError((Object _) => File(copy));
    await repository.deleteNote(id);
    rethrow;
  }
}
