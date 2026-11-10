import '../util/apart.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../collab/note_delta.dart';
import '../collab/replica.dart';
import '../data/note_data.dart';
import '../data/file_digest.dart';
import '../data/note_file.dart';
import '../data/note_repository.dart';
import '../data/safe_zip.dart';
import 'version_diff.dart' show matchLines;

/// Why a version was made.
enum VersionReason {
  /// Now and then while the note was being changed.
  edit,

  /// When the note was left after a change.
  left,

  /// Just before changes from someone else were taken in.
  merge,

  /// Just before an earlier version was restored.
  restore,

  /// Just before the note joined a live session (which takes in the other side's note).
  joined,

  /// The person saved it, with a name.
  manual,

  /// Just before the note was switched to another branch (or a branch was made from an earlier version).
  branch,

  /// Just before the assistant changed the note (the label says what it was about to do).
  assistantBefore,

  /// Just after the assistant changed the note: the note as the assistant made it (the label says what it did).
  assistant,
}

/// An earlier state of a note.
class NoteVersion {
  final String id;
  final String noteId;
  final DateTime at;

  /// Saved by the person (kept until they delete it), as opposed to made by the app (thinned out over time).
  final bool manual;
  final String? label;
  final VersionReason reason;

  /// Whose changes came in right after it ([VersionReason.merge]).
  final String? who;

  /// The line of versions it belongs to ([NoteHistory.mainBranch] unless the note was on a branch).
  final String branch;

  /// The bytes it takes on disk on its own (the PDF and pictures it shares with other versions are not counted).
  final int size;

  final String _file;
  final String _fingerprint;

  const NoteVersion._(this.id, this.noteId, this.at, this.manual, this.label, this.reason, this.who, this.branch, this.size, this._file, this._fingerprint);

  static NoteVersion _fromRow(Map<String, Object?> r) => NoteVersion._(
        r['id'] as String,
        r['note_id'] as String,
        DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        r['manual'] == 1,
        r['label'] as String?,
        VersionReason.values.where((v) => v.name == r['reason']).firstOrNull ?? VersionReason.edit,
        r['who'] as String?,
        r['branch'] as String? ?? NoteHistory.mainBranch,
        r['size'] as int? ?? 0,
        r['file'] as String,
        r['fingerprint'] as String,
      );
}

/// A line of versions of a note: the main one, or one that was branched off to try something without touching the rest.
class NoteBranch {
  final String name;

  /// The version it began from (null for the main branch).
  final String? base;
  final DateTime created;

  /// The note is on this branch now: the versions made from now on are added to it.
  final bool active;

  const NoteBranch(this.name, this.base, this.created, this.active);
}

/// What taking the changes of a branch into the note comes to.
class BranchMerge {
  /// The changes to apply to the note (see `NoteHistory.restoreChanges`), with the pictures' bytes.
  final List<CollabOp> changes;

  /// Things changed on both sides in different ways: the note keeps its own.
  final int conflicts;

  /// The version the branch is at: the next merge begins from there.
  final NoteVersion head;

  const BranchMerge(this.changes, this.conflicts, this.head);
}

/// Where each thing of a note comes from: the version it first appeared in with the look it has now (a thing that changed
/// since is from the version where it last changed), for the drawings, text boxes, pictures and highlights by `kind:id`,
/// and for each line of the written document.
class NoteBlame {
  /// The versions the note went through, oldest first (the branch's, after the part of the branch it was made from).
  final List<NoteVersion> versions;

  /// The index in [versions] of the version each thing is from; -1: it is from before the oldest kept version; [versions].length: it
  /// is not in any version yet (made after the newest).
  final Map<String, int> origin;

  /// The same for each line of the written document, and the lines.
  final List<int> lineOrigin;
  final List<String> lines;

  const NoteBlame(this.versions, this.origin, this.lineOrigin, this.lines);

  /// How many things (not lines) are from each version.
  Map<int, int> get counts {
    final out = <int, int>{};
    for (final i in origin.values) {
      out[i] = (out[i] ?? 0) + 1;
    }
    return out;
  }
}

/// The history of notes: earlier states, made by the app now and then (and before anything from someone else is taken
/// in), or saved by the person with a name. A version is the note file of the note ([noteFileEntries]) without its
/// PDF and pictures: those are kept once in a folder of their own by their checksum, so a hundred versions of a note
/// made from a big PDF hold the PDF once.
///
/// Versions the app makes are thinned out as they get older ([keep]); the ones the person saved are kept until they
/// delete them.
class NoteHistory extends ChangeNotifier {
  final Database _db;
  final NoteRepository _notes;
  final Future<Directory> Function() _support;
  final DateTime Function() _now;

  /// The least time between two versions made while a note is being changed.
  final Duration every;

  /// How long after a save the version is made (so that it is not made in the middle of a stroke of changes).
  final Duration settle;

  NoteHistory(this._db, this._notes,
      {Future<Directory> Function()? supportDirectory, DateTime Function()? now, this.every = const Duration(minutes: 10), this.settle = const Duration(seconds: 10)})
      : _support = supportDirectory ?? getApplicationSupportDirectory,
        _now = now ?? DateTime.now;

  /// The name of the line of versions every note begins with.
  static const mainBranch = 'main';

  StreamSubscription<String>? _saves;
  final Map<String, Timer> _pending = {};

  /// Starts making versions as notes are saved, and clears away files of versions that are gone.
  void start() {
    _saves ??= _notes.saved.listen(_saved);
    unawaited(cleanUp());
  }

  @override
  void dispose() {
    _saves?.cancel();
    for (final t in _pending.values) {
      t.cancel();
    }
    super.dispose();
  }

  /// Forgets every version of [noteId] and the version that was about to be made: an encrypted note that is put away leaves no
  /// plain copies of itself behind.
  Future<void> forgetNote(String noteId) async {
    _pending.remove(noteId)?.cancel();
    for (final v in await list(noteId)) {
      await _db.delete('note_versions', where: 'id = ?', whereArgs: [v.id]);
      await _deleteFile(v._file);
    }
    await _collect();
    notifyListeners();
  }

  /// The notes whose timer is being set: a save that comes while the last version is looked up must not set a second one.
  final Set<String> _starting = {};

  void _saved(String noteId) {
    if (_pending.containsKey(noteId) || !_starting.add(noteId)) return; // one is coming: it takes the note as it is then
    () async {
      try {
        final last = await _latest(noteId, automaticOnly: true);
        final due = last == null ? _now() : last.at.add(every);
        final wait = due.difference(_now());
        _pending[noteId] = Timer(wait > settle ? wait : settle, () {
          _pending.remove(noteId);
          unawaited(snapshot(noteId).catchError((Object e) {
            debugPrint('[history] could not make a version: $e');
            return null;
          }));
        });
      } finally {
        _starting.remove(noteId);
      }
    }();
  }

  Future<Directory> _dir(String name) async => Directory(p.join((await _support()).path, 'versions', name)).create(recursive: true);

  /// The newest version of the branch the note is on (or of [branch]).
  Future<NoteVersion?> _latest(String noteId, {bool automaticOnly = false, String? branch}) async {
    final rows = await _db.query('note_versions',
        where: automaticOnly ? 'note_id = ? AND manual = 0 AND branch = ?' : 'note_id = ? AND branch = ?',
        whereArgs: [noteId, branch ?? await activeBranch(noteId)],
        orderBy: 'created_at DESC',
        limit: 1);
    return rows.isEmpty ? null : NoteVersion._fromRow(rows.single);
  }

  /// The versions of [noteId], newest first: of every branch, or only of [branch].
  Future<List<NoteVersion>> list(String noteId, {String? branch}) async {
    final rows = await _db.query('note_versions',
        where: branch == null ? 'note_id = ?' : 'note_id = ? AND branch = ?', whereArgs: [noteId, ?branch], orderBy: 'created_at DESC');
    return [for (final r in rows) NoteVersion._fromRow(r)];
  }

  Future<NoteVersion?> _byId(String id) async {
    final rows = await _db.query('note_versions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : NoteVersion._fromRow(rows.single);
  }

  // ---- branches

  /// The branches of [noteId]: the main one first, then the others by when they were made.
  Future<List<NoteBranch>> branches(String noteId) async {
    final rows = await _db.query('note_branches', where: 'note_id = ?', whereArgs: [noteId], orderBy: 'created_at');
    final others = [for (final r in rows) NoteBranch(r['name'] as String, r['base'] as String?, DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int), r['active'] == 1)];
    return [NoteBranch(mainBranch, null, DateTime.fromMillisecondsSinceEpoch(0), !others.any((b) => b.active)), ...others];
  }

  /// The name of the branch the note is on.
  Future<String> activeBranch(String noteId) async {
    final rows = await _db.query('note_branches', columns: ['name'], where: 'note_id = ? AND active = 1', whereArgs: [noteId], limit: 1);
    return rows.isEmpty ? mainBranch : rows.single['name'] as String;
  }

  Future<void> _activate(String noteId, String name) async {
    await _db.update('note_branches', {'active': 0}, where: 'note_id = ?', whereArgs: [noteId]);
    if (name != mainBranch) await _db.update('note_branches', {'active': 1}, where: 'note_id = ? AND name = ?', whereArgs: [noteId, name]);
  }

  /// The newest version of [branch]; a branch with no version of its own yet is at the version it began from.
  Future<NoteVersion?> head(String noteId, String branch) async {
    final own = await _latest(noteId, branch: branch);
    if (own != null || branch == mainBranch) return own;
    final rows = await _db.query('note_branches', columns: ['base'], where: 'note_id = ? AND name = ?', whereArgs: [noteId, branch], limit: 1);
    final base = rows.isEmpty ? null : rows.single['base'] as String?;
    return base == null ? null : _byId(base);
  }

  /// Makes a branch called [name] and puts the note on it: from the note as it is now (kept as a version of the branch it is on first),
  /// or from the earlier [version] (the note is kept as it is first; the caller then makes the note what [version] was). The versions
  /// made from now on belong to the new branch. Throws if the name is taken or empty.
  Future<NoteBranch> createBranch(String noteId, String name, {NoteVersion? from}) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.toLowerCase() == mainBranch) throw StateError('"$name" cannot be the name of a branch');
    if ((await branches(noteId)).any((b) => b.name.toLowerCase() == clean.toLowerCase())) throw StateError('There is a branch called "$clean" already');
    final here = await snapshot(noteId, reason: VersionReason.branch);
    final base = from ?? here;
    if (base == null) throw StateError('This note cannot have branches (it is encrypted, or gone)');
    final created = _now();
    await _db.insert('note_branches', {'note_id': noteId, 'name': clean, 'base': base.id, 'created_at': created.millisecondsSinceEpoch, 'active': 0});
    await _activate(noteId, clean);
    notifyListeners();
    return NoteBranch(clean, base.id, created, true);
  }

  /// Puts the note on [name]: the note as it is now is kept as a version of the branch it was on. Returns the version the branch is at,
  /// which the caller makes the note (null: nothing to change).
  Future<NoteVersion?> switchTo(String noteId, String name) async {
    if (!(await branches(noteId)).any((b) => b.name == name)) throw StateError('There is no branch "$name"');
    if (await activeBranch(noteId) == name) return null;
    await snapshot(noteId, reason: VersionReason.branch);
    await _activate(noteId, name);
    notifyListeners();
    return head(noteId, name);
  }

  /// Removes [name] and its versions. Not the main branch, not the one the note is on, not one that another branch began from.
  Future<void> deleteBranch(String noteId, String name) async {
    if (name == mainBranch) throw StateError('The main branch cannot be deleted');
    if (await activeBranch(noteId) == name) throw StateError('The note is on this branch: switch to another one first');
    final versions = await list(noteId, branch: name);
    final ids = {for (final v in versions) v.id};
    final dependent = await _db.query('note_branches', where: 'note_id = ? AND name <> ?', whereArgs: [noteId, name]);
    if (dependent.any((r) => ids.contains(r['base']))) throw StateError('Another branch began from a version of this one');
    for (final v in versions) {
      await _db.delete('note_versions', where: 'id = ?', whereArgs: [v.id]);
      await _deleteFile(v._file);
      _digested.remove(v.id);
    }
    await _db.delete('note_branches', where: 'note_id = ? AND name = ?', whereArgs: [noteId, name]);
    await _collect();
    notifyListeners();
  }

  /// What taking the changes of the branch [source] into the note [current] (on the branch it is on) comes to: what the branch changed
  /// since it began (or since the last merge) and the note has not, three ways. Where both changed a thing, the note's stays.
  Future<BranchMerge> mergeChanges(String noteId, String source, NoteData current) async {
    final active = await activeBranch(noteId);
    if (source == active) throw StateError('A branch cannot be merged into itself');
    final all = await branches(noteId);
    final other = all.where((b) => b.name == (source == mainBranch ? active : source)).firstOrNull;
    final baseId = other?.base;
    final theirsVersion = await head(noteId, source);
    final baseVersion = baseId == null ? null : await _byId(baseId);
    if (theirsVersion == null || baseVersion == null) throw StateError('The branches have no common version to compare with');
    final theirs = await read(theirsVersion), base = await read(baseVersion);
    final b = NoteDelta.digests(base.note), o = NoteDelta.digests(current), t = NoteDelta.digests(theirs.note);
    final take = <String>{};
    var conflicts = 0;
    for (final key in {...b.keys, ...o.keys, ...t.keys}) {
      if (t[key] == b[key] || o[key] == t[key]) continue; // the branch did not change it, or the note is the same already
      if (o[key] == b[key]) {
        take.add(key); // only the branch changed it
      } else {
        conflicts++; // both did: the note's stays
      }
    }
    final pictures = picturesByPath(theirs);
    final ops = NoteDelta.changesSince(theirs.note, o, readImage: (path) => pictures[path]);
    return BranchMerge([for (final op in ops) if (take.contains(Replica.keyOf(op.kind, op.id))) op], conflicts, theirsVersion);
  }

  /// Notes that the branch [source] was taken in up to [merged]: the next merge begins from there.
  Future<void> completeMerge(String noteId, String source, NoteVersion merged) async {
    final active = await activeBranch(noteId);
    // (the line that is not main keeps the common version)
    final owner = source == mainBranch ? active : source;
    await _db.update('note_branches', {'base': merged.id}, where: 'note_id = ? AND name = ?', whereArgs: [noteId, owner]);
    notifyListeners();
  }

  /// What a note is, as one short text: two notes with the same content have the same one.
  static String fingerprint(NoteData note) {
    final digests = NoteDelta.digests(note);
    final keys = digests.keys.toList()..sort();
    return sha1.convert(utf8.encode(jsonEncode([for (final k in keys) '$k=${digests[k]}', note.pdfSha256 ?? '']))).toString();
  }

  /// Keeps the note as it is now as a version. A version the app makes is not made when the note is the same as in
  /// the newest version (that one is returned); one the person saves ([manual]) always is. Null if there is no such note.
  Future<NoteVersion?> snapshot(String noteId, {VersionReason reason = VersionReason.edit, bool manual = false, String? label, String? who}) async {
    // an encrypted note has no copies of itself lying about (they would be the plain text the encryption is there to keep)
    if (await _notes.locks.lockModeOf(noteId) == 2) return null;
    final note = await _notes.loadNote(noteId);
    if (note == null) return null;
    final print = fingerprint(note);
    final branch = await activeBranch(noteId);
    if (!manual) {
      final last = await _latest(noteId, branch: branch);
      if (last != null && last._fingerprint == print) return last;
    }

    // the pictures, and the PDF, go to the shared folder (once); the version names them by their checksum
    final blobs = await _dir('blobs');
    final images = <String, Uint8List>{};
    final extensions = <String, String>{};
    for (final list in note.images.values) {
      for (final m in list) {
        final bytes = await _read(m.path);
        if (bytes == null) continue;
        images[m.id] = bytes;
        final dot = m.path.lastIndexOf('.');
        extensions[m.id] = dot < 0 ? 'png' : m.path.substring(dot + 1).toLowerCase();
      }
    }
    final hasPdf = note.pdfName != null && note.pdfPath != null;
    final times = await _notes.noteTimes(noteId);
    final entries = noteFileEntries(NoteFileParts(note,
        createdAt: times?.created, updatedAt: times?.edited, pdf: hasPdf ? Uint8List(0) : null, images: images, imageExtensions: extensions));
    final kept = <NoteFileEntry>[];
    final refs = <String, String>{}; // name in the file -> checksum
    for (final e in entries) {
      final (name, bytes, _) = e;
      if (name == 'source.pdf') {
        final pdf = note.pdfSha256 != null && File(p.join(blobs.path, note.pdfSha256!)).existsSync() ? null : await _read(note.pdfPath);
        final sum = note.pdfSha256 ?? (pdf == null ? null : await sha256Of(pdf));
        if (sum == null) continue;
        await _putBlob(blobs, sum, pdf ?? await _read(note.pdfPath));
        refs[name] = sum;
      } else if (name.startsWith('media/')) {
        final sum = await sha256Of(bytes); // (a photograph is megabytes of Dart hashing: not on this isolate when it is big)
        await _putBlob(blobs, sum, bytes);
        refs[name] = sum;
      } else {
        kept.add(e);
      }
    }
    kept.add(('blobs.json', Uint8List.fromList(utf8.encode(jsonEncode(refs))), true));
    final zipped = await runApart(() => zipNoteFile(kept));

    final id = '${_now().microsecondsSinceEpoch.toRadixString(36)}${Random.secure().nextInt(1 << 30).toRadixString(36)}';
    final dir = await _dir(noteId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_'));
    final file = p.join(dir.path, '$id.zip');
    await File(file).writeAsBytes(zipped, flush: true);
    final row = {
      'id': id,
      'note_id': noteId,
      'created_at': _now().millisecondsSinceEpoch,
      'manual': manual ? 1 : 0,
      'label': label,
      'reason': (manual ? VersionReason.manual : reason).name,
      'who': who,
      'branch': branch,
      'fingerprint': print,
      'file': file,
      'blobs': refs.values.toSet().join(','),
      'size': zipped.length,
    };
    await _db.insert('note_versions', row);
    if (!manual) await prune(noteId);
    notifyListeners();
    return NoteVersion._fromRow(row);
  }

  static Future<Uint8List?> _read(String? path) async {
    if (path == null) return null;
    try {
      return await File(path).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  static Future<void> _putBlob(Directory blobs, String sum, Uint8List? bytes) async {
    final f = File(p.join(blobs.path, sum));
    if (bytes == null || f.existsSync()) return;
    final part = File('${f.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(f.path);
  }

  /// The note as it was in [version], with its pictures and PDF (nothing is saved).
  Future<ParsedNoteFile> read(NoteVersion version, {bool withPdf = true}) async {
    final archive = decodeZipLimited(await File(version._file).readAsBytes());
    final refs = archive.find('blobs.json');
    final names = refs == null ? const <String, Object?>{} : (jsonDecode(utf8.decode(refs.content)) as Map).cast<String, Object?>();
    final blobs = await _dir('blobs');
    final entries = <NoteFileEntry>[
      for (final f in archive.files)
        if (f.isFile && f.name != 'blobs.json') (f.name, f.content, false),
    ];
    for (final e in names.entries) {
      if (!withPdf && e.key == 'source.pdf') continue;
      final bytes = await _read(p.join(blobs.path, e.value as String));
      if (bytes != null) entries.add((e.key, bytes, false));
    }
    return decodeNoteFileEntries(entries);
  }

  // ---- blame

  /// What a version is, as far as blame goes (kept for the session, since reading a version takes a while).
  final Map<String, ({Map<String, String> digests, String text})> _digested = {};

  Future<({Map<String, String> digests, String text})> _digestOf(NoteVersion v) async {
    final known = _digested[v.id];
    if (known != null) return known;
    final note = (await read(v, withPdf: false)).note;
    return _digested[v.id] = (digests: NoteDelta.digests(note), text: note.documentText);
  }

  /// The versions that lead to the end of [branch], oldest first: those of the branch, after the part of the branch it began from.
  Future<List<NoteVersion>> chain(String noteId, String branch) async {
    final own = (await list(noteId, branch: branch)).reversed.toList();
    if (branch == mainBranch) return own;
    final row = (await branches(noteId)).where((b) => b.name == branch).firstOrNull;
    final base = row?.base == null ? null : await _byId(row!.base!);
    if (base == null) return own;
    final before = await chain(noteId, base.branch);
    return [for (final v in before) if (!v.at.isAfter(base.at)) v, ...own];
  }

  /// Where each thing of [target] (the note as it is on screen, or as it was in a version) comes from, walking back through the
  /// versions of [branch]: the first version from which the thing looked as it does in [target] ever after. [upTo]: only the
  /// versions up to this one count (the target is that version). [progress] is told how far it is.
  Future<NoteBlame> blame(String noteId, NoteData target, {String? branch, NoteVersion? upTo, void Function(int done, int of)? progress}) async {
    var versions = await chain(noteId, branch ?? await activeBranch(noteId));
    if (upTo != null) {
      final i = versions.indexWhere((v) => v.id == upTo.id);
      if (i >= 0) versions = versions.sublist(0, i + 1);
    }
    final digests = <Map<String, String>>[];
    final texts = <String>[];
    for (final (i, v) in versions.indexed) {
      final d = await _digestOf(v);
      digests.add(d.digests);
      texts.add(d.text);
      progress?.call(i + 1, versions.length);
      await Future<void>.delayed(Duration.zero); // (the screen gets a turn)
    }
    final now = NoteDelta.digests(target);
    final origin = <String, int>{};
    for (final e in now.entries) {
      if (e.key.startsWith('note:')) continue;
      var i = versions.length; // (not in any version)
      while (i > 0 && digests[i - 1][e.key] == e.value) {
        i--;
      }
      // it was the same in the oldest kept version too: it is from before that
      origin[e.key] = i == 0 && versions.isNotEmpty ? -1 : i;
    }
    final (lines, lineOrigin) = blameLines(texts, target.documentText);
    return NoteBlame(versions, origin, lineOrigin, lines);
  }

  /// For each line of [current], the index of the text in [texts] (oldest first) it first appeared in with the lines around it
  /// unchanged (-1: already in the first; [texts].length: in none).
  static (List<String>, List<int>) blameLines(List<String> texts, String current) {
    List<String> split(String t) => t.isEmpty ? <String>[] : t.split('\n');
    var lines = texts.isEmpty ? <String>[] : split(texts.first);
    var from = List<int>.filled(lines.length, -1);
    void step(List<String> next, int index) {
      final matched = matchLines(lines, next);
      from = [for (var j = 0; j < next.length; j++) matched[j] >= 0 ? from[matched[j]] : index];
      lines = next;
    }

    for (var i = 1; i < texts.length; i++) {
      if (texts[i] != texts[i - 1]) step(split(texts[i]), i);
    }
    final last = split(current);
    if (texts.isEmpty) return (last, List<int>.filled(last.length, 0));
    if (current != texts.last) step(last, texts.length);
    return (lines, from);
  }

  /// What would make [current] what it was in [version]: the changes to apply to the note to restore it. Pictures
  /// carry their bytes.
  Future<List<CollabOp>> restoreChanges(NoteVersion version, NoteData current) async {
    final old = await read(version);
    final pictures = picturesByPath(old);
    return NoteDelta.changesSince(old.note, NoteDelta.digests(current), readImage: (path) => pictures[path]);
  }

  /// The bytes of the pictures of a note read from a version, by the path its pictures have there.
  static Map<String, Uint8List> picturesByPath(ParsedNoteFile file) => {
        for (final list in file.note.images.values)
          for (final m in list)
            if (file.images[m.id] case final picture?) m.path: picture.bytes,
      };

  /// Makes [version] one the person keeps, with [label] as its name.
  Future<void> keep(NoteVersion version, String label) async {
    await _db.update('note_versions', {'manual': 1, 'label': label}, where: 'id = ?', whereArgs: [version.id]);
    notifyListeners();
  }

  /// Gives a version the person kept another name.
  Future<void> rename(NoteVersion version, String label) => keep(version, label);

  Future<void> delete(NoteVersion version) async {
    await _db.delete('note_versions', where: 'id = ?', whereArgs: [version.id]);
    await _deleteFile(version._file);
    await _collect();
    notifyListeners();
  }

  /// The most versions the app keeps of a note.
  static const maxAutomatic = 300;

  /// Whether a version the app made at [at] is kept at [now]: all of the last day, one an hour for a week, one a day
  /// for a month. Called newest first; [slots] are the hours and days that have theirs already.
  static bool isKept(DateTime at, DateTime now, Set<String> slots) {
    final age = now.difference(at);
    if (age < const Duration(days: 1)) return true;
    final String slot;
    if (age < const Duration(days: 7)) {
      slot = 'h${at.year}-${at.month}-${at.day}-${at.hour}';
    } else if (age < const Duration(days: 30)) {
      slot = 'd${at.year}-${at.month}-${at.day}';
    } else {
      return false;
    }
    return slots.add(slot); // the first (newest) of its slot
  }

  /// Drops the versions the app made of [noteId] that it does not keep any more (see [maxAutomatic]).
  Future<void> prune(String noteId) async {
    final rows = await _db.query('note_versions', where: 'note_id = ? AND manual = 0', whereArgs: [noteId], orderBy: 'created_at DESC');
    final now = _now();
    // the version a branch began from, and where each branch is, are what merging and switching need: they stay
    final protected = <String>{
      for (final r in await _db.query('note_branches', columns: ['base'], where: 'note_id = ?', whereArgs: [noteId]))
        if (r['base'] != null) r['base'] as String,
    };
    final slotsOf = <String, Set<String>>{};
    final keptOf = <String, int>{};
    final gone = <NoteVersion>[];
    for (final r in rows) {
      final v = NoteVersion._fromRow(r);
      final slots = slotsOf.putIfAbsent(v.branch, () => <String>{});
      final first = !keptOf.containsKey(v.branch); // (the newest of a branch is where it is)
      final kept = keptOf[v.branch] ?? 0;
      if (first || protected.contains(v.id) || (kept < maxAutomatic && isKept(v.at, now, slots))) {
        keptOf[v.branch] = kept + 1;
      } else {
        gone.add(v);
      }
    }
    if (gone.isEmpty) return;
    for (final v in gone) {
      await _db.delete('note_versions', where: 'id = ?', whereArgs: [v.id]);
      await _deleteFile(v._file);
      _digested.remove(v.id);
    }
    await _collect();
  }

  static Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // gone already
    }
  }

  /// Removes the files of the shared folder that no version names any more.
  Future<void> _collect() async {
    final rows = await _db.rawQuery('SELECT blobs FROM note_versions');
    final used = {for (final r in rows) ...((r['blobs'] as String? ?? '').split(',').where((s) => s.isNotEmpty))};
    final blobs = await _dir('blobs');
    await for (final f in blobs.list()) {
      if (f is File && !used.contains(p.basename(f.path))) await _deleteFile(f.path);
    }
  }

  /// Removes the files of versions that are gone (their note was deleted for good, which takes its rows with it).
  Future<void> cleanUp() async {
    try {
      final rows = await _db.rawQuery('SELECT file FROM note_versions');
      final files = {for (final r in rows) p.normalize(r['file'] as String)};
      final root = Directory(p.join((await _support()).path, 'versions'));
      if (!root.existsSync()) return;
      await for (final d in root.list()) {
        if (d is! Directory || p.basename(d.path) == 'blobs') continue;
        await for (final f in d.list()) {
          if (f is File && !files.contains(p.normalize(f.path))) await _deleteFile(f.path);
        }
      }
      await _collect();
    } catch (e) {
      debugPrint('[history] could not clean up: $e');
    }
  }

  /// Puts the pictures of a version that is restored into the app's storage (each under a new name): the saver to
  /// apply [restoreChanges] with.
  Future<ImageSaver> pictureSaver() async {
    final dir = await Directory(p.join((await _support()).path, 'images')).create(recursive: true);
    return (id, bytes, extension) {
      final path = p.join(dir.path, 'restored_${_now().microsecondsSinceEpoch}_${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.$extension');
      File(path).writeAsBytesSync(bytes, flush: true);
      return path;
    };
  }
}
