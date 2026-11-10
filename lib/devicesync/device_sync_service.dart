import '../web/temporary_session.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../cloudsync/cloud_sync_service.dart';
import '../collab/invite.dart';
import '../collab/transport.dart';
import '../data/settings_repository.dart';
import '../l10n/language.dart';
import 'live_notes.dart';
import '../collab/webrtc_transport.dart' show defaultIceServers;
import 'peer_linker.dart';
import 'sync_accounts.dart';
import 'sync_devices.dart';
import 'sync_keys.dart';
import 'sync_diag.dart';
import 'sync_library.dart';
import 'sync_link.dart';
import 'sync_room.dart';
import 'sync_session.dart';

part 'device_sync_live.dart';

/// Opens the room of a profile on the signalling server.
typedef RoomOpener = Future<SyncRoom> Function(String server, SyncSecret secret);

typedef LinkerFactory = PeerLinker Function(SyncRoom room, String me);

/// The profile of the person, which sync reads and (when a device is added) replaces.
abstract class SyncProfile implements ProfileAccess {
  /// Takes the id and name of the profile this device was added to.
  Future<void> adopt(String id, String name);
}

/// What is known of another device of the profile.
class PeerState {
  final String id;
  String name;

  /// It is in the room now (it was heard from lately).
  bool online = false;
  DateTime? seen;
  bool syncing = false;
  DateTime? lastSync;
  String? problem;

  /// The notes it has open on its screen (it said so in the room).
  Set<String> open = const {};

  /// Whether it syncs its notes now (it said so in the room; an older app does not say, and does): a device that is only in the room
  /// for a note it works on live, with the automatic sync off, does not.
  bool syncs = true;

  /// A browser that was connected for a while only: the list drops it by itself when it was not seen for an hour.
  bool temporary = false;

  PeerState(this.id, this.name);

  /// It is not in the room any more (it said so, went silent, or the connection to the room broke): what it had open is not known.
  void away() {
    online = false;
    open = const {};
  }
}

/// A device that asks to be added: the person here compares [code] with the one on that device and says yes or no.
class JoinRequest {
  final int id;
  final String deviceName;
  final String code;
  final Completer<bool> _decision = Completer<bool>();

  JoinRequest(this.id, this.deviceName, this.code);
}

/// Syncing the profile between the devices of one person: name and id, notes, folders and settings (see [SyncSession] for what
/// happens between two devices, `docs/profile-sync.md` for the whole).
///
///  * **Adding a device.** [offerLink] makes (the first time) the secret of the profile and a link that holds it. The other
///    device opens the link ([joinWith]); both show six digits; the person says yes on the device that made the link.
///  * **Staying in sync.** With [auto] on (a choice the person makes, as it tells the server that this device is online) the
///    device stays in the profile's room on the signalling server; when another device of the profile is there too, they
///    connect directly and sync, again when something changed and every few minutes. With it off, [syncNow] looks for the
///    other devices for a couple of minutes, once. The sync through a cloud folder runs beside it, for the devices that are not
///    online at the same time.
///  * **Working on a note live.** While a note is open (and [liveTogether] is on) the device is in the room too, and tells the
///    others which notes it has open; a note that is open on two devices is worked on live over a direct connection.
///
/// What the server sees: that some device that knows the secret is connected to a room (whose name changes every day), and when it
/// sends something. Every message in the room is sealed with a key from the secret, with a random nonce of its own, and padded to
/// the same size: the server cannot read which notes are open, nor tell that the same note is opened again, nor how many are open.
/// Every device proves itself with its device secret.
class DeviceSyncService extends ChangeNotifier {
  static const _kAuto = 'sync_auto';
  static const _kCheck = 'sync_check';
  static const _kLive = 'sync_live';
  static const _kDeviceId = 'sync_device_id';
  static const _kDeviceName = 'sync_device_name';
  static const _kServer = 'sync_server';
  static const _kLast = 'sync_last';
  static const _kTemp = 'sync_temp_devices';

  final SettingsRepository _settings;
  final SyncKeyStore _keys;
  final SyncLibrary _library;
  final SyncProfile _profile;
  final DeviceBook book;

  /// The signalling server to use when a link is made (the person's own, or the built-in one); null if there is none.
  final String? Function() serverOf;

  final RoomOpener _openRoom;
  final LinkerFactory _makeLinker;

  /// Told after a sync changed settings or the profile, so that what shows them can read them again.
  final VoidCallback? onSettingsChanged;

  /// The sync through a cloud folder (set when the app is put together; null where there is none).
  CloudSyncService? get cloud => _cloud;
  CloudSyncService? _cloud;
  set cloud(CloudSyncService? value) {
    _cloud?.removeListener(_cloudChanged);
    _cloud = value?..addListener(_cloudChanged);
    _cloudChanged();
  }

  /// The library is synced through the cloud folder here: it is on and its service has an account on this device. (The room is used
  /// all the same, to find the other devices that are online and to work on notes live.)
  bool get cloudCarries => _cloud?.folderNow != null;
  bool _carried = false;

  void _cloudChanged() {
    if (_disposed || cloudCarries == _carried) return;
    _carried = cloudCarries;
    notifyListeners();
  }

  /// The cloud accounts of the app, which a sync hands from one device to the other (the newer of each wins).
  final SyncedAccounts? accounts;

  /// How long a temporary browser may stay away before this device takes it out of the list.
  final Duration temporaryLife;

  final Duration heartbeat, offlineAfter, resync, changeDelay, offerFor, joinFor, manualFor, checkEvery, checkFor, rollCallWait;

  DeviceSyncService({
    required SettingsRepository settings,
    required SyncKeyStore keys,
    required SyncLibrary library,
    required SyncProfile profile,
    required this.serverOf,
    Stream<String>? changes,
    RoomOpener? openRoom,
    LinkerFactory? makeLinker,
    List<Map<String, Object>> Function()? iceServers,
    this.onSettingsChanged,
    this.accounts,
    this.heartbeat = const Duration(seconds: 45),
    this.offlineAfter = const Duration(seconds: 130),
    this.resync = const Duration(minutes: 5),
    this.changeDelay = const Duration(seconds: 20),
    this.offerFor = const Duration(minutes: 10),
    this.joinFor = const Duration(minutes: 4),
    this.manualFor = const Duration(minutes: 2),
    this.checkEvery = const Duration(minutes: 10),
    this.checkFor = const Duration(seconds: 60),
    this.rollCallWait = const Duration(seconds: 5),
    this.temporaryLife = const Duration(hours: 1),
  })  : _settings = settings,
        _keys = keys,
        _library = library,
        _profile = profile,
        book = DeviceBook(settings.get, settings.set),
        _openRoom = openRoom ??
            ((server, secret) async {
              final room = ServerSyncRoom(server, secret);
              await room.connect();
              return room;
            }),
        _makeLinker = makeLinker ?? ((room, me) => WebRtcLinker(room, me, iceServers: iceServers?.call() ?? defaultIceServers)) {
    _changesSub = changes?.listen((id) {
      if (!_library.isApplying(id)) _localChanged();
    });
  }

  StreamSubscription<String>? _changesSub;

  // ---- what is known

  DeviceIdentity? _identity;
  SyncSecret? _secret;
  String? _server;
  bool _auto = false;
  bool _check = false;
  bool _liveTogether = true;
  String _deviceName = '';
  bool _loaded = false;
  final Map<String, DateTime> _lastSync = {};
  final Map<String, PeerState> _peers = {};

  /// This device is part of a profile that syncs (it has the secret).
  bool get isSetUp => _secret != null;

  /// The secret of the profile (null before there is one); the sync through a cloud folder seals its files with a key from it.
  SyncSecret? get profileSecret => _secret;

  /// Stay in the room and sync whenever another device is there too (the server learns when this device is online).
  bool get auto => _auto;

  /// Look for the other devices from time to time (when the app starts, comes to the front, and every [checkEvery]): the device
  /// is in the room for [checkFor] and syncs if another is there. The server learns of these short visits, not of more.
  bool get check => _check;

  /// Work on a note that is open on two devices at the same time, live: while a note is open the device is in the room and tells the
  /// others (sealed) which notes it has open. Off: it does not say, nothing is worked on live, and the copies come together at the
  /// next sync.
  bool get liveTogether => _liveTogether;

  String get deviceName => _deviceName;
  String? get deviceId => _identity?.id;

  /// This device's identity (its id and the key it proves it by), once it has one; null before.
  DeviceIdentity? get identity => _identity;
  String? get server => _server;

  /// The signalling server this device's room is on: the one its profile was linked with, or else the one in the live collaboration
  /// settings (a device that signed in through a cloud folder was never linked, so it has none of its own).
  String? get signalServer => _server ?? serverOf();

  /// The other devices of the profile.
  List<PeerState> get peers => [
        for (final d in book.active)
          if (d.id != _identity?.id) _peers.putIfAbsent(d.id, () => PeerState(d.id, d.name))
            ..name = d.name
            ..temporary = _tempDevices.containsKey(d.id)
            ..lastSync = _lastSync[d.id],
      ];

  /// Whether this device is in the room on the signalling server now.
  bool get connected => _room?.connected ?? false;

  /// Why the last attempt to reach the server or another device did not work.
  String? get problem => _outOfStep
      ? tr(
          'The other devices have another key for this device than the one it signs with, so they refuse it. Sign out of the profile on this device and sign in again.',
        )
      : _problem;
  String? _problem;

  /// Whether the entry of this device on its own list holds another key than the one it signs with (see [_diagSelf]).
  bool get keyOutOfStep => _outOfStep;
  bool _outOfStep = false;

  Future<void> load() async {
    _deviceName = (await _settings.get(_kDeviceName)) ?? _defaultDeviceName();
    _auto = (await _settings.get(_kAuto)) == '1';
    _check = (await _settings.get(_kCheck)) == '1';
    _liveTogether = (await _settings.get(_kLive)) != '0';
    final bytes = await _keys.profileSecret();
    _secret = bytes == null || bytes.length != SyncSecret.length ? null : SyncSecret(bytes);
    // who this device is: needed by more than the room (the sync through a cloud folder, the list of the other devices), and
    // the room may never open when the folder carries the sync
    if (_secret != null) await _ensureIdentity();
    _server = await _settings.get(_kServer);
    _temporary = kIsWeb && temporaryMarked;
    try {
      final temp = jsonDecode((await _settings.get(_kTemp)) ?? '{}') as Map;
      for (final e in temp.entries) {
        _tempDevices[e.key as String] = e.value as int;
      }
    } catch (_) {}
    _tempTimer ??= Timer.periodic(const Duration(minutes: 5), (_) => unawaited(expireTemporaryDevices()));
    try {
      final last = jsonDecode((await _settings.get(_kLast)) ?? '{}') as Map;
      for (final e in last.entries) {
        _lastSync[e.key as String] = DateTime.fromMillisecondsSinceEpoch(e.value as int);
      }
    } catch (_) {
      // forgotten times are only shown as never
    }
    await book.load();
    _diagSelf('start');
    syncDiag(
      'start: profile ${_secret == null ? 'none' : _profile.id}, server ${_server ?? serverOf() ?? 'none'}, name $_deviceName, web=$kIsWeb',
    );
    _loaded = true;
    notifyListeners();
    _scheduleChecks();
    await expireTemporaryDevices();
    await _applyPolicy();
  }

  static String _defaultDeviceName() => kIsWeb ? 'Web browser' : switch (Platform.operatingSystem) {
      'android' => 'Android',
      'ios' => 'iPhone/iPad',
      'macos' => 'Mac',
      'windows' => 'Windows PC',
      'linux' => 'Linux PC',
      _ => 'Device',
    };

  Future<DeviceIdentity>? _identityLoading;

  /// Who this device is: read once, or made the first time (two that ask at once get the same).
  Future<DeviceIdentity> _ensureIdentity() async {
    final have = _identity;
    if (have != null) return have;
    return _identityLoading ??= _loadIdentity().whenComplete(() => _identityLoading = null);
  }

  Future<DeviceIdentity> _loadIdentity() async {
    // the id and the secret half are one entry of the keystore, so that they cannot come from two different times
    final kept = await _keys.deviceIdentity();
    final settingsId = await _settings.get(_kDeviceId);
    syncDiag(
      'identity: keystore entry ${kept == null ? 'none' : kept.id}, legacy seed ${await _keys.deviceSeed() == null ? 'none' : 'present'}, settings id $settingsId',
    );
    if (kept != null && kept.seed.length == 32) {
      if (settingsId != kept.id) {
        syncDiag(
          'identity: settings id $settingsId differs from the keystore id ${kept.id}; the keystore one is used',
        );
        await _settings.set(_kDeviceId, kept.id);
      }
      final me = _identity = await DeviceIdentity.fromSeed(kept.id, kept.seed);
      syncDiag(
        'identity: this device is ${me.id}, key ${keyTag(me.publicKey)} (from the keystore entry)',
      );
      _diagSelf('identity loaded');
      return me;
    }
    // (a device from before: the two were kept apart - take over what is there)
    final seed = await _keys.deviceSeed();
    final id = await _settings.get(_kDeviceId);
    if (seed != null && seed.length == 32 && id != null) {
      await _keys.setDeviceIdentity((id: id, seed: seed));
      final me = _identity = await DeviceIdentity.fromSeed(id, seed);
      syncDiag(
        'identity: this device is ${me.id}, key ${keyTag(me.publicKey)} (taken over from the two old places)',
      );
      _diagSelf('identity migrated');
      return me;
    }
    final fresh = await DeviceIdentity.create();
    await _keys.setDeviceIdentity((id: fresh.id, seed:fresh.seed));
    await _settings.set(_kDeviceId, fresh.id);
    syncDiag(
      'identity: NEW device ${fresh.id}, key ${keyTag(fresh.publicKey)} (nothing was kept${seed != null || id != null ? ': old seed ${seed != null}, old id $id' : ''})',
    );
    return _identity = fresh;
  }

  /// Logs whether the entry this device has for itself on its list holds the key it actually signs with. They must be the same: the
  /// others learn this device's key from that entry (and from the endorsement made from it), and refuse the device when it signs
  /// with another one.
  void _diagSelf(String where) {
    final me = _identity;
    if (me == null) return;
    PairedDevice? entry;
    for (final d in book.all) {
      if (d.id == me.id) entry = d;
    }
    final wasOut = _outOfStep;
    _outOfStep =
        entry != null && keyTag(entry.publicKey) != keyTag(me.publicKey);
    if (wasOut != _outOfStep && _loaded) notifyListeners();
    if (entry == null) {
      syncDiag(
        'self-check ($where): ${me.id} is not on the list (${book.all.length} devices)',
      );
    } else if (keyTag(entry.publicKey) != keyTag(me.publicKey)) {
      syncDiag(
        'self-check ($where): MISMATCH - the list has key ${keyTag(entry.publicKey)} for this device ${me.id}, it signs with ${keyTag(me.publicKey)}',
      );
    } else {
      syncDiag(
        'self-check ($where): ok, ${me.id} key ${keyTag(me.publicKey)}${entry.active ? '' : ' (but removed on the list)'}',
      );
    }
  }

  /// Makes this device a new one (a new id and key): what it was is forgotten here.
  Future<void> _forgetIdentity() async {
    await _keys.setDeviceIdentity(null);
    await _keys.setDeviceSeed(null);
    await _settings.remove(_kDeviceId);
    _identity = null;
    await _ensureIdentity();
  }

  Future<void> setDeviceName(String name) async {
    final n = name.trim();
    if (n.isEmpty || n == _deviceName) return;
    _deviceName = n;
    await _settings.set(_kDeviceName, n);
    // (the others learn the name from the list of devices, at the next sync)
    final me = _identity?.id;
    if (me != null) await book.rename(me, n, DateTime.now().millisecondsSinceEpoch);
    notifyListeners();
  }

  // ---- adding a device

  bool _offering = false;
  Timer? _offerTimer;
  SyncLink? _link;

  /// The link that is on offer now, if any.
  SyncLink? get offeredLink => _offering ? _link : null;

  final List<JoinRequest> _requests = [];
  int _requestIds = 0;

  /// Devices that ask to be added and wait for a yes.
  List<JoinRequest> get requests => List.unmodifiable(_requests);

  /// Starts the profile on this device alone (its secret and identity), without a signalling server: for the sync through a cloud
  /// folder, which needs a profile but no other device. Does nothing when the profile exists.
  Future<void> ensureProfile() async {
    if (_secret != null) return;
    final me = await _ensureIdentity();
    final secret = SyncSecret.create();
    await _keys.setProfileSecret(secret.bytes);
    _secret = secret;
    syncDiag('ensureProfile: started a profile on ${me.id}');
    if (book.find(me.id) == null) {
      await book.add(PairedDevice(id: me.id, name: _deviceName, publicKey: me.publicKey, addedAt: DateTime.now().millisecondsSinceEpoch));
    }
    _diagSelf('ensureProfile');
    notifyListeners();
  }

  /// The id and name of the profile of the person (what a device that signs in with the recovery key takes over).
  String get profileId => _profile.id;
  String get profileName => _profile.name;

  /// Tells whoever shows the devices that the list changed (a device was added by something other than a pairing: see `CloudSignIn`).
  void refreshPeers() {
    if (!_disposed) notifyListeners();
  }

  /// This device becomes part of the profile whose [secret] it was given, without a link and without anyone saying yes on another
  /// device: it signed in with the recovery key (see `CloudSignIn`). It takes over the id and name of the profile and starts a list of
  /// devices with itself on it; the others are read from the cloud folder. Throws when the device is part of a profile already.
  ///
  /// [server] is the signalling server the devices of the profile meet on (the sign-in file says which): without it the device could not
  /// find them to work on a note live, unless it happens to have the same one in its settings.
  Future<DeviceIdentity> joinWithSecret(
    SyncSecret secret,
    String profileId,
    String profileName, {
    String server = '',
  }) async {
    if (_secret != null) {
      throw StateError(
        tr(
          'This device is part of a profile already. Leave it first to sign in to another.',
        ),
      );
    }
    final me = await _ensureIdentity();
    await _keys.setProfileSecret(secret.bytes);
    _secret = secret;
    if (server.isNotEmpty) {
      await _settings.set(_kServer, server);
      _server = server;
    }
    syncDiag(
      'joinWithSecret: ${me.id} (${keyTag(me.publicKey)}) signs in to profile $profileId, server ${server.isEmpty ? '(none given)' : server}',
    );
    await book.clear();
    await book.add(
      PairedDevice(
        id: me.id,
        name: _deviceName,
        publicKey: me.publicKey,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _diagSelf('joinWithSecret');
    if (profileId.isNotEmpty) await _profile.adopt(profileId, profileName);
    _peers.clear();
    _lastSync.clear();
    _scheduleChecks();
    onSettingsChanged?.call();
    notifyListeners();
    return me;
  }

  /// Makes the link for another device to join this profile with (and, the first time, the profile's secret) and waits for it
  /// for a while. Throws when there is no signalling server to use.
  Future<SyncLink> offerLink() async {
    final server = _server ?? serverOf();
    if (server == null || server.isEmpty) throw StateError(tr('There is no signalling server: set one in the live collaboration settings.'));
    final me = await _ensureIdentity();
    var secret = _secret;
    if (secret == null) {
      secret = SyncSecret.create();
      await _keys.setProfileSecret(secret.bytes);
      _secret = secret;
    }
    if (_server == null) {
      // (a profile started by ensureProfile has a secret but no server yet)
      await _settings.set(_kServer, server);
      _server = server;
    }
    if (book.find(me.id) == null) {
      await book.add(PairedDevice(id: me.id, name: _deviceName, publicKey: me.publicKey, addedAt: DateTime.now().millisecondsSinceEpoch));
    }
    _scheduleChecks();
    _offering = true;
    _link = SyncLink(_server!, secret, from: _profile.name);
    _offerTimer?.cancel();
    _offerTimer = Timer(offerFor, stopOffering);
    notifyListeners();
    _announce();
    await _applyPolicy();
    return _link!;
  }

  void stopOffering() {
    if (!_offering) return;
    _offering = false;
    _answeringConnect = false;
    _offerTimer?.cancel();
    for (final r in List.of(_requests)) {
      answer(r.id, false);
    }
    notifyListeners();
    unawaited(_applyPolicy());
  }

  /// The person's answer to a device that asks to be added.
  void answer(int requestId, bool yes) {
    final r = _requests.where((r) => r.id == requestId).firstOrNull;
    if (r == null) return;
    _requests.remove(r);
    if (!r._decision.isCompleted) r._decision.complete(yes);
    notifyListeners();
  }

  /// At most this many devices wait for a yes at once (someone who has the link could otherwise bury the person in requests).
  static const maxRequests = 3;

  Future<bool> _approve(String name, String code) {
    if (_requests.length >= maxRequests) return Future.value(false);
    final r = JoinRequest(++_requestIds, name, code);
    _requests.add(r);
    notifyListeners();
    return r._decision.future.timeout(const Duration(minutes: 3), onTimeout: () {
      _requests.remove(r);
      notifyListeners();
      return false;
    });
  }

  // ---- joining with a link

  SyncLink? _joinLink;
  Timer? _joinTimer;
  String? _joinCode;
  Completer<bool>? _joinConfirm;
  String? _joinProblem;
  bool _joined = false;

  /// This device came with a link and is looking for the device that made it.
  bool get joining => _joinLink != null;

  /// The six digits to compare with those on the other device, once the other device is found.
  String? get joinCode => _joinCode;

  String? get joinProblem => _joinProblem;

  /// Whether the last join worked.
  bool get joined => _joined;

  /// Comes into the profile of [link]: looks for the device that made it, shows the code, and - when the person there says yes -
  /// takes over the profile (id and name) and the notes, folders and settings.
  Future<void> joinWith(SyncLink link) async {
    await _ensureIdentity();
    _joinLink = link;
    _joinCode = null;
    _joinProblem = null;
    _joined = false;
    _armJoinTimer();
    notifyListeners();
    await _closeRoom(); // the room of the link, not the one of a profile this device had
    await _applyPolicy();
  }

  /// Ends the join when [joinFor] is over without the device that made the link having answered. A meeting that is under way (the
  /// code is compared, the person on the other device decides, the notes are brought over) is not cut off for it: ending the join
  /// closes the room and with it the connection, and the sync would fail with "the connection was lost" half-way.
  void _armJoinTimer() {
    _joinTimer?.cancel();
    _joinTimer = Timer(joinFor, () {
      if (_joinLink == null) return;
      if (_active > 0) {
        _armJoinTimer();
        return;
      }
      _joinProblem = tr('The device that made the link was not found. Is it online, and is its link still on offer?');
      _endJoin();
    });
  }

  void cancelJoin() => _endJoin();

  /// The person's answer to "does the other device show the same code?". A no ends the join and takes nothing over.
  void confirmJoinCode(bool same) {
    final c = _joinConfirm;
    if (c != null && !c.isCompleted) c.complete(same);
    if (!same) {
      _joinProblem = tr('The codes were not the same, so this device was not added');
      _endJoin();
    } else {
      notifyListeners();
    }
  }

  /// Whether the code is shown and waits for the person to say it is the same.
  bool get joinCodeNeedsAnswer => _joinConfirm != null && !_joinConfirm!.isCompleted;

  void _endJoin() {
    _joinLink = null;
    _joinTimer?.cancel();
    _joinCode = null;
    final c = _joinConfirm;
    _joinConfirm = null;
    if (c != null && !c.isCompleted) c.complete(false);
    notifyListeners();
    unawaited(_closeRoom().then((_) => _applyPolicy()));
  }

  Future<void> _commitJoin(SyncLink link) async {
    await _keys.setProfileSecret(link.secret.bytes);
    await _settings.set(_kServer, link.server);
    _secret = link.secret;
    _server = link.server;
    _joined = true;
    if (_temporary) {
      // (a browser that is here for a while only keeps the notes in step by itself: there is no later time to press "Sync now")
      _auto = true;
      await _settings.set(_kAuto, '1');
      _unsynced = false;
      _updateLeaveGuard();
    }
    _scheduleChecks();
    _joinLink = null;
    _joinTimer?.cancel();
    _joinCode = null;
    _peers.clear();
    _lastSync.clear();
    onSettingsChanged?.call();
    notifyListeners();
  }


  // ---- using a browser for a while only

  bool _temporary = false;
  bool _unsynced = false;
  ConnectLink? _connect;
  SyncRoom? _connectRoom;
  StreamSubscription<Map<String, Object?>>? _connectSub;
  Timer? _connectTimer;
  SyncLink? _connectArrived;

  /// This browser holds a temporary session: it signs out when its tab is closed (see lib/web/temporary_session_web.dart).
  bool get temporary => _temporary && isSetUp;

  /// Something changed here that no sync has carried to another device yet (a temporary session only: closing the tab would lose it).
  bool get unsynced => temporary && _unsynced;

  /// The tab must not be closed lightly: there are changes no other device has, a sync is under way, or a note is open (what is typed
  /// in it may not be saved yet).
  bool get _mustStay => temporary && (_unsynced || _active > 0 || _openNotes.isNotEmpty);

  void _updateLeaveGuard() => warnBeforeLeaving(_mustStay);

  /// A browser that is here for a while only does not take every note of the profile: it lists them, and a note comes when it is opened
  /// ([fetchNote]). Only in the browser, and only for a temporary session - a device that is part of the profile for good keeps all.
  bool get lazyNotes => kIsWeb && temporary;

  /// Makes sure the content of note [id] is here before it is opened: a note that is only listed is asked for from the other devices
  /// (at most [fetchFor]). True if the note can be opened (it is here in full, or this device keeps every note anyway).
  Future<bool> fetchNote(String id) async {
    if (!await _library.isStub(id)) return true;
    _library.request(id);
    final until = DateTime.now().add(fetchFor);
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      while (DateTime.now().isBefore(until) && !_disposed) {
        if (_running.isEmpty && DateTime.now().difference(last) >= const Duration(seconds: 6)) {
          last = DateTime.now();
          _syncOnlinePeers(force: true);
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!await _library.isStub(id)) return true;
      }
      return false;
    } finally {
      _library.withdraw(id);
    }
  }

  /// How long [fetchNote] waits for the other devices.
  static const fetchFor = Duration(seconds: 45);



  /// The code that is on offer now for a device with a profile to scan.
  ConnectLink? get connectOffer => _connect;

  /// The link a device answered the code with (once it has): [takeConnectedLink] turns it into the join.
  SyncLink? get connectArrived => _connectArrived;

  /// Browser: makes a code for a device that has a profile to scan, and waits in the room of its secret for the device to answer with
  /// a link of its profile. Throws when there is no signalling server.
  Future<ConnectLink> startConnect() async {
    final server = _server ?? serverOf();
    if (server == null || server.isEmpty) throw StateError(tr('There is no signalling server: set one in the live collaboration settings.'));
    await _ensureIdentity();
    stopConnect();
    final secret = SyncSecret.create();
    final room = await _openRoom(server, secret);
    if (_disposed) {
      await room.close();
      throw StateError('closed');
    }
    _connectRoom = room;
    _connectArrived = null;
    _connect = ConnectLink(server, secret);
    _connectSub = room.messages.listen((m) {
      if (m['t'] != 'link' || m['l'] is! String) return;
      final link = SyncLink.parse(m['l'] as String);
      if (link == null) return;
      _connectArrived = link;
      notifyListeners();
    });
    _connectTimer = Timer(offerFor, stopConnect);
    notifyListeners();
    return _connect!;
  }

  void stopConnect() {
    _connectTimer?.cancel();
    _connectSub?.cancel();
    final room = _connectRoom;
    _connectRoom = null;
    _connectSub = null;
    final had = _connect != null || _connectArrived != null;
    _connect = null;
    _connectArrived = null;
    if (room != null) unawaited(room.close());
    if (had && !_disposed) notifyListeners();
  }

  /// Browser: the device answered the code. The session is marked as temporary from here on (also when the join then fails: the
  /// next start throws away what the browser holds), and the link is what the join goes on with.
  SyncLink? takeConnectedLink() {
    final link = _connectArrived;
    if (link == null) return null;
    stopConnect();
    markTemporary();
    _temporary = true;
    _unsynced = false;
    return link;
  }

  /// A device with a profile read the code of [code] (a browser that wants to be connected for a while): it offers a link of its
  /// profile as usual and hands it to the browser through the room of the code, sealed with the code's secret. The person still
  /// compares the codes and says yes, as for any device that is added.
  Future<void> answerConnect(ConnectLink code) async {
    final link = await offerLink();
    _answeringConnect = true;
    final room = await _openRoom(code.server, code.secret);
    try {
      await room.send({'t': 'link', 'l': link.toLink()});
      await Future<void>.delayed(const Duration(seconds: 1)); // (a connection that is closed at once may lose it)
    } finally {
      await room.close();
    }
  }

  bool _answeringConnect = false;
  final Map<String, int> _tempDevices = {};
  Timer? _tempTimer;

  Future<void> _saveTemp() => _settings.set(_kTemp, jsonEncode(_tempDevices));

  /// Takes the temporary browsers out of the list that were not seen for [temporaryLife] (one that is online now is seen now). The
  /// removal is carried to the other devices of the profile like any other.
  Future<void> expireTemporaryDevices() async {
    if (_tempDevices.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final id in _tempDevices.keys.toList()) {
      if (book.find(id) == null) {
        _tempDevices.remove(id); // (taken out by hand, or by another device)
        changed = true;
      } else if (_peers[id]?.online ?? false) {
        _tempDevices[id] = now;
      } else if (now - _tempDevices[id]! > temporaryLife.inMilliseconds) {
        _tempDevices.remove(id);
        changed = true;
        if (!_disposed) await removeDevice(id);
      }
    }
    if (changed && !_disposed) await _saveTemp();
  }

  /// Browser: ends the temporary session now. The profile is left, the tab is marked as gone and the page opens again, which throws
  /// away what the browser held of it.
  Future<void> signOutTemporary() async {
    await leave();
    markTemporary(); // (a browser that was paired the usual way is signed out the same way: marked, then its tab is gone)
    _temporary = false;
    _unsynced = false;
    warnBeforeLeaving(false);
    endTemporary();
    reloadPage();
  }

  // ---- options and actions

  Future<void> setAuto(bool value) async {
    if (_auto == value) return;
    _auto = value;
    // (a note that is worked on live goes on: an open note keeps the device in the room without the automatic sync)
    await _settings.set(_kAuto, value ? '1' : '0');
    notifyListeners();
    _announce();
    await _applyPolicy();
  }

  Future<void> setLiveTogether(bool value) async {
    if (_liveTogether == value) return;
    _liveTogether = value;
    await _settings.set(_kLive, value ? '1' : '0');
    notifyListeners();
    if (_room != null) _hello(ask: true); // (the others learn what is open here now, or that nothing is)
    await _applyPolicy();
    unawaited(_evaluateLive());
  }

  Future<void> setCheck(bool value) async {
    if (_check == value) return;
    _check = value;
    await _settings.set(_kCheck, value ? '1' : '0');
    notifyListeners();
    _scheduleChecks();
  }

  DateTime? _checkUntil;
  Timer? _checkWindow, _checkTimer;

  void _scheduleChecks() {
    _checkTimer?.cancel();
    if (!_check || !isSetUp) return;
    _checkTimer = Timer.periodic(checkEvery, (_) => _startCheck());
    _startCheck();
  }

  /// One visit to the room: [checkFor] long, to see whether another device is there and to sync with it if so.
  void _startCheck() {
    if (!_loaded || !_check || !isSetUp || _auto || cloudCarries) return; // (in the room anyway, or the folder carries the sync)
    _checkUntil = DateTime.now().add(checkFor);
    _windowStart = DateTime.now();
    _checkWindow?.cancel();
    _checkWindow = Timer(checkFor, () {
      _checkUntil = null;
      notifyListeners();
      _announce();
      unawaited(_applyPolicy());
    });
    unawaited(_applyPolicy().then((_) => _hello(ask: true)));
  }

  /// Asks the other devices to say whether they are there (when the settings are in front, every half minute). Without the
  /// automatic sync, and outside a visit to the room, there is nothing to ask: a device that is not in the room cannot know.
  void refreshStatus() {
    if (!_loaded || !isSetUp) return;
    _expire();
    if (_room != null) {
      _hello(ask: true);
    } else {
      _startCheck();
    }
    notifyListeners();
  }

  DateTime? _manualUntil;
  Timer? _manualTimer;

  /// When "sync now" (or a look from time to time) began: it ends early once every device that is online was synced with since.
  DateTime? _windowStart;

  bool get _metEveryone {
    final since = _windowStart, me = _identity?.id;
    if (since == null) return true;
    for (final p in _peers.values) {
      if (!p.online || p.id == me || book.find(p.id) == null) continue;
      final last = _lastSync[p.id];
      if (last == null || last.isBefore(since)) return false;
    }
    return true;
  }

  /// Whether a manual sync is looking for the other devices.
  bool get lookingForDevices => _manualUntil != null;

  /// Looks for the other devices of the profile for a couple of minutes and syncs with those that are there; they have to be
  /// looking too (or have the automatic sync on).
  Future<void> syncNow() async {
    if (!isSetUp) return;
    _windowStart = DateTime.now();
    _manualUntil = DateTime.now().add(manualFor);
    _manualTimer?.cancel();
    _manualTimer = Timer(manualFor, () {
      _manualUntil = null;
      notifyListeners();
      _announce();
      unawaited(_applyPolicy());
    });
    notifyListeners();
    _announce();
    await _applyPolicy();
    _syncOnlinePeers(force: true);
  }

  Future<void> removeDevice(String id) async {
    await book.remove(id, DateTime.now().millisecondsSinceEpoch);
    _peers.remove(id);
    await _library.forgetMarks(id);
    notifyListeners();
  }

  /// This device leaves the profile: the secret and the list of devices are forgotten here (the notes stay).
  Future<void> leave() async {
    // the sessions with the devices of the profile end: this one is not one of them any more
    for (final note in {..._hosts.keys, ..._joinedHost.keys, ...?live?.ownNotes}) {
      await _leaveLive(note);
    }
    await _closeRoom();
    syncDiag('leave: ${_identity?.id} leaves the profile');
    await _keys.setProfileSecret(null);
    await book.clear();
    // (what the others have of this device - its key under its id - is not trusted again by a device that comes back as the same one:
    // it comes back as a new one, which is also the way out of an id whose key got out of step)
    await _forgetIdentity();
    _outOfStep = false;
    await _settings.remove(_kServer);
    _secret = null;
    _server = null;
    _offering = false;
    _peers.clear();
    _lastSync.clear();
    _manualUntil = null;
    _checkUntil = null;
    _checkTimer?.cancel();
    await setAuto(false);
    notifyListeners();
  }

  // ---- the room

  SyncRoom? _room;
  PeerLinker? _linker;
  StreamSubscription<Map<String, Object?>>? _roomSub;
  StreamSubscription<PeerChannel>? _incomingSub;
  StreamSubscription<bool>? _connectionSub;
  // (the signs of life, the sync every [resync], and the next try to open the room after the server could not be reached)
  Timer? _beat, _resyncTimer, _reopen;
  bool _opening = false;
  SyncSecret? _roomSecret;
  final Set<String> _running = {};
  final Map<String, DateTime> _attempts = {};
  final Map<String, int> _failures = {};

  bool get _wantRoom => _loaded && (_joinLink != null || (_secret != null && (_syncWanted || _shared.isNotEmpty)));

  /// Whether the library is synced with the devices in the room now (a device that is only there for a note that is open is not:
  /// with the automatic sync off, the person did not ask for it).
  bool get _syncWanted => _auto || _offering || _manualUntil != null || _checkUntil != null || _joinLink != null;

  /// The notes that are offered to be worked on live: those that are open, unless the person switched that off.
  Set<String> get _shared => _liveTogether && _live != null ? _openNotes : const {};

  Future<void> _applyPolicy() async {
    if (_disposed) return;
    if (_wantRoom) {
      if (_room == null && !_opening) await _open();
    } else if (_room != null) {
      if (_active > 0) {
        // a sync is under way: its connection goes through this room's linker, so the room stays until it is done
        Timer(const Duration(seconds: 2), () => unawaited(_applyPolicy()));
        return;
      }
      await _closeRoom();
    }
  }

  int _active = 0; // syncs under way (also those another device started)

  /// How many syncs are under way now.
  int get activeSyncs => _active;

  /// Counts a sync as under way that never ends (for tests of what waits on syncs).
  @visibleForTesting
  void debugHangSync() => _active++;

  Future<void> _open() async {
    final link = _joinLink;
    final secret = link?.secret ?? _secret;
    final server = link?.server ?? signalServer;
    if (secret == null || server == null || server.isEmpty) return;
    _opening = true;
    final me = await _ensureIdentity();
    try {
      syncDiag(
        'room: opening on $server as ${me.id} (${keyTag(me.publicKey)})${link == null ? '' : ' with a link'}',
      );
      final room = await _openRoom(server, secret);
      if (_disposed || !_wantRoom) {
        await room.close();
        return;
      }
      syncDiag('room: open, name ${room.name}');
      _diagSelf('room open');
      _room = room;
      _roomSecret = secret;
      _problem = null;
      _linker = _makeLinker(room, me.id);
      _roomSub = room.messages.listen(_onRoom);
      _incomingSub = _linker!.incoming.listen((c) => unawaited(_meet(null, channel: c)));
      var wasUp = true;
      _connectionSub = room.connection.listen((up) {
        if (up) {
          _hello(ask: !wasUp);
          // the connection to the server was lost and is back: the other devices may have changed things (or tried to reach this one)
          if (!wasUp) _syncRetry = Timer(const Duration(seconds: 3), () => _syncOnlinePeers(force: true));
          // and the notes that are open on two devices are worked on live again (the sessions broke with the connection)
          if (!wasUp) {
            _liveFailures.clear();
            _live?.wake(); // (a guest that lost its host tries again now that the way to it is back)
            unawaited(_evaluateLive());
          }
        } else {
          // what was known of the others is old now (the phone was asleep, the network changed): they say again when it is back
          for (final p in _peers.values) {
            p.away();
          }
        }
        wasUp = up;
        notifyListeners();
      });
      _hello();
      _beat = Timer.periodic(heartbeat, (_) {
        _hello();
        _expire();
      });
      _resyncTimer = Timer.periodic(resync, (_) => _syncOnlinePeers());
    } catch (e) {
      syncDiag('room: could not be opened: $e');
      _problem = tr('The signalling server could not be reached: {error}', {'error': '$e'.replaceFirst('Bad state: ', '')});
      _reopen?.cancel();
      _reopen = Timer(const Duration(seconds: 30), () => unawaited(_applyPolicy()));
    } finally {
      _opening = false;
      notifyListeners();
    }
  }

  Future<void> _closeRoom() async {
    _rollCall?.cancel();
    _beat?.cancel();
    _resyncTimer?.cancel();
    _reopen?.cancel();
    final room = _room;
    final me = _identity?.id;
    if (room != null && me != null && room.connected) {
      try {
        await room.send({'t': 'gone', 'd': me});
      } catch (_) {
        // going away anyway
      }
    }
    _room = null;
    _roomSecret = null;
    await _roomSub?.cancel();
    await _incomingSub?.cancel();
    await _connectionSub?.cancel();
    await _linker?.close();
    _linker = null;
    await room?.close();
    for (final p in _peers.values) {
      p.online = false;
    }
    notifyListeners();
  }

  void _hello({bool ask = false}) {
    final me = _identity;
    if (me == null) return;
    // (sealed and padded to one size, see [ServerSyncRoom.send]: the server sees neither the notes nor how many there are)
    _room?.send({
      't': 'here',
      'd': me.id,
      'n': _deviceName,
      if (ask) 'q': true,
      if (_shared.isNotEmpty) 'o': _shared.take(maxOpenNotes).toList(),
      's': _syncWanted ? 1 : 0,
    });
  }

  /// Whether a sync is wanted here changed: the others hear of it now, not at the next sign of life.
  void _announce() {
    if (_room != null) _hello();
  }

  Timer? _rollCall;

  /// A device may have gone without a word (the app was killed, or crashed, while it hosted a note): every device is asked to say
  /// it is here, and one that does not within [rollCallWait] is taken for gone, instead of after [offlineAfter].
  void _callRoll() {
    if (_rollCall?.isActive ?? false) return;
    final room = _room;
    if (room == null || !room.connected) return;
    final since = DateTime.now();
    _hello(ask: true);
    _rollCall = Timer(rollCallWait, () {
      if (!identical(room, _room) || !room.connected) return; // (with the connection gone, nothing is known of the others anyway)
      var changed = false;
      for (final p in _peers.values) {
        if (p.online && (p.seen == null || p.seen!.isBefore(since))) {
          p.away();
          changed = true;
        }
      }
      if (changed) {
        notifyListeners();
        unawaited(_evaluateLive());
      }
    });
  }

  void _expire() {
    final now = DateTime.now();
    var changed = false;
    for (final p in _peers.values) {
      if (p.online && p.seen != null && now.difference(p.seen!) > offlineAfter) {
        p.away();
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      unawaited(_evaluateLive()); // (a device that went without a word may have been the host)
    }
  }

  bool _canMeet(String peer) => book.find(peer) != null || _offering || _joinLink != null;

  void _onRoom(Map<String, Object?> m) {
    final me = _identity?.id;
    if (me == null) return;
    switch (m['t']) {
      case 'here':
        final peer = m['d'] as String?;
        if (peer == null || peer == me) return;
        if (!_peers.containsKey(peer) && _peers.length >= 64) return; // (only devices with the secret can say this; no need to grow for ever)
        final state = _peers.putIfAbsent(peer, () => PeerState(peer, (m['n'] as String?) ?? peer));
        final wasOnline = state.online;
        if (!wasOnline) {
          final known = book.find(peer);
          syncDiag(
            'room: $peer (${m['n']}) is here; ${known == null ? 'NOT on the list' : 'on the list with key ${keyTag(known.publicKey)}'}',
          );
        }
        state.online = true;
        state.seen = DateTime.now();
        if (_tempDevices.containsKey(peer)) _tempDevices[peer] = state.seen!.millisecondsSinceEpoch;
        if (m['n'] is String && book.find(peer) == null) state.name = m['n'] as String;
        final open = m['o'] is List ? {for (final id in (m['o'] as List).take(maxOpenNotes)) if (id is String) id} : <String>{};
        final openChanged = !setEquals(open, state.open);
        state.open = open;
        final syncs = m['s'] != 0;
        final startedSyncing = syncs && !state.syncs;
        state.syncs = syncs;
        if (!wasOnline || m['q'] == true) {
          _hello(); // it does not know this device is here yet (or asked)
          notifyListeners();
        }
        // (a device that is being added or adds one tries again at every sign of life: one failed attempt must not end it)
        final pairing = _joinLink != null || _offering;
        if ((!wasOnline || pairing || startedSyncing) && (_syncWanted || pairing) && (syncs || pairing) && me.compareTo(peer) < 0) unawaited(_meet(peer));
        // (also when it asks: it has just come back, and what was live between the two may have broken meanwhile)
        if (openChanged || !wasOnline || m['q'] == true) unawaited(_evaluateLive());
      case 'gone':
        final peer = m['d'] as String?;
        if (peer != null && _tempDevices.containsKey(peer)) _tempDevices[peer] = DateTime.now().millisecondsSinceEpoch;
        if (peer != null && _peers[peer] != null) {
          _peers[peer]!.away();
          notifyListeners();
          unawaited(_evaluateLive()); // (it may have hosted a note that is still open on two others)
        }
      case 'left':
        // the server saw a connection in the room close (it does not know whose): who is still here?
        _callRoll();
      case 'poke':
        // (asked to sync by a device with the automatic sync on: only if a sync is wanted here, not when only a note is worked on live)
        if (m['to'] == me && m['from'] is String && _syncWanted) unawaited(_meet(m['from'] as String));
    }
  }

  /// What the sync reads and writes; the screen tells it which notes are open.
  SyncLibrary get library => _library;

  /// The app is back in front: the connection to the room, which may have been cut in the background, is made again.
  void wake() {
    _room?.wake();
    _startCheck();
  }

  // ---- meeting another device

  /// Connects to [peer] (or takes the connection [channel] it made) and runs a sync with it.
  Future<void> _meet(String? peer, {PeerChannel? channel}) async {
    final me = await _ensureIdentity();
    final secret = _roomSecret;
    if (secret == null) {
      await channel?.close();
      return;
    }
    if (peer != null) {
      if (!_canMeet(peer) || _running.contains(peer)) return;
      // a device that keeps knocking (or whose proof keeps failing) is not let to make this one set up connections non-stop
      final last = _attempts[peer];
      final failed = _failures[peer] ?? 0;
      final wait = failed == 0 ? Duration.zero : _backoff(failed);
      if (last != null && DateTime.now().difference(last) < wait) return;
      _attempts[peer] = DateTime.now();
      _running.add(peer);
    }
    _active++;
    final state = peer == null ? null : _peers.putIfAbsent(peer, () => PeerState(peer, peer));
    state?.syncing = true;
    notifyListeners();
    var who = peer;
    var askedForCode = false; // (this meeting got as far as comparing the code of a device that wants to be added)
    try {
      final link = _joinLink;
      final roomName = _room?.name ?? (await secret.roomKeys()).room; // (the room of today)
      final c = channel ?? await _linker!.connect(peer!);
      final session = SyncSession(
        channel: c,
        secret: secret,
        roomName: roomName,
        identity: me,
        deviceName: _deviceName,
        book: book,
        profile: _profile,
        library: _library,
        offer: _offering && link == null ? PairingOffer(_approve) : null,
        liveSecretFor: _liveSecretFor,
        syncsLibrary: _syncWanted,
        lazyNotes: lazyNotes,
        accounts: accounts,
        join: link == null
            ? null
            : PairingJoin((code) {
                askedForCode = true;
                _joinCode = code;
                final c = _joinConfirm = Completer<bool>();
                notifyListeners();
                return c.future.timeout(const Duration(minutes: 3), onTimeout: () => false);
              }, _profile.adopt),
        onProgress: (what, fraction) {
          _progress = what;
          _fraction = fraction;
          notifyListeners();
        },
      );
      syncDiag(
        'meeting: ${peer == null ? 'a device called' : 'calling $peer'}, this device ${me.id} (${keyTag(me.publicKey)}), room $roomName',
      );
      final outcome = await session.run();
      who = outcome.peerId ?? who;
      syncDiag(
        'meeting: ended ${outcome.end}${outcome.problem == null ? '' : ' (${outcome.problem})'} with ${outcome.peerId} (${outcome.peerName})',
      );
      if (outcome.live != null) {
        _acceptLive(outcome.live!); // (a device that wants to work on a note live with this one)
      } else {
        await _finished(outcome, link, askedForCode: askedForCode);
      }
    } catch (e) {
      syncDiag('meeting: failed with $e');
      _problem = '$e'.replaceFirst('Bad state: ', '');
      if (state != null) state.problem = _problem;
      if (peer != null) _failures[peer] = (_failures[peer] ?? 0) + 1;
    } finally {
      _active--;
      if (peer != null) _running.remove(peer);
      state?.syncing = false;
      _progress = null;
      _fraction = null;
      notifyListeners();
      if (_resyncAfter && _running.isEmpty) {
        _resyncAfter = false;
        _syncOnlinePeers();
      } else if (peer != null && (_failures[peer] ?? 0) > 0 && (_failures[peer] ?? 0) <= maxRetries && !_disposed) {
        // the connection broke or the other device did not answer: once more after a pause (longer each time), the sync starts over
        // from the lists of both, so nothing that was taken in is taken twice
        _syncRetry?.cancel();
        _syncRetry = Timer(_backoff(_failures[peer]!) + const Duration(seconds: 1), () => _syncOnlinePeers(force: true));
      }
    }
  }

  /// How long to wait before meeting a device again after [failures] failed meetings in a row: 10 s, 20 s, ... at most 5 minutes.
  static Duration _backoff(int failures) => Duration(seconds: min(300, 5 << min(failures, 6)));

  /// How many times in a row a sync that failed is tried again by itself.
  static const maxRetries = 4;
  Timer? _syncRetry;

  String? _progress;
  double? _fraction;

  /// What the sync that is running does now, and how far it is.
  String? get progress => _progress;
  double? get fraction => _fraction;

  Future<void> _finished(SyncOutcome outcome, SyncLink? link, {bool askedForCode = false}) async {
    if (outcome.declined) return; // (this device turned a sync away, as it does not sync now: nothing went wrong)
    final id = outcome.peerId;
    final state = id == null ? null : _peers.putIfAbsent(id, () => PeerState(id, outcome.peerName ?? id));
    if (id != null) {
      if (outcome.ok) {
        _failures.remove(id);
      } else {
        _failures[id] = (_failures[id] ?? 0) + 1;
      }
    }
    if (outcome.removedSelf) {
      await leave();
      _problem = outcome.problem;
      return;
    }
    if (outcome.ok) {
      if (state != null) {
        state.problem = null;
        state.lastSync = DateTime.now();
        _lastSync[state.id] = state.lastSync!;
        if (_tempDevices.containsKey(state.id)) _tempDevices[state.id] = state.lastSync!.millisecondsSinceEpoch;
        await _settings.set(_kLast, jsonEncode({for (final e in _lastSync.entries) e.key: e.value.millisecondsSinceEpoch}));
      }
      if (outcome.paired && link != null) {
        await _commitJoin(link);
        await _closeRoom();
        await _applyPolicy();
      } else if (outcome.paired) {
        if (_answeringConnect && id != null) {
          // the device that was let in came from a code of a browser: it is not a device of the person, only a visit
          _answeringConnect = false;
          _tempDevices[id] = DateTime.now().millisecondsSinceEpoch;
          await _saveTemp();
        }
        _offering = false;
        _offerTimer?.cancel();
        _syncOnlinePeers(force: true,); // (the other devices of the profile hear of the new one now, not at their next meeting)
      }
      if (_temporary && _unsynced && !(_changeTimer?.isActive ?? false) && !_resyncAfter) {
        _unsynced = false; // (nothing changed since this sync started)
        _updateLeaveGuard();
      }
      if (outcome.changes > 0 || outcome.paired) onSettingsChanged?.call();
      // "sync now" and a look from time to time end once every device that is online was synced with (not at the first one)
      if (_metEveryone && (_manualUntil != null || _checkUntil != null)) {
        _manualUntil = null;
        _manualTimer?.cancel();
        _checkUntil = null;
        _checkWindow?.cancel();
        _windowStart = null;
        _announce();
      }
      _problem = null;
      if (!_auto && !_offering) unawaited(_applyPolicy());
    } else {
      state?.problem = outcome.problem;
      if (link != null && !askedForCode) {
        // (a device that joins tries every device it finds: one that is not offering the link turns it away, and that is not the
        // end of the join - it goes on until the device that made the link answers, or the time is up)
        return;
      }
      _problem = outcome.problem;
      if (link != null) {
        _joinProblem = outcome.problem;
        _endJoin();
      }
    }
  }

  // ---- again and again

  Timer? _changeTimer;
  bool _resyncAfter = false;

  void _localChanged() {
    if (_temporary && !_unsynced) {
      _unsynced = true;
      _updateLeaveGuard();
      notifyListeners();
    }
    if (_room == null) return;
    _changeTimer?.cancel();
    _changeTimer = Timer(changeDelay, () => _syncOnlinePeers(force: true));
  }

  /// Syncs with the devices that are online: those with the lower id are asked to connect, the others connect themselves.
  void _syncOnlinePeers({bool force = false}) {
    final me = _identity?.id;
    final room = _room;
    if (me == null || room == null || !room.connected || !_syncWanted) return;
    for (final p in _peers.values.where((p) => p.online && p.syncs && book.find(p.id) != null)) {
      if (_running.contains(p.id)) {
        _resyncAfter = true; // something changed while it was syncing: once more afterwards
        continue;
      }
      if (me.compareTo(p.id) < 0) {
        unawaited(_meet(p.id));
      } else {
        room.send({'t': 'poke', 'from': me, 'to': p.id});
      }
    }
  }

  // ---- working on one note live on two devices

  /// The live sessions of the app (set when there are any to start).
  LiveNotes? get live => _live;
  LiveNotes? _live;
  StreamSubscription<String>? _editorsReady;

  set live(LiveNotes? value) {
    _editorsReady?.cancel();
    _live?.changes.removeListener(_sessionChanged);
    _live = value;
    _lastStatus.clear();
    value?.changes.addListener(_sessionChanged);
    // (the editor of a note that was reported open registers a moment later, once it has loaded the note: a session can start then)
    _editorsReady = value?.editorsReady.listen((note) {
      if (_openNotes.contains(note)) unawaited(_evaluateLive());
    });
  }

  final Map<String, ({bool host, int people, bool ended})> _lastStatus = {};

  /// A session changed: when the host is left alone the note is saved and synced (the devices that were in it have it already, the
  /// others get it); when it is over for this device, what the devices had counts as agreed, so that the copies that follow - each
  /// device saved the note at its own moment - are not taken for changes made on both sides.
  void _sessionChanged() {
    final l = _live;
    if (_disposed || l == null) return;
    for (final note in {..._lastStatus.keys, ..._openNotes, ...l.ownNotes}) {
      final st = l.status(note);
      if (st == null) continue;
      final prev = _lastStatus[note];
      _lastStatus[note] = st;
      if (prev != null && prev.host && st.host && prev.people > 1 && (st.people <= 1 || st.ended)) unawaited(_publishLive(note));
      if (prev != null && !prev.ended && st.ended) {
        // (only the devices that were in it: one that was not, or left early, may have changed the note on its own meanwhile)
        unawaited(_library.markNoteAgreed(note, _liveWith.remove(note) ?? const {}));
        // (the host closed the note, or went: the room says who hosts now, if the note is still open on two devices)
        unawaited(Future<void>.delayed(Duration.zero, _evaluateLive));
      }
    }
  }

  /// At most this many open notes are told to the other devices.
  static const maxOpenNotes = 12;

  Set<String> _openNotes = const {};
  final Map<String, _OwnHost> _hosts = {};
  final Set<String> _joiningLive = {};
  final Map<String, int> _liveFailures = {};
  Timer? _liveRetry;

  /// The notes that are open on the screen of this device now. A note that is open on two devices of the profile is worked on live
  /// (with the automatic sync on, as that is what lets the devices know about each other): the device with the lower id hosts a
  /// session, the other joins it. The sessions go over the direct connection between the devices, after both proved who they are.
  void setOpenNotes(Set<String> ids) {
    if (setEquals(ids, _openNotes)) return;
    _openNotes = Set.unmodifiable(ids);
    notifyListeners(); // (the tab of a temporary browser must not be closed while a note is open)
    if (_room != null) _hello(ask: true); // (the others answer with what they have open)
    unawaited(_applyPolicy().then((_) => _evaluateLive()),); // (a note that is open brings the device into the room, the last one closed takes it out)
  }

  final Set<String> _hostingStarting = {};

  /// The device that hosts the session this device joined, by note.
  final Map<String, String> _joinedHost = {};

  /// The devices this device is in a live session with, by note: the host for a guest, the guests that are still connected for the
  /// host. When the session ends, the note counts as agreed with them, and only them.
  final Map<String, Set<String>> _liveWith = {};

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    _updateLeaveGuard();
    super.notifyListeners(); // (work that was under way when the service went away ends quietly)
  }

  @override
  void dispose() {
    _disposed = true;
    _cloud?.removeListener(_cloudChanged);
    _live?.changes.removeListener(_sessionChanged);
    _editorsReady?.cancel();
    _changeTimer?.cancel();
    _offerTimer?.cancel();
    _joinTimer?.cancel();
    stopConnect();
    _tempTimer?.cancel();
    _manualTimer?.cancel();
    _checkTimer?.cancel();
    _checkWindow?.cancel();
    _liveRetry?.cancel();
    _syncRetry?.cancel();
    for (final h in _hosts.values) {
      h.close();
    }
    _hosts.clear();
    _changesSub?.cancel();
    unawaited(_closeRoom());
    super.dispose();
  }
}
