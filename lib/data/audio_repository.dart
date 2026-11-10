import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../audio/sound_marks.dart';
import '../audio/wav.dart';
import 'note_repository.dart';
import 'safe_names.dart';

/// Where a piece of sound comes from.
enum AudioKind {
  /// Recorded while the person spoke (a meeting, a dictation); what was said is in the note as text.
  recording,

  /// The text of the note read out by a voice, to listen to later.
  speech,
}

/// A sound kept with a note.
class NoteAudio {
  final String id;
  final String noteId;
  final AudioKind kind;
  final String title;

  /// The name of the file in the audio folder.
  final String file;
  final Duration duration;
  final int bytes;
  final DateTime createdAt;

  const NoteAudio({required this.id, required this.noteId, required this.kind, required this.title, required this.file, required this.duration, required this.bytes, required this.createdAt});
}

/// The sounds kept with notes: a row in `note_audio` and a file in the audio folder for each.
class AudioRepository {
  final Database _db;
  final Future<Directory> Function() _root;

  /// [root] is the folder the sound files go in (made when needed).
  AudioRepository(this._db, {required Future<Directory> Function() root}) : _root = root;

  final _changes = StreamController<void>.broadcast();

  /// Fires after a sound was added, renamed or removed.
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  final _added = StreamController<NoteAudio>.broadcast();

  /// The recordings as they are kept here (what the person recorded or dictated; not a note read aloud, and not the sounds a note file
  /// brings along).
  Stream<NoteAudio> get recorded => _added.stream;

  static NoteAudio _audio(Map<String, Object?> r) => NoteAudio(
        id: r['id'] as String,
        noteId: r['note_id'] as String,
        kind: AudioKind.values.where((k) => k.name == r['kind']).firstOrNull ?? AudioKind.recording,
        title: r['title'] as String,
        file: r['file'] as String,
        duration: Duration(milliseconds: r['duration_ms'] as int),
        bytes: r['bytes'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  /// The sounds of the note, the first made first.
  Future<List<NoteAudio>> list(String noteId) async {
    final rows = await _db.query('note_audio', where: 'note_id = ?', whereArgs: [noteId], orderBy: 'created_at, id');
    return rows.map(_audio).toList();
  }

  /// How many sounds each note has (only notes that have any).
  Future<Map<String, int>> counts() async {
    final rows = await _db.rawQuery('SELECT note_id, COUNT(*) AS n FROM note_audio GROUP BY note_id');
    return {for (final r in rows) r['note_id'] as String: r['n'] as int};
  }

  /// The file of a sound by the name kept in its row; null if that name leads out of the audio folder.
  Future<File?> _fileFor(String file) async {
    final root = (await _root()).path;
    final path = p.join(root, file);
    return isInside(root, path) ? File(path) : null;
  }

  /// Keeps [wav] (a WAV file) with the note. [id] is given when a note file brings its sounds along (the same id again replaces it).
  Future<NoteAudio> add(String noteId, Uint8List wav, {AudioKind kind = AudioKind.recording, String title = '', Duration? duration, String? id, DateTime? createdAt}) async {
    final newId = id ?? NoteRepository.newId();
    // both become parts of a path, and a note file of somebody else names its sounds
    if (!isSafeId(noteId) || !isSafeId(newId)) throw ArgumentError('A sound needs a plain note id and sound id (letters, digits, - and _).');
    final dir = await Directory(p.join((await _root()).path, noteId)).create(recursive: true);
    final name = p.join(noteId, '$newId.wav');
    await File(p.join(dir.path, '$newId.wav')).writeAsBytes(wav, flush: true);
    final length = duration ?? readWavInfo(wav)?.duration ?? Duration.zero;
    final at = createdAt ?? DateTime.now();
    await _db.insert('note_audio', {
      'id': newId,
      'note_id': noteId,
      'kind': kind.name,
      'title': title,
      'file': name,
      'duration_ms': length.inMilliseconds,
      'bytes': wav.length,
      'created_at': at.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _changed();
    final audio = NoteAudio(id: newId, noteId: noteId, kind: kind, title: title, file: name, duration: length, bytes: wav.length, createdAt: at);
    if (id == null && kind == AudioKind.recording && !_added.isClosed) _added.add(audio);
    return audio;
  }

  /// Keeps which moment of the sound [audioId] each of [marks] (the strokes and text boxes written while it was recorded) belongs to.
  Future<void> saveMarks(String noteId, String audioId, Iterable<SoundMark> marks) async {
    final batch = _db.batch();
    batch.delete('audio_marks', where: 'note_id = ? AND audio_id = ?', whereArgs: [noteId, audioId]);
    for (final m in marks) {
      batch.insert('audio_marks', {'note_id': noteId, 'audio_id': audioId, 'element_id': m.elementId, 'page_index': m.page, 'offset_ms': m.offsetMs},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    _changed();
  }

  /// Where each element of the note was written, by the element's id; an element that was written in two recordings has the later one.
  Future<Map<String, SoundPoint>> marksOf(String noteId) async {
    final rows = await _db.rawQuery('''
      SELECT m.element_id, m.audio_id, m.offset_ms FROM audio_marks m JOIN note_audio a ON a.note_id = m.note_id AND a.id = m.audio_id
       WHERE m.note_id = ? ORDER BY a.created_at, m.offset_ms''', [noteId]);
    return {for (final r in rows) r['element_id'] as String: SoundPoint(r['audio_id'] as String, r['offset_ms'] as int)};
  }

  /// The file of a sound, if it is still there.
  Future<File?> fileOf(NoteAudio audio) async {
    final f = await _fileFor(audio.file);
    return f != null && await f.exists() ? f : null;
  }

  Future<Uint8List?> bytesOf(NoteAudio audio) async => (await fileOf(audio))?.readAsBytes();

  Future<void> rename(NoteAudio audio, String title) async {
    await _db.update('note_audio', {'title': title.trim()}, where: 'note_id = ? AND id = ?', whereArgs: [audio.noteId, audio.id]);
    _changed();
  }

  Future<void> remove(NoteAudio audio) async {
    await _db.delete('note_audio', where: 'note_id = ? AND id = ?', whereArgs: [audio.noteId, audio.id]);
    await _db.delete('audio_marks', where: 'note_id = ? AND audio_id = ?', whereArgs: [audio.noteId, audio.id]);
    final f = await _fileFor(audio.file);
    if (f != null && await f.exists()) await f.delete();
    _changed();
  }

  /// Removes every sound of a note, rows and files (the note is encrypted, or its sounds were put into its sealed block).
  Future<void> removeAllFor(String noteId) async {
    final rows = await _db.query('note_audio', where: 'note_id = ?', whereArgs: [noteId]);
    await _db.delete('note_audio', where: 'note_id = ?', whereArgs: [noteId]);
    for (final r in rows) {
      final f = await _fileFor(r['file'] as String);
      if (f != null && await f.exists()) await f.delete();
    }
    if (rows.isNotEmpty) _changed();
  }

  /// Deletes the files that no note has a row for any more (a note was deleted for good, and its rows with it). Answers how many.
  Future<int> purgeOrphans() async {
    final root = await _root();
    if (!await root.exists()) return 0;
    final known = {for (final r in await _db.query('note_audio', columns: ['file'])) p.normalize(r['file'] as String)};
    var gone = 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (!known.contains(p.normalize(p.relative(e.path, from: root.path)))) {
        await e.delete();
        gone++;
      }
    }
    return gone;
  }
}
