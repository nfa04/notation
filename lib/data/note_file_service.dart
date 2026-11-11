import '../util/apart.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/image_item.dart';
import 'audio_repository.dart';
import 'brush_library.dart';
import 'note_data.dart';
import 'note_file.dart';
import 'note_repository.dart';
import '../l10n/language.dart';

/// What opening a note file came to.
class ImportResult {
  final String noteId;
  final String title;
  final List<String> warnings;

  const ImportResult(this.noteId, this.title, this.warnings);
}

/// Notes as `.uninote` files ([noteFileExtension]): making one from a note (by hand, or by the
/// automation "Save the note as a file") and a note from one.
class NoteFileService {
  final NoteRepository _notes;
  final Future<Directory> Function() _support;

  /// The sounds kept with notes: written into a note's file and read from one; null: notes have none.
  AudioRepository? audio;

  /// The folder the app keeps its own files in (pictures, PDFs).
  Future<Directory> supportDirectory() => _support();

  NoteFileService(this._notes, {Future<Directory> Function()? supportDirectory})
      : _support = supportDirectory ?? getApplicationSupportDirectory;

  // ---- one note

  /// A file name for a note: its title, and the start of its id so that two notes with one title
  /// have two files.
  static String fileNameFor(String title, String id) {
    final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim().replaceAll(RegExp(r'^\.+'), '');
    final base = cleaned.isEmpty ? 'Untitled' : (cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned);
    final short = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return '$base (${short.length > 8 ? short.substring(short.length - 8) : short}).$noteFileExtension';
  }

  static String _extensionOf(String path, [String fallback = 'png']) {
    final e = p.extension(path).replaceFirst('.', '').toLowerCase();
    return e.isEmpty || e.length > 5 ? fallback : e;
  }

  Future<Uint8List?> _read(String? path) async {
    if (path == null) return null;
    try {
      return await File(path).readAsBytes();
    } on FileSystemException {
      return null; // gone: the file is made without it
    }
  }

  /// Whether the note is locked and not open now (what is in it cannot be written out).
  Future<bool> isLocked(String noteId) async => !await _notes.locks.isReadable(noteId);

  /// The note file of [noteId] as bytes; null if there is no such note.
  Future<Uint8List?> exportBytes(String noteId, {bool locked = false}) async {
    // a locked note is not written out (until it is unlocked): there is nothing in it to write, or it is not for others
    if (!locked && !await _notes.locks.isReadable(noteId)) return null;
    final note = await _notes.loadNote(noteId);
    if (note == null) return null;
    final times = await _notes.noteTimes(noteId);
    final images = <String, Uint8List>{};
    final extensions = <String, String>{};
    for (final list in note.images.values) {
      for (final ImageItem m in list) {
        final bytes = await _read(m.path);
        if (bytes != null) {
          images[m.id] = bytes;
          extensions[m.id] = _extensionOf(m.path);
        }
      }
    }
    // the pictures in the written document, kept by the app
    final documentImages = <String, Uint8List>{};
    for (final m in RegExp(r'!\[[^\]\n]*\]\((image:[^)\s]+)\)').allMatches(note.documentText)) {
      final target = m.group(1)!;
      if (documentImages.containsKey(target)) continue;
      final bytes = await _read(p.join((await _support()).path, 'images', p.basename(target.substring(6))));
      if (bytes != null) documentImages[target] = bytes;
    }
    final parts = NoteFileParts(
      note,
      documentImages: documentImages,
      createdAt: times?.created,
      updatedAt: times?.edited,
      pdf: await _read(note.pdfPath),
      themeImage: await _read(note.themeImage),
      themeExtension: _extensionOf(note.themeImage ?? ''),
      images: images,
      imageExtensions: extensions,
      ai: await _notes.ai.of(noteId),
      ink: InkReadingParts(texts: await _notes.text.inkTexts(noteId), reads: await _notes.text.inkReads(noteId)),
      audio: await _audioParts(noteId),
    );
    final entries = noteFileEntries(parts);
    // packing is the slow part: away from the screen
    return runApart(() => zipNoteFile(entries));
  }

  Future<List<AudioPart>> _audioParts(String noteId) async {
    final repo = audio;
    if (repo == null) return const [];
    final parts = <AudioPart>[];
    for (final a in await repo.list(noteId)) {
      final bytes = await repo.bytesOf(a);
      if (bytes != null) parts.add(AudioPart(id: a.id, kind: a.kind.name, title: a.title, bytes: bytes, durationMs: a.duration.inMilliseconds, createdAt: a.createdAt));
    }
    return parts;
  }

  /// Writes the note file of [noteId] into [dir] under the name its title gives it, and removes
  /// the file the note was given under an earlier title (the start of the id is in every name).
  /// Returns the path, or null if there is no such note.
  Future<String?> exportInto(String noteId, String dir) async {
    final info = await _notes.noteInfo(noteId);
    if (info == null) return null;
    final name = fileNameFor(info.title, noteId);
    final path = p.join(dir, name);
    if (!await exportTo(noteId, path)) return null;
    final tail = name.substring(name.lastIndexOf(' ('));
    try {
      await for (final f in Directory(dir).list()) {
        final other = p.basename(f.path);
        if (f is File && other != name && other.endsWith(tail)) await f.delete();
      }
    } on FileSystemException {
      // the folder cannot be listed: the new file is there all the same
    }
    return path;
  }

  /// Writes the note file of [noteId] to [path] (all of it or nothing). Returns false if there is no such note.
  Future<bool> exportTo(String noteId, String path) async {
    final bytes = await exportBytes(noteId);
    if (bytes == null) return false;
    await _writeAtomically(path, bytes);
    return true;
  }

  static Future<void> _writeAtomically(String path, Uint8List bytes) async {
    final temp = File('$path.part');
    await temp.parent.create(recursive: true);
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(path);
  }

  // ---- opening a file

  /// Makes a new note from a note file (the file stays as it is). The note is put in [folderId]; [id] is its id, a new one if not given.
  Future<ImportResult> importBytes(Uint8List bytes, {String? folderId, String? id}) async {
    final parsed = decodeNoteFile(bytes);
    id = await _notes.createNote(title: parsed.note.title, folderId: folderId, id: id);
    final warnings = await _materialise(id, parsed);
    return ImportResult(id, parsed.note.title, warnings);
  }

  /// Puts the content of a note file into the note [noteId], which is there but empty (a locked note being opened again).
  /// The note keeps its id, its folder and its dates.
  Future<ImportResult> restoreInto(String noteId, Uint8List bytes) async {
    final parsed = decodeNoteFile(bytes);
    final times = await _notes.noteTimes(noteId);
    final warnings = await _materialise(noteId, parsed);
    if (times != null) await _notes.setTimes(noteId, created: times.created, edited: times.edited);
    return ImportResult(noteId, parsed.note.title, warnings);
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Writes the files of [parsed] to disk and its content into the note [id].
  Future<List<String>> _materialise(String id, ParsedNoteFile parsed) async {
    final warnings = [...parsed.warnings];
    final support = (await _support()).path;
    final note = parsed.note;
    // a copy of the note under its new id; its files are put on disk
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final copy = NoteData(
      id: id,
      title: note.title,
      background: note.background,
      pageFormat: note.pageFormat,
      landscape: note.landscape,
      nativePages: Set.of(note.nativePages),
      layers: note.layers,
      marginLeft: note.marginLeft,
      marginRight: note.marginRight,
      marginTop: note.marginTop,
      marginBottom: note.marginBottom,
      documentText: note.documentText,
      documentSpans: note.documentSpans,
      strokes: note.strokes,
      textBoxes: note.textBoxes,
      highlights: note.highlights,
    );
    if (parsed.pdf != null) {
      final ok = note.pdfSha256 == null || sha256.convert(parsed.pdf!).toString() == note.pdfSha256;
      if (ok) {
        final dir = await Directory(p.join(support, 'pdfs')).create(recursive: true);
        final path = p.join(dir.path, '${stamp}_${note.pdfName ?? 'document.pdf'}'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'));
        await File(path).writeAsBytes(parsed.pdf!, flush: true);
        copy
          ..pdfName = note.pdfName
          ..pdfPath = path
          ..pdfSha256 = note.pdfSha256
          ..pdfPageCount = note.pdfPageCount;
      } else {
        warnings.add(tr('The PDF in the file does not match its checksum and was left out'));
      }
    }
    // the pictures of the written document go where its text says they are
    for (final e in parsed.documentImages.entries) {
      if (!e.key.startsWith('image:')) continue;
      final dir = await Directory(p.join(support, 'images')).create(recursive: true);
      final target = File(p.join(dir.path, p.basename(e.key.substring(6))));
      // (a picture the device has under that name is never replaced by one from a file: another note may be showing it)
      if (await target.exists() && !_sameBytes(await target.readAsBytes(), e.value)) {
        warnings.add(tr('A picture in the file has the name of another picture on this device and was left out'));
        continue;
      }
      await target.writeAsBytes(e.value, flush: true);
    }
    var n = 0;
    for (final e in note.images.entries) {
      final placed = <ImageItem>[];
      for (final m in e.value) {
        final image = parsed.images[m.id]!;
        final dir = await Directory(p.join(support, 'images')).create(recursive: true);
        final path = p.join(dir.path, '${stamp}_${n++}.${image.extension}');
        await File(path).writeAsBytes(image.bytes, flush: true);
        placed.add(ImageItem(id: m.id, path: path, position: m.position, size: m.size, author: m.author, layer: m.layer, group: m.group));
      }
      copy.images[e.key] = placed;
    }
    // the brushes the lines were drawn with: kept (not in the brush menu), so that the lines look as they were made to. Before the note
    // is saved, which tells the screens (and makes the picture of the note on the dashboard) that it is there
    if (parsed.brushes.isNotEmpty) await BrushLibrary(_notes.settings).adopt(parsed.brushes);
    await _notes.saveNote(copy);
    final sounds = audio;
    for (final a in parsed.audio) {
      if (sounds == null) break;
      try {
        await sounds.add(id, a.bytes,
            kind: AudioKind.values.where((k) => k.name == a.kind).firstOrNull ?? AudioKind.recording,
            title: a.title,
            duration: Duration(milliseconds: a.durationMs),
            id: a.id,
            createdAt: a.createdAt);
      } on ArgumentError {
        warnings.add(tr('A sound with an unusable name was left out'));
      }
    }
    for (final a in parsed.ai) {
      await _notes.ai.put(NoteAiRow(noteId: id, kind: a.kind, key: a.key, content: a.content, sourceHash: a.sourceHash, model: a.model, createdAt: a.createdAt));
    }
    // what the handwriting reader made of the strokes (the keys are the same here, so nothing is read twice); a failure here loses
    // only that
    if (!parsed.ink.isEmpty) {
      try {
        // (a note that is there already keeps the readings it has: the file's are added to them; what no longer fits its strokes is
        // dropped when the editor keeps its readings)
        final known = {for (final t in await _notes.text.inkTexts(id)) t.key};
        if (parsed.ink.texts.isNotEmpty) await _notes.text.saveInkText(id, parsed.ink.texts, {...known, for (final t in parsed.ink.texts) t.key});
        if (parsed.ink.reads.isNotEmpty) {
          final mine = await _notes.text.inkReads(id);
          final fromFile = {for (final r in parsed.ink.reads) r.key};
          await _notes.text.saveInkReads(id, [...mine.where((r) => !fromFile.contains(r.key)), ...parsed.ink.reads]);
        }
      } catch (e) {
        warnings.add(tr('The readings of the handwriting in the file were left out'));
      }
    }
    if (parsed.themeImage != null) {
      final dir = await Directory(p.join(support, 'note_images')).create(recursive: true);
      final path = p.join(dir.path, '$stamp.${parsed.themeExtension}');
      await File(path).writeAsBytes(parsed.themeImage!, flush: true);
      await _notes.setNoteThemeImage(id, path);
    }
    return warnings;
  }

  Future<ImportResult> importFile(String path, {String? folderId}) async =>
      importBytes(await File(path).readAsBytes(), folderId: folderId);

}
