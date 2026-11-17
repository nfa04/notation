import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/note_pdfs.dart';
import 'session.dart';

/// The PDFs of a note with several, as they go to the others in a live session: each file as it is, with the table of pages.
Future<SharedPdf> sharedPdfOfTable(NotePdfs table) async {
  final files = <SharedPdf>[];
  for (final f in table.files) {
    files.add(SharedPdf(f.name, f.sha256, f.pages, await File(f.path).readAsBytes()));
  }
  return SharedPdf(files.first.name, files.first.sha256, files.first.pages, files.first.bytes, more: files.skip(1).toList(), layout: table.layout);
}

/// The PDFs [pdf] holds (a table) written as files in [dir], each under a name that starts with [stem]; the table, with where they are.
Future<NotePdfs> keepSharedTable(SharedPdf pdf, Directory dir, String stem) async {
  final all = [pdf, ...pdf.more];
  final paths = <String>[];
  try {
    for (var i = 0; i < all.length; i++) {
      final path = p.join(dir.path, '${stem}_$i ${all[i].name}'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'));
      await File(path).writeAsBytes(all[i].bytes, flush: true);
      paths.add(path);
    }
  } catch (_) {
    for (final path in paths) {
      File(path).delete().catchError((Object _) => File(path));
    }
    rethrow;
  }
  return pdf.table(paths)!;
}
