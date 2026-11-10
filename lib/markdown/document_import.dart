import 'dart:convert';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import 'docx_import.dart';
import 'html_import.dart';

/// The file types a document can be read from: the ones it can be exported as.
const documentImportExtensions = ['docx', 'html', 'htm', 'md', 'markdown', 'txt', 'pdf'];

/// Reads the file [name] with [bytes] into the written document, by the type its name ends in. Throws a [FormatException] for a type
/// that cannot be read.
Future<DocxImport> importDocumentFile(String name, Uint8List bytes, {Future<String?> Function(Uint8List bytes, String ext)? keepPicture}) async {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  switch (ext) {
    case 'docx':
      return importDocx(bytes, keepPicture: keepPicture);
    case 'html' || 'htm':
      return importHtml(utf8.decode(bytes, allowMalformed: true));
    case 'md' || 'markdown' || 'txt':
      return DocxImport(_trimmed(utf8.decode(bytes, allowMalformed: true)), const []);
    case 'pdf':
      return DocxImport(await _pdfText(bytes), const []);
  }
  throw const FormatException('This type of file cannot be read into a document.');
}

String _trimmed(String s) => s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('﻿', '').trim();

/// The text of the pages of a PDF, a page break between them.
Future<String> _pdfText(Uint8List bytes) async {
  final PdfDocument doc;
  try {
    doc = await PdfDocument.openData(bytes);
  } catch (_) {
    throw const FormatException('This is not a PDF.');
  }
  try {
    final pages = <String>[];
    for (final page in doc.pages) {
      pages.add(_trimmed((await page.loadText())?.fullText ?? ''));
    }
    return pages.join('\n\n\\pagebreak\n\n').trim();
  } finally {
    await doc.dispose();
  }
}
