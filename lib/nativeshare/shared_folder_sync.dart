import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../cloudsync/caching_folder.dart';
import '../cloudsync/cloud_folder.dart';
import '../cloudsync/folder_sync.dart';
import '../data/settings_repository.dart';
import '../devicesync/sync_library.dart';
import 'native_share_provider.dart';
import 'scoped_library.dart';
import 'share_live.dart' show ParticipantRecord;
import 'share_model.dart';
import 'share_scope.dart';

/// What is at the top of a shared folder: that it is a share of Notation, and what it is about. Whoever receives the share reads it
/// before anything else, and takes nothing from a folder that does not have one.
class ShareDescriptor {
  static const fileName = 'share.json';
  static const formatVersion = 1;

  final ShareKind kind;

  /// The id of the shared note, or of the shared folder, in the library of the owner.
  final String rootId;
  final String name;

  /// The secret of the share for working on a note live (see `ShareLive`), base64: with it a device finds the room of the share. It is
  /// in the folder, like the files, so the service can read it as it can read them; who may take part is decided by the proof of the
  /// device (see there), not by this.
  final String? live;

  const ShareDescriptor(this.kind, this.rootId, this.name, {this.live});

  ShareDescriptor withLive(String secret) => ShareDescriptor(kind, rootId, name, live: secret);

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({'v': formatVersion, 'kind': kind.name, 'root': rootId, 'name': name, if (live != null) 'live': live})));

  static String? _secret(Object? text) {
    if (text is! String) return null;
    try {
      return base64.decode(text).length == 32 ? text : null;
    } catch (_) {
      return null;
    }
  }

  /// Null when [bytes] is not a descriptor this version can use.
  static ShareDescriptor? decode(Uint8List? bytes) {
    if (bytes == null || bytes.length > 4096) return null;
    try {
      final j = jsonDecode(utf8.decode(bytes)) as Map;
      final kind = ShareKind.values.where((k) => k.name == j['kind']).firstOrNull;
      final root = j['root'];
      final name = j['name'];
      if (j['v'] != formatVersion || kind == null || root is! String || !_id.hasMatch(root) || name is! String) return null;
      return ShareDescriptor(kind, root, name.length > 200 ? name.substring(0, 200) : name, live: _secret(j['live']));
    } catch (_) {
      return null;
    }
  }
}

/// What one run of a share did.
class SharedRunResult {
  final FolderSyncResult sync;

  /// The people it was shared with deleted the shared note or folder: the share is over, and what is here stays.
  final bool ended;

  /// Nothing was done: the service said that nothing changed in the shared folder since this device last looked (one request).
  final bool skipped;

  const SharedRunResult(this.sync, {this.ended = false, this.skipped = false});
}

/// What a run that went well saw, so that the next one can tell what did not change (see `SharedFolderSync.run`).
class _Seen {
  /// The stamp of the whole shared folder, when this device left it as it found it (it wrote nothing); null otherwise.
  final String? root;

  /// The stamp of the directory with the participants' files, and who was in it then.
  final String? participants;
  final List<ParticipantRecord> peers;

  /// The stamp of each participant's directory when it was read ('-': there was none).
  final Map<String, String> dirs;

  /// When every participant was last read in full: a full look is made now and then whatever the stamps say.
  final int at;

  const _Seen(this.root, this.participants, this.peers, this.dirs, this.at);

  String toJson() => jsonEncode({
    'root': root,
    'p': participants,
    'dirs': dirs,
    'at': at,
    'peers': [
      for (final r in peers)
        {
          'id': r.id,
          'name': r.name,
          if (r.key != null) 'k': base64.encode(r.key!),
        },
    ],
  });

  static _Seen? fromJson(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final j = jsonDecode(text) as Map;
      return _Seen(
        j['root'] as String?,
        j['p'] as String?,
        [
          for (final e in (j['peers'] as List))
            ParticipantRecord(
              (e as Map)['id'] as String,
              e['name'] as String,
              ParticipantRecord.keyOf(e['k']),
            ),
        ],
        {
          for (final e in (j['dirs'] as Map).entries)
            e.key as String: e.value as String,
        },
        j['at'] as int,
      );
    } catch (_) {
      return null;
    }
  }
}

/// One run of one share: says who takes part, then runs the sync of a cloud folder (`FolderSync`) on the part of the library that the
/// share is about (`ScopedSyncLibrary`). The shared folder holds, besides the share's descriptor:
///
///     p/<device>                one small file for each device that publishes: its id and name
///     d-<device>/...            what that device has (manifest, notes, folder pictures), written only by it
///
/// A device that may only read does not write at all.
class SharedFolderSync {
  static const participantsDir = 'p';
  static const maxParticipants = 50;

  final NativeShare share;
  final NativeShareProvider provider;
  final SyncLibrary library;
  final Database db;
  final SettingsRepository settings;
  final String deviceId, deviceName;

  /// The public key of this device, told to the others in the participants' file (what a live session checks the proof against).
  final Uint8List? deviceKey;
  final List<Duration> retryDelays;

  /// How long what a run saw counts: after this, a quick run reads everything again (a safety net for a service whose stamps do not
  /// follow what is below a directory, and for what changed here without being noticed).
  final Duration maxAge;

  const SharedFolderSync({
    this.cache,
    required this.share,
    required this.provider,
    required this.library,
    required this.db,
    required this.settings,
    required this.deviceId,
    required this.deviceName,
    this.deviceKey,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 4), Duration(seconds: 10)],
    this.maxAge = const Duration(minutes: 10),
  });

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// What was read of the folder before, kept from run to run (see [CachingFolder]); null: everything is read each time.
  final CachingFolder? cache;

  CloudFolder get _folder {
    final folder = RetryingFolder(provider.folderAt(share.place), delays: retryDelays);
    final kept = cache;
    return kept == null ? folder : (kept..inner = folder);
  }

  String get _payload =>jsonEncode({'id': deviceId, 'name': deviceName, if (deviceKey != null) 'k': base64.encode(deviceKey!)});

  String get _kAnnounced => 'share_${share.id}_announced';
  String get _kSeen => 'share_${share.id}_seen';

  /// Says that this device takes part (when it may write).
  Future<void> announce([CloudFolder? folder]) async {
    if (!share.writes) return;
    final payload = _payload;
    await (folder ?? _folder).write(
      '$participantsDir/${_safe(deviceId)}',
      Uint8List.fromList(utf8.encode(payload)),
    );
    await settings.set(_kAnnounced, '${provider.id}/${share.place}:$payload');
  }

  /// Says that this device takes part unless it did so already, in the same words and in this folder, and the file is still there
  /// ([names] are the participants' files). True when it wrote.
  Future<bool> _announceIfNeeded(CloudFolder folder, List<String> names) async {
    if (!share.writes) return false;
    if (names.contains(_safe(deviceId)) &&
        await settings.get(_kAnnounced) ==
            '${provider.id}/${share.place}:$_payload') {
      return false;
    }
    await announce(folder);
    return true;
  }

  /// The devices that wrote their file in the shared folder - those who may write - from what they wrote, this device left out.
  Future<List<ParticipantRecord>> readParticipants([CloudFolder? folder,
    List<String>? names,]) async {
    final f = folder ?? _folder;
    final out = <ParticipantRecord>[];
    for (final file in names ?? await f.list(participantsDir)) {
      if (out.length >= maxParticipants) break;
      try {
        final raw = await f.read('$participantsDir/$file');
        if (raw == null || raw.length > 2048) continue;
        final j = jsonDecode(utf8.decode(raw)) as Map;
        final id = j['id'];
        // (the name of the file has to say whose it is: one device cannot write as another)
        if (id is! String || id.isEmpty || id.length > 80 || _safe(id) != file || id == deviceId) continue;
        final name = j['name'] is String ? (j['name'] as String).trim() : '';
        out.add(ParticipantRecord(id, name.isEmpty ? id : (name.length > 60 ? name.substring(0, 60) : name), ParticipantRecord.keyOf(j['k'])));
      } catch (_) {
        // not a participant's file
      }
    }
    return out;
  }

  /// Says that this device takes part, and who else does.
  Future<List<SyncPeer>> _participants(CloudFolder folder) async {
    await announce(folder);
    return [for (final r in await readParticipants(folder)) SyncPeer(r.id, r.name)];
  }

  ShareScope _scope() => ShareScope(db, shareId: share.id, kind: share.kind, rootId: share.rootId);

  FolderSync _sync(CloudFolder folder, ScopedSyncLibrary scoped, List<SyncPeer> peers) => FolderSync(
        folder: folder,
        library: scoped,
        peers: peers,
        keyPrefix: 'share_${share.id}_',
        plainOnly: true,
    devicesByNewest: false,
        settings: settings,
        deviceId: deviceId,
        deviceName: deviceName,
        key: Uint8List(32), // (nothing is sealed in a share: the service does the access control)
        encrypted: false,
        place: '${share.providerId}/${share.place}',
      );

  ScopedSyncLibrary _library(List<SyncPeer> peers) => ScopedSyncLibrary(library, _scope(), targetFolderId: share.targetFolderId)
    ..participants = {deviceId, for (final p in peers) p.id};

  // ---- the quick way: ask what changed before reading anything

  /// The stamps of the shared folder, or null when the service cannot say (or this request did not work: the run itself then tells
  /// what is wrong).
  Future<Map<String, String>?> _stamps(CloudFolder folder) async {
    try {
      return await folder.stamps('');
    } on CloudAccountMissing {
      rethrow;
    } catch (e) {
      debugPrint('[share] ${share.name}: no stamps ($e)');
      return null;
    }
  }

  /// What the last run that went well saw, as long as it still counts.
  Future<_Seen?> _lastSeen() async {
    final seen = _Seen.fromJson(await settings.get(_kSeen));
    return seen != null &&
            DateTime.now().millisecondsSinceEpoch - seen.at <
                maxAge.inMilliseconds
        ? seen
        : null;
  }

  /// The participants: those of the last look when their directory has the same stamp; otherwise they are listed and read, and this
  /// device says that it takes part if it has not. [announced] tells whether it wrote.
  Future<({List<ParticipantRecord> records, bool announced})>
  _participantsQuick(
    CloudFolder folder,
    Map<String, String>? stamps,
    _Seen? seen,
  ) async {
    final stamp = stamps?[participantsDir];
    if (seen != null && stamp != null && seen.participants == stamp) return (records: seen.peers, announced: false);
    final names = await folder.list(participantsDir);
    final announced = await _announceIfNeeded(folder, names);
    return (
      records: await readParticipants(folder, names),
      announced: announced,
    );
  }

  /// The participants whose directory has the stamp it had when they were read (they published nothing since), with the stamps now.
  ({Set<String> unchanged, Map<String, String> now}) _unchanged(
    FolderSync sync,
    List<ParticipantRecord> records,
    Map<String, String>? stamps,
    _Seen? seen,
  ) {
    final unchanged = <String>{}, now = <String, String>{};
    if (stamps == null) return (unchanged: unchanged, now: now);
    for (final r in records) {
      final stamp =
          stamps[sync.dirOf(r.id, encrypted: false)] ??
          '-'; // ('-': there is none, which the listing tells for sure)
      now[r.id] = stamp;
      if (seen != null && seen.dirs[r.id] == stamp) unchanged.add(r.id);
    }
    return (unchanged: unchanged, now: now);
  }

  /// One run. With [quick] it first asks the service what changed (one request) and reads only what did: nothing at all when the shared
  /// folder is as this device left it and [force] is not set (something changed here); the participants of the last look when nobody
  /// joined; the manifest of a participant only when its directory changed. The look it relies on is made in full again every
  /// [maxAge], and after any run that had a problem. Without [quick] everything is read, as a person who presses "Sync now" expects.

  Future<SharedRunResult> run({bool Function()? stop,
    bool quick = false,
    bool force = false,}) async {
    final folder = _folder;
    if (!quick || force) cache?.invalidate(); // (a run that was asked for, or one that is told something changed here, reads what is up there now)
    if (!quick) {
    final peers = await _participants(folder);
    final scoped = _library(peers);
    final result = await _sync(folder, scoped, peers).run(stop: stop, publish: share.writes);
    return SharedRunResult(result, ended: scoped.rootDeleted);
  }
    final stamps = await _stamps(folder);
    final seen = stamps == null ? null : await _lastSeen();
    if (!force &&
        seen != null &&
        seen.root != null &&
        stamps![''] == seen.root) {
      debugPrint(
        '[share] ${share.name}: nothing new up there (stamp ${seen.root})',
      );
      return const SharedRunResult(
        FolderSyncResult(0, 0, 0, []),
        skipped: true,
      );
    }
    final (:records, :announced) = await _participantsQuick(
      folder,
      stamps,
      seen,
    );
    final peers = [for (final r in records) SyncPeer(r.id, r.name)];
    final scoped = _library(peers);
    final sync = _sync(folder, scoped, peers);
    final (:unchanged, :now) = _unchanged(sync, records, stamps, seen);
    final result = await sync.run(
      stop: stop,
      publish: share.writes,
      unchanged: unchanged,
    );
    final clean =
        result.ok &&
        sync.complete &&
        !(stop?.call() ?? false) &&
        !scoped.rootDeleted;
    if (clean && stamps != null) {
      final wrote = announced || result.put > 0;
      await settings.set(
        _kSeen,
        _Seen(
          wrote
              ? null
              : stamps[''], // (what this device wrote changed the stamp of the folder: the next run looks once more)
          announced ? null : stamps[participantsDir],
          records,
          now,
          unchanged.isEmpty || seen == null
              ? DateTime.now().millisecondsSinceEpoch
              : seen.at,
        ).toJson(),
      );
    } else if (await settings.get(_kSeen) != null) {
      await settings.set(_kSeen, '');
    }
    debugPrint(
      '[share] ${share.name}: ${unchanged.length} of ${records.length} participants unchanged, ${result.taken} taken, ${result.put} put',
    );
    return SharedRunResult(result, ended: scoped.rootDeleted);
  }

  /// A look whether a participant published a newer copy of the note [noteId] (see `FolderSync.pullNote`); true if it was taken in.
  /// With [quick] nothing is asked of a participant whose directory did not change since the last run (and when nothing did, one
  /// request is all it costs).
  Future<bool> pullNote(String noteId, {bool Function()? allow,
    bool quick = false,}) async {
    final folder = _folder;
    if (!quick) cache?.invalidate();
    if (!quick) {
    final peers = await _participants(folder);
    final scoped = _library(peers);
    await scoped.scope.refresh();
    if (!scoped.scope.hasNote(noteId)) return false;
    return _sync(folder, scoped, peers).pullNote(noteId, allow: allow);
  }
    final stamps = await _stamps(folder);
    final seen = stamps == null ? null : await _lastSeen();
    if (seen != null && seen.root != null && stamps![''] == seen.root) return false;
    final (:records, announced: _) = await _participantsQuick(
      folder,
      stamps,
      seen,
    );
    final peers = [for (final r in records) SyncPeer(r.id, r.name)];
    final scoped = _library(peers);
    await scoped.scope.refresh();
    if (!scoped.scope.hasNote(noteId)) return false;
    final sync = _sync(folder, scoped, peers);
    return sync.pullNote(
      noteId,
      allow: allow,
      unchanged: _unchanged(sync, records, stamps, seen).unchanged,
    );
}
}
