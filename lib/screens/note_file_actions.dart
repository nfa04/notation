import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import '../export/file_dialogs.dart';
import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

import '../data/note_file.dart';
import '../data/note_file_service.dart';
import '../l10n/language.dart';

bool get _phone => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// The file type and extensions to ask a picker for. A phone turns extensions into MIME types and refuses one it does not know
/// ("uninote") with "Unsupported filter", so there anything can be chosen and what is read decides whether it is the right kind.
({FileType type, List<String>? extensions}) pickerFilter(List<String> extensions) =>
    _phone ? (type: FileType.any, extensions: null) : (type: FileType.custom, extensions: extensions);

/// Asks where to put the file of a note and writes it. [beforeExport] runs first (the editor saves what is
/// being typed, so that the file holds it).
Future<void> saveNoteAsFile(
  BuildContext context,
  NoteFileService files,
  String noteId,
  String title, {
  Future<void> Function()? beforeExport,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await beforeExport?.call();
    final name = NoteFileService.fileNameFor(title, noteId);
    final bytes = await files.exportBytes(noteId);
    if (bytes == null) {
      messenger.showSnackBar(const SnackBar(content: Text('That note is gone')));
      return;
    }
    final path = await saveWithDialog(dialogTitle: 'Save the note as a file', fileName: name, extension: noteFileExtension, bytes: bytes);
    if (path == null) return; // cancelled
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Saved "{title}" as a file', {'title': title.isEmpty ? tr('Untitled') : title}))));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not save the note as a file: {error}', {'error': e})), duration: const Duration(seconds: 8)));
  }
}

/// Asks for a note file and makes a note of it. Returns the new note's id, or null if nothing was opened.
Future<String?> openNoteFile(BuildContext context, NoteFileService files, {String? folderId}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Open a note file',
      type: pickerFilter([noteFileExtension]).type,
      allowedExtensions: pickerFilter([noteFileExtension]).extensions,
    );
    if (file == null) return null;
    final path = file.path;
    // a file on disk is read where it is (a large note is not loaded into memory), anything else through the picker
    final result = path != null ? await files.importFile(path, folderId: folderId) : await files.importBytes(await file.readAsBytes(), folderId: folderId);
    messenger.showSnackBar(SnackBar(
      content: Text(result.warnings.isEmpty
          ? tr('Opened "{title}" as a new note', {'title': result.title.isEmpty ? tr('Untitled') : result.title})
          : tr('Opened "{title}", but: {warnings}', {'title': result.title, 'warnings': result.warnings.join('; ')})),
      duration: const Duration(seconds: 8),
    ));
    return result.noteId;
  } on NoteFileException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text.verbatim('$e'), duration: const Duration(seconds: 8)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not open the file: {error}', {'error': e})), duration: const Duration(seconds: 8)));
  }
  return null;
}
