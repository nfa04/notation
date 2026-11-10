import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart' show debugPrint;

import '../collab/compression.dart';
import '../data/note_file.dart';
import '../util/apart.dart';
import '../collab/secure_box.dart';
import '../data/settings_repository.dart';
import '../devicesync/sync_devices.dart';
import '../devicesync/sync_library.dart';
import '../l10n/language.dart';
import 'cloud_folder.dart';

// These run on another isolate. They are functions of their own, not closures made in a method: a closure carries what its method
// captured - here the whole sync with the library and the database - and that is copied along with the call.
Future<({Uint8List slim, List<NoteBlob> blobs})?> _splitApart(Uint8List bytes) => runApart(() => splitNoteFile(bytes));
Future<Map<String, Uint8List>> _attachmentsApart(Uint8List bytes, Set<int> lengths) => runApart(() => noteAttachmentsByHash(bytes, lengths));
Future<String> _hashApart(Uint8List bytes) => runApart(() => sha256.convert(bytes).toString());
Future<Uint8List> _joinApart(Uint8List slim, Map<String, Uint8List> parts) => runApart(() => joinNoteFile(slim, parts));

/// Another participant of a folder sync: a device of the profile, or (in a shared folder) a device of someone it is shared with.
class SyncPeer {
  final String id, name;
  const SyncPeer(this.id, this.name);
}

/// What a run of [FolderSync] did.
class FolderSyncResult {
  /// Notes, folders and settings taken in (or deleted) here.
  final int taken;

  /// Notes and images put in the folder.
  final int put;

  /// Devices whose state was read.
  final int devices;

  /// What went wrong for some device or file, in words (the rest was done).
  final List<String> problems;

  const FolderSyncResult(this.taken, this.put, this.devices, this.problems);

  bool get ok => problems.isEmpty;
}

/// What another device published: its directory, its manifest and the files the manifest points to.
typedef _Theirs = ({
  String dir,
  bool sealed,
  SyncManifest manifest,
  Map<String, String> notes,
  Map<String, ({String file, String ext})> images,
  Map<String, String> graphs,
  List<PairedDevice> devices,

  /// The big files kept apart from a note file: note -> name in the note file -> where it is, its hash and its length.
  Map<String, Map<String, ({String file, String hash, int length})>> blobs,
});

/// Syncing the library through a folder on cloud storage that all the devices of the profile can reach, for when they are not
/// online at the same time.
///
/// Each device only ever writes to a directory of its own and reads those of the others, so two devices never write the same
/// file. In its directory a device keeps its **manifest** (the same lines as in a sync between two devices: a line for every
/// folder, note, setting and deletion), the **note files** (`n/<id>.<version>`, one per note, named by version so that a manifest
/// always points to files that are complete) and the folder pictures. A run first takes in what the others published - with the
/// same plan as a sync over a direct connection, so conflicts are kept twice, deletions travel, newer replaces older - and then
/// publishes what changed here: new files first, the manifest last, old files after that.
///
/// With [encrypted] every file is sealed with a key from the secret of the profile and the names say nothing: the cloud holds
/// files nobody can read. Without it the files are plain: manifests are JSON and notes are `.uninote` files that can be opened
/// anywhere. A run reads either kind, so changing the choice on one device needs no care on the others.
class FolderSync {
  static const _kPublished = 'cloud_published';
  static const _kPublishedMode = 'cloud_published_mode';
  static const _kPublishedHash = 'cloud_published_hash';
  static const formatVersion = 1;

  /// What a manifest says when notes in it are kept without their big files (see [_splitMin]): a device of an older version refuses it
  /// ("update the app") instead of taking in a note without its PDF.
  static const blobFormatVersion = 2;

  /// A note file of this size or more is put in the folder without its PDF, pictures and sounds (sealed folders only: a plain note file
  /// is one that can be opened anywhere, whole). Those are files of their own, named by what is in them, written once, and read by the
  /// other device only when it does not have them: drawing on a PDF of 20 MB writes the strokes again and not the PDF.
  static const _splitMin = 256 * 1024;

  final CloudFolder folder;
  final SyncLibrary library;
  /// The devices of the profile: who is read from, and (sealed) who is told of. A sync of a shared folder has none, and says who takes
  /// part with [peers].
  final DeviceBook? book;

  /// Who takes part besides this device; without it, the devices of [book] that are on.
  final List<SyncPeer>? peers;

  /// What the settings keys that say what was published start with: one sync of a shared folder must not take another's for its own.
  final String keyPrefix;

  /// Only plain files are read (a shared folder has no key of the profile to seal with, so a sealed directory in it is not from a
  /// participant).
  final bool plainOnly;
  final SettingsRepository settings;

  /// The id of this device, its name, and the key files are sealed with (from the secret of the profile).
  final String deviceId;
  final String deviceName;
  final Uint8List key;
  final bool encrypted;

  /// What went wrong for single files in the run (a note that would not upload, one that would not be taken in): the run goes on
  /// with the rest, since one bad file must not keep every other change from travelling.
  final List<String> _problems = [];

  /// Writes what went wrong with one note, with where in the code, to the console (the message the person sees has no place in it): a
  /// service that said no is no bug and is left out.
  void _trace(String what, Object e, StackTrace s) {
    if (e is CloudFolderException || e is DioException) return;
    debugPrint('cloud sync, $what: $e\n$s');
  }

  String _why(Object e) => '$e'.replaceFirst('Bad state: ', '');

  /// Which folder this is (the service and the name), to tell when the files are to be put somewhere else: nothing that was published
  /// to another place counts as published here.
  final String place;

  /// How many files are read or written at the same time. A sync is many small requests, and each waits for the round trip to the
  /// service: one after the other, a hundred notes take a hundred round trips; four at a time, a quarter of that.
  final int parallel;

  FolderSync({
    required this.folder,
    required this.library,
    this.book,
    this.peers,
    this.keyPrefix = '',
    this.plainOnly = false,
    required this.settings,
    required this.deviceId,
    required this.deviceName,
    required this.key,
    required this.encrypted,
    this.place = '',
    this.parallel = 4,
    this.devicesByNewest = true,
  }) : assert(book != null || peers != null, 'who takes part?');

  /// Whether the device whose newest note is the newest is taken in first (the notes within a device always are).
  final bool devicesByNewest;

  List<SyncPeer> get _others => [
        for (final d in (peers ?? [for (final d in book!.active) SyncPeer(d.id, d.name)]))
          if (d.id != deviceId) d,
      ];

  // ---- names

  String _mac(String what) => Hmac(sha256, key).convert(utf8.encode(what)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// The directory of a device.
  String dirOf(String id, {bool? encrypted}) => directory(key, id, encrypted ?? this.encrypted);

  /// The directory of the device [id] for the kind of files and the key of the profile.
  static String directory(Uint8List key, String id, bool encrypted) =>
      encrypted ? 'x${Hmac(sha256, key).convert(utf8.encode('dir:$id')).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, 20)}' : 'd-${_safe(id)}';

  String _manifestName(bool encrypted) => encrypted ? 'm' : 'manifest.json';

  String _noteName(String id, int version) => encrypted ? 'n/${_mac('note:$id:$version').substring(0, 24)}' : 'n/${_safe(id)}.$version.uninote';

  /// The file of a graph: its picture as JSON (sealed, compressed first, like the manifest), named by the graph and the time it was made.
  String _graphName(String uid, int at) => encrypted
      ? 'g/${_mac('graph:$uid:$at').substring(0, 24)}'
      : 'g/${_safe(uid)}.$at.json';

  String _imageName(String id, int at, String ext) => encrypted ? 'f/${_mac('image:$id:$at').substring(0, 24)}' : 'f/${_safe(id)}.$at.${_safe(ext)}';

  // ---- sealing

  /// What a sealed file is tied to: the place it is stored at. Whoever runs the storage cannot then put one sealed file where another
  /// belongs (a note's file under another note's name) and have it taken for the right one.
  static List<int> _placeOf(String path) => utf8.encode('notation-cloud-file-v1|$path');

  Future<Uint8List> _wrap(Uint8List plain, String path) => encrypted ? sealApart(key, plain, aad: _placeOf(path)) : Future.value(plain);

  // ---- doing several things at once

  /// Runs [job] for the [items] with at most [parallel] at a time. The results are in the order of the items; an item that was not
  /// started because [stop] said so has none (null). An error of one job is its result, not the end of the others.
  Future<List<({R? value, Object? error})?>> _pool<T, R>(List<T> items, Future<R> Function(T item) job, {bool Function()? stop}) async {
    final out = List<({R? value, Object? error})?>.filled(items.length, null);
    var next = 0, halted = false;
    Future<void> worker() async {
      while (next < items.length && !halted && !(stop?.call() ?? false)) {
        final i = next++;
        try {
          out[i] = (value: await job(items[i]), error: null);
        } catch (e) {
          out[i] = (value: null, error: e);
          if (e is CloudAccountMissing) halted = true; // (the others would fail the same way)
        }
      }
    }

    await Future.wait([for (var w = 0; w < min(parallel, items.length); w++) worker()]);
    return out;
  }

  /// Starts [job] for the [items] up to [parallel] ahead of the one that is being used, and hands the results over one by one in the
  /// order of the items (so the things that are done with them - they change the library, one at a time - keep their order, while the
  /// waiting for the service overlaps). Only [parallel] results are ever held at once.
  Stream<({T item, R? value, Object? error})> _ahead<T, R>(List<T> items, Future<R> Function(T item) job) async* {
    final started = <Future<({R? value, Object? error})>>[];
    for (var i = 0; i < items.length; i++) {
      while (started.length < items.length && started.length < i + parallel) {
        final item = items[started.length];
        started.add(Future.sync(() => job(item)).then((v) => (value: v, error: null), onError: (Object e) => (value: null, error: e)));
      }
      final done = await started[i];
      started[i] = Future.value((value: null, error: null)); // (let go of the bytes)
      yield (item: items[i], value: done.value, error: done.error);
    }
  }


  /// The file as it was meant: from the directory of a device that seals ([sealed]) it must open with the key of the profile - one
  /// that does not was not written by a device of the profile (anyone who reaches the folder can put files there) and is refused;
  /// from a plain directory it is taken as it is.
  Future<Uint8List> _unwrap(Uint8List bytes, String path, {required bool sealed}) async {
    if (!sealed) return bytes;
    try {
      return await openApart(key, bytes, aad: _placeOf(path));
    } catch (_) {
      // (files written before they were tied to their place open without; the next time they are written they are tied)
    }
    try {
      return await openApart(key, bytes);
    } catch (_) {
      throw StateError(tr('A file in the folder is not sealed with the key of this profile; it was not taken.'));
    }
  }

  // ---- a run

  /// Whether the last [run] left nothing for later: no file that was not up there yet (so that what [run] was told was unchanged can
  /// be taken as read).
  bool get complete => !_incomplete;
  bool _incomplete = false;

  /// Takes in what the other devices published, then publishes what changed here (unless [publish] is false: someone who may only
  /// read). [stop] is asked between files. The devices in [unchanged] are known to have published nothing since the last time they
  /// were read in full (the service said so by the stamp of their directory): their manifests are not read again.
  Future<FolderSyncResult> run({bool Function()? stop, bool publish = true,
    Set<String>? unchanged,}) async {
    final problems = <String>[];
    _problems.clear();
    _incomplete = false;
    var taken = 0, devices = 0;
    // The manifests come first (one small file for each device), so that the device with the newest work is taken in first: what was
    // changed last is what the person most likely wants to go on with.
    final others = [
    for (final d in _others)
        if (!(unchanged?.contains(d.id) ?? false)) d,
    ];
    final read = <String, _Theirs?>{};
    final unreadable = <String, Object>{};
    for (final d in others) {
      try {
        read[d.id] = await _readManifest(d.id);
      } catch (e) {
        unreadable[d.id] = e;
      }
    }
    int newest(String id) =>
        read[id]?.manifest.notes.fold<int>(
          0,
          (m, n) => n.deletedAt == null && n.version > m ? n.version : m,
        ) ??
        0;
    // (a stable sort: devices with nothing keep their order. A shared folder keeps the order it was given: what a device published may
    // build on what another one did - a note in a folder - and that one has to be taken in first)
    final order = devicesByNewest
        ? ([...others]..sort((x, y) => newest(y.id).compareTo(newest(x.id))))
        : others;
    for (final d in order) {
      if (stop?.call() ?? false) break;
      try {
        if (unreadable[d.id] case final Object e) throw e;
        if (!read.containsKey(d.id)) continue;
        final n = await _pull(d.id, stop, read[d.id]);
        if (n != null) {
          devices++;
          taken += n;
        }
      } catch (e) {
        problems.add('${d.name}: ${'$e'.replaceFirst('Bad state: ', '')}');
      }
    }
    var put = 0;
    if (publish && !(stop?.call() ?? false)) {
      try {
        put = await _publish(stop);
      } catch (e) {
        problems.add('$e'.replaceFirst('Bad state: ', ''));
      }
    }
    problems.addAll(_problems);
    return FolderSyncResult(taken, put, devices, problems);
  }

  // ---- big files of notes

  String _blobName(String hash) => 'b/${_mac('blob:$hash').substring(0, 32)}';

  /// The note file [slim] of [noteId] with the big files it was published without put back in; null when one of them is not up there
  /// yet (the next run). A file this device has already - in its own copy of the note - is not fetched: after a stroke on a PDF only the
  /// strokes come over.
  Future<Uint8List?> _assemble(_Theirs theirs, String noteId, Uint8List slim) async {
    final refs = theirs.blobs[noteId];
    if (refs == null || refs.isEmpty) return slim;
    final parts = <String, Uint8List>{};
    final here = await library.noteInfo(noteId) == null ? null : await library.files.exportBytes(noteId);
    final lengths = {for (final r in refs.values) r.length};
    final Map<String, Uint8List> mine = here == null ? const {} : await _attachmentsApart(here, lengths);
    for (final e in refs.entries) {
      final ref = e.value;
      var bytes = mine[ref.hash];
      if (bytes == null) {
        final raw = await folder.read('${theirs.dir}/${ref.file}');
        if (raw == null) return null;
        bytes = await _unwrap(raw, '${theirs.dir}/${ref.file}', sealed: theirs.sealed);
        final got = bytes;
        if (got.length != ref.length || await _hashApart(got) != ref.hash) {
          throw StateError(tr('A file in the folder is not sealed with the key of this profile; it was not taken.'));
        }
      }
      parts[e.key] = bytes;
    }
    return _joinApart(slim, parts);
  }

  // ---- taking

  /// Looks whether another device published a newer copy of the note [noteId] and takes it in if so (only that note, and only if
  /// [allow] says yes at the moment it would be written, as the person may have started to change the note meanwhile). Reads one small
  /// file for each other device, and the note's file only when it is newer. True if the note was replaced.
  Future<bool> pullNote(String noteId, {bool Function()? allow,
    Set<String>? unchanged,}) async {
    for (final d in _others) {
      if (unchanged?.contains(d.id) ?? false) continue;
      final theirs = await _readManifest(d.id);
      if (theirs == null) continue;
      final info = theirs.manifest.notes.where((n) => n.id == noteId).firstOrNull;
      if (info == null) continue;
      final taken = await library.forcing(noteId, () async {
        final want = (await library.plan(d.id, deviceId, theirs.manifest)).notes[noteId];
        if (want == null || !want.data) return false; // not newer
        final file = theirs.notes[noteId];
        final raw = file == null ? null : await folder.read('${theirs.dir}/$file');
        if (raw == null) return false;
        final slim = await _unwrap(raw, '${theirs.dir}/$file', sealed: theirs.sealed);
        final bytes = await _assemble(theirs, noteId, slim);
        if (bytes == null || !(allow?.call() ?? true)) return false;
        await library.applyNote(d.id, info, bytes, data: true, meta: want.meta);
        return true;
      });
      if (taken) return true;
    }
    return false;
  }

  Future<_Theirs?> _readManifest(String id) async {
    for (final enc in plainOnly ? [false] : [encrypted, !encrypted]) {
      final dir = dirOf(id, encrypted: enc);
      final raw = await folder.read('$dir/${_manifestName(enc)}');
      if (raw == null) continue;
      final Map<String, Object?> json;
      try {
        json = (jsonDecode(utf8.decode(await unpackMessage(await _unwrap(raw, '$dir/${_manifestName(enc)}', sealed: enc,)))) as Map).cast<String, Object?>();
      } catch (_) {
        throw StateError(tr('The manifest of the device {dir} cannot be read (is it from another profile?).', {'dir': dir}));
      }
      if (json['v'] != formatVersion && json['v'] != blobFormatVersion) throw StateError(tr('The other device writes a newer kind of sync files: update the app.'));
      return (
        dir: dir,
        sealed: enc,
        manifest: SyncManifest.fromJson(json['m'] as Map),
        notes: {for (final e in (json['notes'] as Map? ?? const {}).entries) e.key as String: e.value as String},
        graphs: {
          for (final e in (json['graphs'] as Map? ?? const {}).entries)
            e.key as String: e.value as String,
        },
        blobs: {
          for (final e in (json['blobs'] as Map? ?? const {}).entries)
            e.key as String: {
              for (final b in (e.value as Map).entries)
                b.key as String: (file: (b.value as Map)['f'] as String, hash: (b.value as Map)['h'] as String, length: (b.value as Map)['n'] as int),
            },
        },
        images: {for (final e in (json['images'] as Map? ?? const {}).entries) e.key as String: (file: (e.value as Map)['f'] as String, ext: (e.value as Map)['e'] as String? ?? 'png')},
        // the list of devices counts only from the manifest of the device itself, and only when the files are sealed with the key of
        // the profile (plain files can be written by anyone who reaches the folder)
        devices: enc && json['device'] == id ? <PairedDevice>[for (final j in (json['devices'] as List? ?? const [])) ?PairedDevice.fromJson(j)] : const <PairedDevice>[],
      );
    }
    return null;
  }

  /// The list of devices the device [id] published in its manifest (sealed with the key of the profile); null when it published nothing.
  Future<List<PairedDevice>?> deviceListOf(String id) async {
    final theirs = await _readManifest(id);
    return theirs?.devices;
  }

  String _titleOf(SyncNote n) => n.id;

  /// Takes in what [peer] published; null if it published nothing (yet).
  Future<int?> _pull(String peer, bool Function()? stop,
    _Theirs? theirs,) async {
    if (theirs == null) return null;
    // a device that was added through another device is known here from the list of the device that published this manifest (devices
    // that sync through the folder never meet directly, so they could not tell each other otherwise)
    if (theirs.devices.isNotEmpty) await book?.merge(theirs.devices);
    final plan = await library.plan(peer, deviceId, theirs.manifest);
    var taken = 0;
    for (final id in plan.deleteNotes) {
      await library.deleteNote(id, at: plan.deletedAt['note:$id']);
      taken++;
    }
    for (final id in plan.deleteFolders) {
      await library.deleteFolder(id, at: plan.deletedAt['folder:$id']);
      taken++;
    }
    for (final id in plan.deleteGraphs) {
      await library.deleteGraph(id, at: plan.deletedAt['graph:$id']!);
      taken++;
    }
    // folders: parents first
    final wanted = [for (final f in theirs.manifest.folders) if (plan.folders.contains(f.id)) f];
    final byId = {for (final f in theirs.manifest.folders) f.id: f};
    int depth(SyncFolder f) {
      var d = 0;
      // (the count only stops a folder that is its own ancestor from looping: a chain may be as deep as the folders are many - a cap of
      // 100 put a folder before its parent, which then was not there to be put under)
      for (var p = f.parentId; p != null && byId[p] != null && d < byId.length; p = byId[p]!.parentId) {
        d++;
      }
      return d;
    }

    wanted.sort((a, b) => depth(a).compareTo(depth(b)));
    final dir = theirs.dir;
    for (final f in wanted) {
      ({String ext, Uint8List bytes})? image;
      final entry = theirs.images[f.id];
      if (entry != null) {
        final raw = await folder.read('$dir/${entry.file}');
        if (raw != null) image = (ext: entry.ext, bytes: await _unwrap(raw, '$dir/${entry.file}', sealed: theirs.sealed));
      }
      await library.applyFolder(f, image: image);
      taken++;
    }
    // graphs: their pictures are small beside notes, and each is one file
    final graphInfo = {for (final g in theirs.manifest.graphs) g.uid: g};
    for (final id in plan.graphs) {
      if (stop?.call() ?? false) return taken;
      final info = graphInfo[id], file = theirs.graphs[id];
      if (info == null) continue;
      try {
        final raw = file == null ? null : await folder.read('$dir/$file');
        if (raw == null) {
          _incomplete = true; // not up there (yet): the next run
          continue;
        }
        final plain = await _unwrap(raw, '$dir/$file', sealed: theirs.sealed);
        await library.applyGraph(
          info,
          utf8.decode(theirs.sealed ? await unpackMessage(plain) : plain),
        );
        taken++;
      } catch (err, st) {
        if (err is CloudAccountMissing) rethrow;
        _trace('taking in the graph $id', err, st);
        _problems.add('${info.name}: ${_why(err)}');
      }
    }
    final notes = {for (final n in theirs.manifest.notes) n.id: n};
    // the newest first (what is in the trash last): somebody who just signed in can open and write in the latest notes while the
    // older ones are still coming in; the sort is stable, so notes of the same time keep their order
    final wantedNotes = [for (final e in plan.notes.entries) if (notes[e.key] != null) e]..sort((x, y) {
          final a = notes[x.key]!, b = notes[y.key]!;
          if ((a.deletedAt != null) != (b.deletedAt != null)) return a.deletedAt != null ? 1 : -1;
          return b.version.compareTo(a.version);
        });
    // the files are fetched (and opened) a few at a time ahead of the one that is being taken in; taking them in is one by one
    final fetched = _ahead(wantedNotes, (e) async {
      if (!e.value.data) return (bytes: null, missing: false);
      final file = theirs.notes[e.key];
      final raw = file == null ? null : await folder.read('$dir/$file');
      if (raw == null) return (bytes: null, missing: true); // not up there (yet): the next run
      final whole = await _assemble(theirs, e.key, await _unwrap(raw, '$dir/$file', sealed: theirs.sealed));
      return whole == null ? (bytes: null, missing: true) : (bytes: whole, missing: false);
    });
    await for (final f in fetched) {
      if (stop?.call() ?? false) return taken;
      final e = f.item;
      final info = notes[e.key]!;
      if (f.error is CloudAccountMissing) throw f.error!; // (the run of this device ends here, with one message)
      try {
        if (f.error != null) throw f.error!;
        final got = f.value!;
        if (got.missing) {
          _incomplete = true; continue;
        }
        await library.applyNote(peer, info, got.bytes, data: e.value.data, meta: e.value.meta);
        taken++;
      } catch (err, st) {
        _trace('taking in ${info.id}', err, st);
        _problems.add('${_titleOf(info)}: ${_why(err)}'); // (the other notes are still taken in)
      }
    }
    for (final s in theirs.manifest.settings) {
      if (plan.settings.contains(s.key)) {
        await library.applySetting(s);
        taken++;
      }
    }
    await library.markAgreed(peer, theirs.manifest);
    return taken;
  }

  // ---- publishing

  Future<Map<String, Map<String, Object?>>> _readPublished() async {
    try {
      final text = await settings.get('$keyPrefix$_kPublished');
      if (text == null) return {};
      return {for (final e in (jsonDecode(text) as Map).entries) e.key as String: (e.value as Map).cast<String, Object?>()};
    } catch (_) {
      return {};
    }
  }

  /// Puts what changed here in the folder. Returns how many files were written.
  Future<int> _publish(bool Function()? stop) async {
    final mode = encrypted ? 'enc' : 'plain';
    final where = '$mode@$place';
    var published = await _readPublished();
    final was = await settings.get('$keyPrefix$_kPublishedMode');
    if (was != where) {
      // the kind of files changed, or the folder: everything is written again (and the old kind is taken away below)
      if (was?.split('@').first != mode) await _removeAll(oldMode: !encrypted);
      published = {};
      await settings.set('$keyPrefix$_kPublishedHash', ''); // (the manifest is written whatever it says)
    }
    final manifest = await library.manifest();
    final dir = dirOf(deviceId);
    var put = 0;

    final noteFiles = <String, String>{};
    // the big files kept apart from the note files: note -> name in the note file -> {f: file, h: hash, n: length}
    final blobRefs = <String, Map<String, Map<String, Object?>>>{};
    // what is up there already (a file is written once, whichever notes hold it), and what is being written now
    final blobWrites = <String, Future<void>>{
      for (final k in published.keys)
        if (k.startsWith('b:')) k.substring(2): Future<void>.value(),
    };
    final failed = <String>{};
    final nextPublished = <String, Map<String, Object?>>{};
    final toWrite = <SyncNote>[];
    for (final n in manifest.notes) {
      final have = published['n:${n.id}'];
      if (have != null && have['v'] == n.version && have['f'] is String) {
        noteFiles[n.id] = have['f'] as String;
        nextPublished['n:${n.id}'] = have;
        if (have['b'] is Map) {
          blobRefs[n.id] = {
            for (final e in (have['b'] as Map).entries) e.key as String: (e.value as Map).cast<String, Object?>(),
          };
        }
      } else {
        toWrite.add(n);
      }
    }
    // (the first goes on its own: it makes the directories, which several uploads at once could each try to do)
    Future<String?> upload(SyncNote n) async {
      try {
      final bytes = await library.noteBytes(n.id);
      if (bytes == null) return null; // locked or gone meanwhile
      var body = bytes;
      if (encrypted && !plainOnly && bytes.length >= _splitMin) {
        final split = await _splitApart(bytes);
        if (split != null) {
          final refs = <String, Map<String, Object?>>{};
          for (final b in split.blobs) {
            final file = _blobName(b.hash);
            refs[b.name] = {'f': file, 'h': b.hash, 'n': b.bytes.length};
            await blobWrites.putIfAbsent(file, () async => folder.write('$dir/$file', await _wrap(b.bytes, '$dir/$file')));
          }
          blobRefs[n.id] = refs;
          body = split.slim;
        } else {
          blobRefs.remove(n.id);
        }
      }
      final name = _noteName(n.id, n.version);
      await folder.write('$dir/$name', await _wrap(body, '$dir/$name'));
      return name;
    } catch (e, s) {
        _trace('publishing ${n.id}', e, s);
        rethrow;
      }
    }

    final results = [
      ...await _pool(toWrite.take(1).toList(), upload, stop: stop),
      ...await _pool(toWrite.skip(1).toList(), upload, stop: stop),
    ];
    for (final r in results) {
      if (r?.error is CloudAccountMissing) throw r!.error!; // (one message, not one for every note)
    }
    if (stop?.call() ?? false) return put + results.where((r) => r?.value != null).length;
    for (var i = 0; i < toWrite.length; i++) {
      final n = toWrite[i], r = results[i];
      if (r == null) continue;
      if (r.error != null) {
        // this note stays out of the manifest for now (the others are not held back by it) and is tried again next run
        failed.add(n.id);
        _problems.add('${n.id}: ${_why(r.error!)}');
      } else if (r.value != null) {
        put++;
        noteFiles[n.id] = r.value!;
        nextPublished['n:${n.id}'] = {'v': n.version, 'f': r.value, if (blobRefs[n.id] != null) 'b': blobRefs[n.id]};
      }
    }
    // the graphs: one file each, written again when the graph was made again or renamed
    final graphFiles = <String, String>{};
    final failedGraphs = <String>{};
    for (final g in manifest.graphs) {
      if (stop?.call() ?? false) break;
      final have = published['g:${g.uid}'];
      if (have != null && have['v'] == g.at && have['f'] is String) {
        graphFiles[g.uid] = have['f'] as String;
        nextPublished['g:${g.uid}'] = have;
        continue;
      }
      try {
        final got = await library.graphFor(g.uid);
        if (got == null) {
          failedGraphs.add(g.uid); // (gone meanwhile)
          continue;
        }
        final name = _graphName(g.uid, g.at);
        final bytes = Uint8List.fromList(utf8.encode(got.payload));
        await folder.write(
          '$dir/$name',
          await _wrap(
            encrypted ? await packMessage(bytes) : bytes,
            '$dir/$name',
          ),
        );
        put++;
        graphFiles[g.uid] = name;
        nextPublished['g:${g.uid}'] = {'v': g.at, 'f': name};
      } catch (e, st) {
        if (e is CloudAccountMissing) rethrow;
        _trace('publishing the graph ${g.uid}', e, st);
        failedGraphs.add(g.uid);
        _problems.add('${g.name}: ${_why(e)}');
      }
    }
    final images = <String, ({String file, String ext})>{};
    for (final f in manifest.folders) {
      final have = published['i:${f.id}'];
      if (have != null && have['v'] == f.updatedAt) {
        if (have['f'] is String) images[f.id] = (file: have['f'] as String, ext: have['e'] as String? ?? 'png');
        nextPublished['i:${f.id}'] = have;
        continue;
      }
      try {
        final image = await library.folderImage(f.id);
        if (image == null) {
          nextPublished['i:${f.id}'] = {'v': f.updatedAt};
          continue;
        }
        final name = _imageName(f.id, f.updatedAt, image.ext);
        await folder.write('$dir/$name', await _wrap(image.bytes, '$dir/$name'));
        put++;
        images[f.id] = (file: name, ext: image.ext);
        nextPublished['i:${f.id}'] = {'v': f.updatedAt, 'f': name, 'e': image.ext};
      } catch (e) {
        if (e is CloudAccountMissing) rethrow;
        _problems.add('${f.name}: ${_why(e)}');
      }
    }

    // the manifest comes last: what it points to is all there
    blobRefs.removeWhere((id, _) => !noteFiles.containsKey(id)); // (a note that is not in the manifest keeps nothing up there)
    for (final refs in blobRefs.values) {
      for (final ref in refs.values) {
        nextPublished['b:${ref['f']}'] = const {};
      }
    }
    final body = <String, Object?>{
      'v': blobRefs.isEmpty ? formatVersion : blobFormatVersion,
      'device': deviceId,
      'name': deviceName,
      if (encrypted && book != null) 'devices': [for (final d in book!.all) d.toJson()],
      'm': (failed.isEmpty && failedGraphs.isEmpty ? manifest : SyncManifest(manifest.folders, [for (final n in manifest.notes) if (!failed.contains(n.id)) n], manifest.settings, manifest.tombs,
                      graphs: [
                        for (final g in manifest.graphs)
                          if (!failedGraphs.contains(g.uid)) g,
                      ],)).toJson(),
      'notes': noteFiles,
      if (graphFiles.isNotEmpty) 'graphs': graphFiles,
      if (blobRefs.isNotEmpty) 'blobs': blobRefs,
      'images': {for (final e in images.entries) e.key: {'f': e.value.file, 'e': e.value.ext}},
    };
    final text = jsonEncode(body);
    final hash = sha256.convert(utf8.encode(text)).toString();
    if (put > 0 || await settings.get('$keyPrefix$_kPublishedHash') != hash) {
      // (sealed, it is compressed first, as a sealed file cannot be; a plain one stays JSON that can be read anywhere)
      final bytes = Uint8List.fromList(utf8.encode(text));
      await folder.write('$dir/${_manifestName(encrypted)}', await _wrap(encrypted ? await packMessage(bytes) : bytes, '$dir/${_manifestName(encrypted)}'));
      put++;
    }
    await settings.set('$keyPrefix$_kPublished', jsonEncode(nextPublished));
    await settings.set('$keyPrefix$_kPublishedMode', where);
    await settings.set('$keyPrefix$_kPublishedHash', hash);

    // files no manifest points to any more (older versions, deleted notes). Only looked for when something was written: the folder is
    // listed then, and an idle run - most of them - asks for nothing but the manifests of the others.
    if (put > 0) {
      final keep = {...noteFiles.values, ...graphFiles.values,
        ...images.values.map((i) => i.file),
        for (final refs in blobRefs.values) for (final ref in refs.values) ref['f'] as String,};
      final listed = await Future.wait([for (final sub in ['n', 'f', 'g', 'b']) folder.list('$dir/$sub').then((names) => [for (final name in names) '$sub/$name'])]);
      final stale = [for (final names in listed) for (final name in names) if (!keep.contains(name)) name];
      final deleted = await _pool(stale, (name) => folder.delete('$dir/$name'));
      for (final d in deleted) {
        if (d?.error != null) _problems.add(_why(d!.error!)); // (a file that stays is taken away by the next run)
      }
    }
    return put;
  }

  /// Removes what this device published in the kind of files that is not used any more.
  Future<void> _removeAll({required bool oldMode}) async {
    final dir = dirOf(deviceId, encrypted: oldMode);
    await folder.delete('$dir/${_manifestName(oldMode)}');
    final listed = await Future.wait([for (final sub in ['n', 'f', 'g', 'b']) folder.list('$dir/$sub').then((names) => [for (final name in names) '$sub/$name'])]);
    final results = await _pool([for (final names in listed) ...names], (name) => folder.delete('$dir/$name'));
    for (final r in results) {
      if (r?.error != null) throw r!.error!;
    }
  }
}
