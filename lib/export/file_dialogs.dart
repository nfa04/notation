import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// The kinds of file the app saves, by extension, for the dialog of a phone (it offers the apps that take that kind).
const _mimeTypes = {
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'zip': 'application/zip',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'tex': 'application/x-tex',
  'apkg': 'application/octet-stream',
  'json': 'application/json',
  'svg': 'image/svg+xml',
  'html': 'text/html',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'bib': 'text/x-bibtex',
  'ris': 'application/x-research-info-systems',
};

bool get _computer => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// Asks where to put [bytes] and puts them there. Returns where they went (a path on a computer, what the system says on a phone), or
/// null when the person cancelled. The picker writes the file itself; what it does not do on a computer is give the file the
/// [extension] a person leaves out, so that is done here.
Future<String?> saveWithDialog({
  required String dialogTitle,
  required String fileName,
  required Uint8List bytes,
  required String extension,
}) async {
  final saved = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    bytes: bytes,
    mimeType: _mimeTypes[extension.toLowerCase()] ?? 'application/octet-stream',
  );
  if (saved == null) return null;
  if (saved.scheme != 'file') return saved.toString();
  var path = saved.toFilePath();
  if (_computer && !path.toLowerCase().endsWith('.${extension.toLowerCase()}')) {
    final named = '$path.$extension';
    await File(path).rename(named);
    path = named;
  }
  return path;
}
