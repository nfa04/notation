import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../cloudsync/caching_folder.dart';
import '../cloudsync/cloud_folder.dart';
import '../collab/shared_notes.dart' show NativeMarks, SharedKind;
import '../data/note_data.dart';
import '../data/settings_repository.dart';
import '../devicesync/live_notes.dart';
import '../devicesync/sync_devices.dart';
import '../devicesync/sync_keys.dart';
import '../devicesync/sync_library.dart';
import '../l10n/language.dart';
import 'native_share_provider.dart';
import 'share_model.dart';
import 'share_live.dart';
import 'share_scope.dart';
import 'shared_folder_sync.dart';

/// A share that was given to the person and that they have not taken in yet.
class PendingShare {
  final NativeShareProvider provider;
  final IncomingShare share;

  const PendingShare(this.provider, this.share);
}

/// How the last run of a share went, for the screen.
class ShareStatus {
  final bool running;
  final String? problem;
  final String? what;

  const ShareStatus({this.running = false, this.problem, this.what});
}

/// Sharing notes and folders with the other people of a cloud service, and keeping what is shared in step. It is the cloud sync
/// (see `CloudSyncService`) for a note or folder and the people it is shared with, instead of the library and the devices of one person:
/// the same engine, run for each share, after a change, every few minutes, and when asked.
///
/// A **given** share is a folder in the person's own cloud space (`Notation Shares/<name> (Notation <id>)`) that is shared with each person
/// at the service, with the rights they were given. A **received** share is a folder that someone shared with them: when they accept it,
/// a note or a folder of the library takes part in it. See `docs/native-sharing.md`.
class NativeShareService extends ChangeNotifier implements NativeMarks {
  final Database _db;
  final SettingsRepository _settings;
  final SyncLibrary _library;
  final ShareStore _store;
  final List<NativeShareProvider> providers;

  /// The id and name of this device in a sync profile; a share needs one to tell this device from the others that take part.
  final String? Function() _deviceId;
  final String Function() _deviceName;

  /// How often it runs by itself, and how long after a change.
  final Duration every, afterChange;

  /// How soon a note that is opened may look again in the folder of the same share (opening several notes of it in a row asks once).
  final Duration lookEvery;

  /// How often a quick run looks for shares given to the person.
  final Duration incomingEvery;
  final List<Duration> retryDelays;
  final DateTime Function() _now;

  // ---- for working on a note live with the others of a share
  final DeviceIdentity? Function() _identity;
  final String? Function() _serverOf;
  final List<Map<String, Object>> Function()? _iceServers;
  final ShareRoomOpener? _openRoom;
  final ShareLinkerFactory? _makeLinker;
  final Duration _liveHeartbeat, _liveOfflineAfter, _liveRollCall;

  /// Told when a share given to the person was taken in (the automations can react to it).
  void Function(NativeShare share)? onReceived;

  NativeShareService({
    required Database db,
    required SettingsRepository settings,
    required SyncLibrary library,
    required this.providers,
    required String? Function() deviceId,
    required String Function() deviceName,
    Stream<String>? changes,
    this.every = const Duration(minutes: 3),
    this.afterChange = const Duration(seconds: 30),
    this.lookEvery = const Duration(seconds: 20),
    this.incomingEvery = const Duration(minutes: 5),
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 4), Duration(seconds: 10)],
    DateTime Function()? now,
    DeviceIdentity? Function()? identity,
    String? Function()? serverOf,
    List<Map<String, Object>> Function()? iceServers,
    ShareRoomOpener? openRoom,
    ShareLinkerFactory? makeLinker,
    Duration liveHeartbeat = const Duration(seconds: 45),
    Duration liveOfflineAfter = const Duration(seconds: 130),
    Duration liveRollCall = const Duration(seconds: 5),
  })  : _db = db,
        _identity = identity ?? (() => null),
        _serverOf = serverOf ?? (() => null),
        _iceServers = iceServers,
        _openRoom = openRoom,
        _makeLinker = makeLinker,
        _liveHeartbeat = liveHeartbeat,
        _liveOfflineAfter = liveOfflineAfter,
        _liveRollCall = liveRollCall,
        _settings = settings,
        _library = library,
        _store = ShareStore(db),
        _deviceId = deviceId,
        _deviceName = deviceName,
        _now = now ?? DateTime.now {
    _changesSub = changes?.listen((id) {
      if (!_library.isApplying(id)) _localChanged(id);
    });
  }

  StreamSubscription<String>? _changesSub;
  Timer? _timer, _changeTimer;
  List<NativeShare> _shares = [];
  List<PendingShare> _pending = [];
  String? _incomingProblem;
  final Map<String, ShareStatus> _status = {};
  bool _dirty = false, _disposed = false;

  List<NativeShare> get shares => List.unmodifiable(_shares);
  List<NativeShare> get given => [for (final s in _shares) if (s.outgoing) s];
  List<NativeShare> get received => [for (final s in _shares) if (!s.outgoing) s];

  /// Shares given to the person that wait to be taken in (as of the last look, see [refreshIncoming]).
  List<PendingShare> get pending => List.unmodifiable(_pending);

  /// Why the last look for shares given to the person failed (null: it did not).
  String? get incomingProblem => _incomingProblem;

  ShareStatus statusOf(String shareId) => _status[shareId] ?? const ShareStatus();

  bool get running => _active > 0;

  NativeShareProvider? providerOf(String id) => providers.where((p) => p.id == id).firstOrNull;

  /// The services that can be shared through now: an account is connected and the service can share with people.
  List<NativeShareProvider> get usable => [for (final p in providers) if (p.available && p.unsupportedReason == null) p];

  /// The services with an account that cannot share with people, and why (for the screen: they are not left out in silence).
  List<({NativeShareProvider provider, String reason})> get unsupported => [
        for (final p in providers)
          if (p.available && p.unsupportedReason != null) (provider: p, reason: p.unsupportedReason!),
      ];

  /// The share given for a note or folder through a service, if there is one.
  NativeShare? givenFor(ShareKind kind, String rootId, {String? providerId}) => given
      .where((s) => s.kind == kind && s.rootId == rootId && s.state == ShareState.active && (providerId == null || s.providerId == providerId))
      .firstOrNull;

  /// Whether the note or folder takes part in a share, given or received (for a mark on it).
  bool isShared(ShareKind kind, String rootId) => _shares.any((s) => s.kind == kind && s.rootId == rootId && s.state == ShareState.active);

  // ---- marks on notes and folders

  Map<String, SharedKind> _noteMarks = {}, _folderMarks = {};
  Map<String, String> _noteFrom = {};

  @override
  SharedKind noteKind(String noteId) => _noteMarks[noteId] ?? SharedKind.none;

  @override
  SharedKind folderKind(String folderId) => _folderMarks[folderId] ?? SharedKind.none;

  @override
  String? noteFrom(String noteId) => _noteFrom[noteId];

  /// Works out which notes and folders take part in a share that is going, and in which direction, from what each share remembers.
  Future<void> _refreshMarks() async {
    final byShare = {for (final s in _shares) if (s.state == ShareState.active) s.id: s};
    final notes = <String, SharedKind>{}, folders = <String, SharedKind>{}, from = <String, String>{};
    SharedKind add(SharedKind? had, bool given) {
      final now = given ? SharedKind.byMe : SharedKind.withMe;
      return had == null || had == now ? now : SharedKind.both;
    }

    for (final r in await _db.query('native_share_items')) {
      final s = byShare[r['share_id']];
      if (s == null) continue;
      final id = r['id'] as String;
      if (r['kind'] == 'note') {
        notes[id] = add(notes[id], s.outgoing);
        if (!s.outgoing && s.owner.isNotEmpty) from[id] = s.owner;
      } else {
        folders[id] = add(folders[id], s.outgoing);
      }
    }
    // (a share that has not run yet: its note or folder is marked all the same)
    for (final s in byShare.values) {
      final map = s.kind == ShareKind.note ? notes : folders;
      map[s.rootId] = add(map[s.rootId], s.outgoing);
    }
    // which notes belong to which share (for working on them live)
    final members = <String, Set<String>>{};
    for (final r in await _db.query('native_share_items', where: "kind = 'note'")) {
      if (byShare.containsKey(r['share_id'])) (members[r['share_id'] as String] ??= {}).add(r['id'] as String);
    }
    for (final s in byShare.values) {
      if (s.kind == ShareKind.note) (members[s.id] ??= {}).add(s.rootId);
    }
    _membersOf = members;
    _noteMarks = notes;
    _folderMarks = folders;
    _noteFrom = from;
    unawaited(_syncLive());
  }

  // ---- working on a note live with the others of a share

  Map<String, Set<String>> _membersOf = {};
  final Map<String, ShareLive> _lives = {};
  Set<String> _openNotes = const {};
  LiveNotes? _liveNotes;

  /// The live sessions of the app (set when there are any to start): with it, a note of a share that is open here and on another
  /// person's device is worked on live.
  set live(LiveNotes? value) {
    _liveNotes = value;
    unawaited(_syncLive());
  }

  /// The notes that are open on the screen of this device now. One that belongs to a share that this device may write to brings it into
  /// the room of the share; when another person's device has it open too, the two work on it live.
  void setOpenNotes(Set<String> ids) {
    if (setEquals(ids, _openNotes)) return;
    _openNotes = Set.unmodifiable(ids);
    unawaited(_syncLive());
  }

  Future<void> _syncLive() async {
    if (_disposed) return;
    final live = _liveNotes, me = _identity();
    final canLive = live != null && me != null && (_serverOf() ?? '').isNotEmpty;
    final wanted = <String>{};
    for (final share in _shares) {
      final secret = share.liveSecret;
      final provider = providerOf(share.providerId);
      if (secret == null || share.state != ShareState.active || !share.writes || provider == null || !provider.available) continue;
      final open = _openNotes.intersection(_membersOf[share.id] ?? const {});
      var l = _lives[share.id];
      if (open.isEmpty && l == null) continue;
      if (!canLive) continue;
      wanted.add(share.id);
      l ??= _lives[share.id] = ShareLive(
        shareId: share.id,
        secret: SyncSecret(Uint8List.fromList(base64.decode(secret))),
        serverOf: _serverOf,
        identity: me,
        deviceName: _deviceName(),
        live: live,
        library: _library,
        participants: () => _writers(share.id),
        onPublish: (_) => unawaited(syncShare(share.id)),
        openRoom: _openRoom,
        makeLinker: _makeLinker,
        iceServers: _iceServers,
        heartbeat: _liveHeartbeat,
        offlineAfter: _liveOfflineAfter,
        rollCallWait: _liveRollCall,
      );
      l.setOpen(open);
    }
    // a share that is over, or that this device does not write to any more: nothing is worked on live through it
    for (final id in _lives.keys.toList()) {
      final share = _shares.where((s) => s.id == id).firstOrNull;
      if (share == null || share.state != ShareState.active || !share.writes || !canLive) {
        unawaited(_lives.remove(id)!.dispose());
      }
    }
  }

  /// Those who may write in the share, with their keys, from the files they wrote in the shared folder (this device's own is written
  /// first, so that the others can find it).
  Future<List<PairedDevice>> _writers(String shareId) async {
    final share = _shares.where((s) => s.id == shareId).firstOrNull;
    final provider = share == null ? null : providerOf(share.providerId);
    if (share == null || provider == null || !provider.available) return const [];
    final runner = _runner(share, provider);
    await runner.announce();
    return [
      for (final r in await runner.readParticipants())
        if (r.key != null) PairedDevice(id: r.id, name: r.name, publicKey: r.key!, addedAt: 0),
    ];
  }

  /// The app is back in front: the rooms are entered again, and a run is made if the last one was a while ago.
  void wake() {
    for (final l in _lives.values) {
      l.wake();
    }
    final last = _shares.map((s) => s.lastSync ?? 0).fold<int>(0, (a, b) => a > b ? a : b);
    if (_shares.any((s) => s.state == ShareState.active) && _now().millisecondsSinceEpoch - last > const Duration(minutes: 2).inMilliseconds) {
      unawaited(syncNow(quick: true));
    }
  }

  // ---- the same shares on the devices of the person

  /// The list of shares travels between the devices of a profile as a setting (see `syncedSetting`): each share with when it last
  /// changed, and a note of when each was ended. The newer of two copies wins, an ended share is ended on every device, and a share that
  /// one device does not know yet is taken over, so a second device takes part in it too (with its own directory in the shared folder).
  static const _kProfile = 'native_shares';
  static const _goneFor = Duration(days: 90);

  /// When a share was ended on a device of the profile, by id.
  Map<String, int> _gone = {};

  Future<void> _mergeProfile() async {
    final text = await _settings.get(_kProfile);
    if (text == null) return;
    Map<String, Object?> blob;
    try {
      blob = (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    _gone = {
      for (final e in ((blob['gone'] as Map?) ?? const {}).entries)
        if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };
    for (final j in (blob['shares'] as List? ?? const [])) {
      final r = NativeShare.fromProfileJson(j);
      if (r == null || (_gone[r.id] ?? -1) >= r.createdAt) continue;
      final i = _shares.indexWhere((x) => x.id == r.id);
      if (i < 0) {
        await _store.save(r);
        _shares = [..._shares, r];
      } else if (r.updatedAt > _shares[i].updatedAt) {
        final merged = r.copyWith(lastSync: _shares[i].lastSync);
        await _store.save(merged);
        _shares = [..._shares]..[i] = merged;
      }
    }
    // what was ended on another device is ended here (the notes stay)
    for (final s in List.of(_shares)) {
      if ((_gone[s.id] ?? -1) >= s.createdAt) {
        await _rememberLeft(s);
        await _store.delete(s.id);
        _shares = [for (final x in _shares) if (x.id != s.id) x];
      }
    }
    await _publishProfile();
  }

  /// Writes the list as the other devices should have it, if it is not so already.
  Future<void> _publishProfile() async {
    final cutoff = _now().subtract(_goneFor).millisecondsSinceEpoch;
    _gone.removeWhere((_, at) => at < cutoff);
    final text = jsonEncode({'v': 1, 'shares': [for (final s in _shares) s.toProfileJson()], 'gone': _gone});
    final was = await _settings.get(_kProfile);
    if (was == null && _shares.isEmpty && _gone.isEmpty) return; // (nothing to tell)
    if (text != was) await _settings.set(_kProfile, text);
  }

  // ---- loading and the schedule

  Future<void> load() async {
    _shares = await _store.all();
    await _mergeProfile();
    await _refreshMarks();
    _schedule();
    if (!_disposed) notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || providers.isEmpty) return;
    // (also with no share yet: this is how the shares given to the person are found)
    _timer = Timer.periodic(every, (_) => unawaited(syncNow(quick: true)));
  }

  /// The shares something changed in here since they last ran (only those are run when the person stops editing).
  final Set<String> _dirtyShares = {};

  void _localChanged(String id) {
    if (_disposed || !_shares.any((s) => s.state == ShareState.active)) return;
    unawaited(_markDirty(id));
  }

  Future<void> _markDirty(String id) async {
    final touched = await _sharesTouchedBy(id);
    if (_disposed || touched.isEmpty) return;
    _dirtyShares.addAll(touched);
    if (_active > 0) _dirty = true;
    _changeTimer?.cancel();
    _changeTimer = Timer(afterChange, () => unawaited(_syncDirty()));
  }

  /// The shares a change of the note or folder [id] may concern: those it belongs to (or belonged to), those it has just been put in (a
  /// note in a shared folder, a folder in one) and those that are about it. A note that is in no share changes nothing up there.
  Future<Set<String>> _sharesTouchedBy(String id) async {
    final out = <String>{
      for (final s in _shares)
        if (s.state == ShareState.active && s.rootId == id) s.id,
    };
    final members = await _db.query(
      'native_share_items',
      columns: ['share_id'],
      where: 'id = ?',
      whereArgs: [id],
    );
    out.addAll([for (final r in members) r['share_id'] as String]);
    final parents = <String>[
      for (final r in await _db.query(
        'notes',
        columns: ['folder_id'],
        where: 'id = ?',
        whereArgs: [id],
      ))
        ?(r['folder_id'] as String?),
      for (final r in await _db.query(
        'folders',
        columns: ['parent_id'],
        where: 'id = ?',
        whereArgs: [id],
      ))
        ?(r['parent_id'] as String?),
    ];
    for (final folder in parents) {
      final inside = await _db.query(
        'native_share_items',
        columns: ['share_id'],
        where: "kind = 'folder' AND id = ?",
        whereArgs: [folder],
      );
      out.addAll([for (final r in inside) r['share_id'] as String]);
    }
    return {
      for (final id in out)
        if (_shares.any((s) => s.id == id && s.state == ShareState.active)) id,
    };
  }

  /// A run for the shares something changed in.
  Future<void> _syncDirty() => _exclusive(() async {
    for (final s in List.of(_shares)) {
      if (_disposed) break;
      if (s.state == ShareState.active && _dirtyShares.remove(s.id)) await _runShare(s.id, quick: true, force: true);
    }
  });

  /// Saves a share. A change in what it is (not just that it ran) is told to the other devices of the person.
  Future<void> _put(NativeShare s, {bool content = true}) async {
    if (content) s = s.copyWith(updatedAt: _now().millisecondsSinceEpoch);
    await _store.save(s);
    final i = _shares.indexWhere((x) => x.id == s.id);
    if (i < 0) {
      _shares = [..._shares, s];
    } else {
      _shares = [..._shares]..[i] = s;
    }
    _schedule();
    await _refreshMarks();
    if (content) await _publishProfile();
    if (!_disposed) notifyListeners();
  }

  /// A share is over here: out of the list, with a note of when for the other devices of the person.
  Future<void> _drop(NativeShare share) async {
    await _lives.remove(share.id)?.dispose();
    await _store.delete(share.id);
    _shares = [for (final s in _shares) if (s.id != share.id) s];
    _status.remove(share.id);
    _gone[share.id] = _now().millisecondsSinceEpoch;
    _schedule();
    await _refreshMarks();
    await _publishProfile();
    if (!_disposed) notifyListeners();
  }

  NativeShare _get(String id) => _shares.firstWhere((s) => s.id == id);

  String _newId() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// The folders of the library, for choosing where a received share goes.
  Future<List<FolderEntry>> folders() => _library.notes.listFolders();

  /// The id of a share received: the same on every device of the person that takes it in, so that they come to one share between them.
  static String _incomingId(String providerId, String providerShareId) =>
      sha256.convert(utf8.encode('$providerId|$providerShareId')).bytes.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ---- giving

  /// Shares the note [noteId] with [person] through [provider]. A note that is shared already through the service gets the person added.
  Future<NativeShare> shareNote(String noteId, NativeShareProvider provider, SharePerson person, ShareRole role) async {
    if (await _library.files.isLocked(noteId)) throw NativeShareException(tr('Take the lock off this note before sharing it.'));
    final info = await _library.notes.noteInfo(noteId);
    if (info == null) throw NativeShareException(tr('That note is gone'));
    return _give(ShareKind.note, noteId, info.title.isEmpty ? tr('Untitled') : info.title, provider, person, role);
  }

  /// Shares the folder [folderId] and what is in it with [person] through [provider].
  Future<NativeShare> shareFolder(String folderId, NativeShareProvider provider, SharePerson person, ShareRole role) async {
    final folder = (await _library.notes.listFolders()).where((f) => f.id == folderId).firstOrNull;
    if (folder == null) throw NativeShareException(tr('That folder is gone'));
    return _give(ShareKind.folder, folderId, folder.name, provider, person, role);
  }

  Future<NativeShare> _give(ShareKind kind, String rootId, String title, NativeShareProvider provider, SharePerson person, ShareRole role) async {
    if (!provider.available) throw NativeShareException(tr('Connect {service} first.', {'service': provider.label}));
    final why = provider.unsupportedReason;
    if (why != null) throw NativeShareException(why);
    final existing = givenFor(kind, rootId, providerId: provider.id);
    if (existing != null) return addPerson(existing, person, role);
    final device = _deviceId();
    if (device == null) throw NativeShareException(tr('This device is not part of a sync profile yet.'));

    final id = _newId();
    final place = 'Notation Shares/${ShareNaming.folderName(title, id)}';
    final liveSecret = base64.encode(SyncSecret.create().bytes);
    var share = NativeShare(
      id: id,
      providerId: provider.id,
      direction: ShareDirection.outgoing,
      kind: kind,
      rootId: rootId,
      name: title,
      place: place,
      liveSecret: liveSecret,
      createdAt: _now().millisecondsSinceEpoch,
    );
    await _store.save(share,); // (so that the notes and folders that belong to it are remembered from the first run)
    try {
      await RetryingFolder(provider.folderAt(place), delays: retryDelays).write(ShareDescriptor.fileName, ShareDescriptor(kind, rootId, title, live: liveSecret).encode());
      // what is shared is up there before anyone is told
      final first = await _runner(share, provider).run();
      if (!first.sync.ok) throw NativeShareException(first.sync.problems.join('\n'));
      final given = await provider.share(place, person, role);
      share = share.copyWith(recipients: [ShareRecipient(person, given.role, given.id, link: given.link)], lastSync: _now().millisecondsSinceEpoch);
    } catch (e) {
      // nothing is left half made
      try {
        await provider.removeFolder(place);
      } catch (_) {}
      await _store.delete(id);
      rethrow;
    }
    await _put(share);
    return share;
  }

  /// Gives a share that exists to one more person.
  Future<NativeShare> addPerson(NativeShare share, SharePerson person, ShareRole role) async {
    final provider = _providerFor(share);
    final given = await provider.share(share.place, person, role);
    final r = ShareRecipient(person, given.role, given.id, link: given.link);
    final updated = share.copyWith(recipients: [for (final x in share.recipients) if (x.person != person) x, r]);
    await _put(updated);
    return updated;
  }

  Future<void> changeRole(NativeShare share, ShareRecipient to, ShareRole role) async {
    final provider = _providerFor(share);
    await provider.changeRole(ProviderShare(to.shareId, to.person, to.role), role);
    await _put(share.copyWith(recipients: [for (final x in share.recipients) x.shareId == to.shareId ? x.withRole(role) : x]));
  }

  /// Takes the access of one person away: they stop receiving; what they have already stays with them.
  Future<void> removePerson(NativeShare share, ShareRecipient who) async {
    final provider = _providerFor(share);
    await provider.unshare(ProviderShare(who.shareId, who.person, who.role));
    await _put(share.copyWith(recipients: [for (final x in share.recipients) if (x.shareId != who.shareId) x]));
  }

  /// Ends a share that was given: nobody gets any more, and the folder is removed from the person's cloud space. The note or folder
  /// itself stays as it is, and so does what the others already have.
  Future<void> stopSharing(NativeShare share) async {
    if (!share.outgoing) return leave(share);
    final provider = _providerFor(share);
    await provider.removeFolder(share.place);
    await _drop(share);
  }

  NativeShareProvider _providerFor(NativeShare share) {
    final p = providerOf(share.providerId);
    if (p == null || !p.available) throw NativeShareException(tr('Connect {service} first.', {'service': p?.label ?? share.providerId}));
    return p;
  }

  // ---- receiving

  /// What the person left or removed, by the id of the note or folder: `service|owner|kind`. Taking in the same thing again from the same
  /// person is a return, and the note or folder that is here is the one that was shared; from anyone else it is refused.
  static const _kLeft = 'native_share_left';

  Future<Map<String, String>> _readLeft() async {
    try {
      return (jsonDecode(await _settings.get(_kLeft) ?? '{}') as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  static String _leftKey(String providerId, String owner, ShareKind kind) => '$providerId|$owner|${kind.name}';

  Future<void> _rememberLeft(NativeShare share) async {
    if (share.outgoing) return;
    final left = await _readLeft();
    left[share.rootId] = _leftKey(share.providerId, share.owner, share.kind);
    await _settings.set(_kLeft, jsonEncode(left));
  }

  /// Adds a share from a link that came with an invitation (for a service that cannot list the shares given to the person): it waits in
  /// [pending] like the others.
  Future<PendingShare> addLink(String text) async {
    final provider = usable.where((p) => p.acceptsLinks && p.recognizes(text)).firstOrNull;
    if (provider == null) {
      final any = providers.where((p) => p.acceptsLinks && p.recognizes(text)).firstOrNull;
      throw NativeShareException(any == null ? tr('This is not a link to a share.') : (any.unsupportedReason ?? tr('Connect {service} first.', {'service': any.label})));
    }
    final share = await provider.addLink(text.trim());
    final known = _shares.any((x) => !x.outgoing && x.providerId == provider.id && x.providerShareId == share.id);
    if (known) throw NativeShareException(tr('You have this share already.'));
    final pending = PendingShare(provider, share);
    _pending = [for (final p in _pending) if (!(p.provider.id == provider.id && p.share.id == share.id)) p, pending];
    if (!_disposed) notifyListeners();
    return pending;
  }

  /// Looks at each connected service for shares that were given to the person: those of Notation that are not taken in yet become
  /// [pending]; a received share that the service no longer lists was withdrawn, and ends.
  Future<void> refreshIncoming() async {
    final found = <PendingShare>[];
    final seen = <String, Set<String>>{};
    String? problem;
    for (final p in usable) {
      try {
        final list = await p.incoming();
        seen[p.id] = {for (final s in list) s.id};
        for (final s in list) {
          if (!ShareNaming.isOurs(s.name)) continue;
          if (_shares.any((x) => !x.outgoing && x.providerId == p.id && x.providerShareId == s.id)) continue;
          found.add(PendingShare(p, s));
        }
      } catch (e) {
        debugPrint('[nativeshare] could not look for shares on ${p.label}: $e');
        problem = '${p.label}: ${e is NativeShareException ? e.message : e}';
      }
    }
    _pending = found;
    _incomingProblem = problem;
    for (final s in received) {
      final ids = seen[s.providerId];
      if (ids != null && s.state == ShareState.active && !ids.contains(s.providerShareId)) {
        await _put(s.copyWith(state: ShareState.ended));
        _status[s.id] = ShareStatus(problem: tr('The share was withdrawn. What you have of it stays.'));
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// Takes a share in: it is accepted at the service if it has to be, and a note or a folder of the library takes part in it from now on.
  /// The folder it arrives in is [targetFolderId] (null: at the top).
  Future<NativeShare> accept(PendingShare pending, {String? targetFolderId}) async {
    final device = _deviceId();
    if (device == null) throw NativeShareException(tr('This device is not part of a sync profile yet.'));
    final provider = pending.provider;
    var incoming = pending.share;
    if (incoming.pending) incoming = await provider.accept(incoming);

    final descriptor = ShareDescriptor.decode(await RetryingFolder(provider.folderAt(incoming.place), delays: retryDelays).read(ShareDescriptor.fileName));
    if (descriptor == null) throw NativeShareException(tr('This is not a share from Notation, or from a newer version of it.'));
    // an id that is here already would make the share write this note or folder to the others
    final rootHere = descriptor.kind == ShareKind.note
        ? (await _db.query('notes', columns: ['id'], where: 'id = ?', whereArgs: [descriptor.rootId])).isNotEmpty
        : (await _db.query('folders', columns: ['id'], where: 'id = ?', whereArgs: [descriptor.rootId])).isNotEmpty;
    final left = await _readLeft();
    final returning = rootHere && left[descriptor.rootId] == _leftKey(provider.id, incoming.owner, descriptor.kind);
    if (rootHere && !returning) {
      throw NativeShareException(tr('You have this {what} already, and not from this share. Delete it here first to take the share in.',
          {'what': descriptor.kind == ShareKind.note ? tr('note') : tr('folder')}));
    }
    final share = NativeShare(
      id: _incomingId(provider.id, incoming.id),
      providerId: provider.id,
      direction: ShareDirection.incoming,
      kind: descriptor.kind,
      rootId: descriptor.rootId,
      name: descriptor.name.isEmpty ? ShareNaming.shown(incoming.name) : descriptor.name,
      place: incoming.place,
      role: incoming.role,
      owner: incoming.owner,
      providerShareId: incoming.id,
      targetFolderId: targetFolderId,
      liveSecret: descriptor.live,
      createdAt: _now().millisecondsSinceEpoch,
    );
    await _put(share);
    if (returning) {
      // (what is here is what was shared before: it takes part again, as it is)
      final scope = ShareScope(_db, shareId: share.id, kind: share.kind, rootId: share.rootId);
      if (share.kind == ShareKind.note) {
        await scope.addNote(share.rootId);
      } else {
        await scope.addFolder(share.rootId);
      }
      left.remove(descriptor.rootId);
      await _settings.set(_kLeft, jsonEncode(left));
    }
    _pending = [for (final p in _pending) if (!(p.provider.id == provider.id && p.share.id == pending.share.id)) p];
    onReceived?.call(share);
    unawaited(syncShare(share.id));
    return share;
  }

  /// The person no longer wants a share they received: they leave it at the service; the notes stay, unshared.
  Future<void> leave(NativeShare share) async {
    if (share.outgoing) return stopSharing(share);
    final provider = providerOf(share.providerId);
    if (provider != null && provider.available && share.state == ShareState.active) {
      await provider.leave(IncomingShare(id: share.providerShareId, name: share.name, owner: share.owner, role: share.role, place: share.place));
    }
    await _rememberLeft(share);
    await _drop(share);
  }

  /// Takes a share that ended off the list.
  Future<void> remove(NativeShare share) async {
    await _rememberLeft(share);
    await _drop(share);
  }

  // ---- running

  /// What was read of each shared folder, kept from run to run (see [CachingFolder]).
  final Map<String, CachingFolder> _caches = {};

  SharedFolderSync _runner(NativeShare share, NativeShareProvider provider) => SharedFolderSync(
        cache: _caches.putIfAbsent('${provider.id}/${share.place}', () => CachingFolder(provider.folderAt(share.place))),
        share: share,
        provider: provider,
        library: _library,
        db: _db,
        settings: _settings,
        deviceId: _deviceId()!,
        deviceName: _deviceName(),
        deviceKey: _identity()?.publicKey,
        retryDelays: retryDelays,
      );

  /// Runs go one after the other: two at once would write the same files.
  Future<void> _serial = Future.value();
  int _active = 0;
  bool _allQueued = false;

  Future<void> _exclusive(Future<void> Function() job) {
    _active++;
    if (_active == 1 && !_disposed) notifyListeners();
    final run = _serial.then((_) => _disposed ? null : job());
    _serial = run.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _active--;
      if (_active == 0 && !_disposed) {
        notifyListeners();
        if (_dirty) {
          _dirty = false;
          _changeTimer?.cancel();
          _changeTimer = Timer(const Duration(seconds: 5), () => unawaited(_syncDirty()));
        }
      }
    });
    return run;
  }

  Future<void> _closing = Future.value();

  /// Done when the live sessions of the shares have been let go of (after [dispose]).
  Future<void> get disposed => _closing;

  /// Done when the runs under way are done (for tests, and before the app closes).
  Future<void> get idle => _serial;

  /// A run for every share that is going, one after the other. Done when they are all done. Asked again while one is waiting to start,
  /// it is the same run.
  ///
  /// With [quick] (the timer, the app coming back) a share where nothing changed up there nor here costs one request; without it
  /// (the person pressed "Sync now") everything is read.
  Future<void> syncNow({bool quick = false}) {
    if (_disposed) return Future.value();
    if (_allQueued) return _serial;
    _allQueued = true;
    return _exclusive(() async {
      _allQueued = false;
      // (the shares given to the person: a quick run asks the service for them only now and then, two requests for each service)
      final lookedForIncoming = _incomingAt;
      if (usable.isNotEmpty &&
          (!quick ||
              lookedForIncoming == null ||
              _now().difference(lookedForIncoming) >= incomingEvery)) {
        _incomingAt = _now(); await refreshIncoming();
      }
      for (final s in List.of(_shares)) {
        if (_disposed) break;
        if (s.state == ShareState.active) await _runShare(s.id, quick: quick, force: _dirtyShares.remove(s.id));
      }
    });
  }

  /// A note was opened: a look whether a participant of a share it belongs to put a newer copy of it up, taken in if so (see
  /// `FolderSync.pullNote`). True if the note was replaced. Quiet: a problem is not shown, the next run will say it.
  final Map<String, DateTime> _lookedAt = {};
  DateTime? _incomingAt;
  Future<bool> refreshNote(String noteId, {bool Function()? allow}) async {
    if (_disposed || _deviceId() == null) return false;
    final rows = await _db.query('native_share_items', columns: ['share_id'], where: "kind = 'note' AND id = ?", whereArgs: [noteId]);
    final ids = {for (final r in rows) r['share_id'] as String};
    if (ids.isEmpty) return false;
    var took = false;
    await _exclusive(() async {
      for (final share in _shares) {
        if (!ids.contains(share.id) || share.state != ShareState.active) continue;
        final provider = providerOf(share.providerId);
        if (provider == null || !provider.available) continue;
        final last = _lookedAt[share.id];
        if (last != null && _now().difference(last) < lookEvery) continue; // (it looked a moment ago)
        _lookedAt[share.id] = _now();
        try {
          if (await _runner(share, provider,).pullNote(noteId, allow: allow, quick: true)) {
            took = true;
            break;
          }
        } catch (e) {
          debugPrint('[nativeshare] could not look for a newer copy of $noteId: $e');
        }
      }
    });
    return took;
  }

  /// A run for one share (after it was taken in, say).
  Future<void> syncShare(String shareId) => _exclusive(() async {
        if (_shares.any((s) => s.id == shareId)) await _runShare(shareId, quick: true, force: true);
      });

  /// A share made before there was live editing in it has no secret for it: the owner makes one, the others read it from the folder.
  Future<NativeShare> _ensureLiveSecret(NativeShare share, NativeShareProvider provider) async {
    if (share.liveSecret != null) return share;
    try {
      final folder = RetryingFolder(provider.folderAt(share.place), delays: retryDelays);
      final d = ShareDescriptor.decode(await folder.read(ShareDescriptor.fileName));
      var secret = d?.live;
      if (secret == null && share.outgoing) {
        secret = base64.encode(SyncSecret.create().bytes);
        await folder.write(ShareDescriptor.fileName, ShareDescriptor(share.kind, share.rootId, d?.name ?? share.name, live: secret).encode());
      }
      if (secret != null) {
        final updated = share.copyWith(liveSecret: secret);
        await _put(updated);
        return updated;
      }
    } catch (e) {
      debugPrint('[nativeshare] could not get the secret for working live: $e');
    }
    return share;
  }

  Future<void> _runShare(String shareId, {
    bool quick = false,
    bool force = false,
  }) async {
    var share = _get(shareId);
    final provider = providerOf(share.providerId);
    if (provider == null || !provider.available || _deviceId() == null) {
      _status[shareId] = ShareStatus(problem: tr('Connect {service} first.', {'service': provider?.label ?? share.providerId}));
      return;
    }
    _status[shareId] = ShareStatus(running: true, what: tr('Syncing through {service}...', {'service': provider.label}));
    notifyListeners();
    try {
      share = await _ensureLiveSecret(share, provider);
      final r = await _runner(share, provider).run(quick: quick, force: force);
      var updated = _get(shareId,).copyWith(lastSync: _now().millisecondsSinceEpoch);
      if (r.ended) updated = updated.copyWith(state: ShareState.ended);
      await _put(updated, content: r.ended);
      _status[shareId] = ShareStatus(
        problem: r.ended ? tr('The owner removed this. What you have of it stays.') : (r.sync.ok ? null : r.sync.problems.join('\n')),
        what: trCount(r.sync.taken, 'One change taken in', '{n} changes taken in'),
      );
    } catch (e) {
      _status[shareId] = ShareStatus(problem: '$e'.replaceFirst('Bad state: ', ''));
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _closing = Future.wait([for (final l in _lives.values) l.dispose()]);
    _lives.clear();
    _timer?.cancel();
    _changeTimer?.cancel();
    _changesSub?.cancel();
    super.dispose();
  }
}
