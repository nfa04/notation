import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext, Widget;

import '../data/settings_repository.dart';
import '../devicesync/device_sync_service.dart';
import '../devicesync/sync_keys.dart' show SyncSecret;
import '../l10n/language.dart';
import 'caching_folder.dart';
import 'cloud_folder.dart';
import 'cloud_sign_in.dart';
import 'folder_sync.dart';

/// A service the library can be synced through: whether an account is connected on this device, and its folder.
class CloudProvider {
  final String id;
  final String label;
  final bool Function() available;
  final CloudFolder Function(String folderName) folderFor;

  /// Told when the account is connected or removed.
  final Listenable changes;

  /// What connects the account (its login), for the screen that signs in to a profile on a device that has no account yet.
  final Widget Function(BuildContext context)? setup;

  const CloudProvider({required this.id, required this.label, required this.available, required this.folderFor, required this.changes,
    this.setup,});
}

/// The sync of the library through a folder on cloud storage (see [FolderSync]), for devices that are not online at the same time.
/// What the person chose - whether it is on, which service, the name of the folder and whether the files are sealed - is a setting of
/// the profile, so it reaches the other devices with the rest; the account itself is handed over when two devices sync directly.
class CloudSyncService extends ChangeNotifier {
  static const kOn = 'sync_cloud_on';
  static const kProvider = 'sync_cloud_provider';
  static const kMode = 'sync_cloud_mode';
  static const kFolder = 'sync_cloud_folder';
  static const _kLast = 'sync_cloud_last';

  /// What the last run that went well saw of the folder (see [_lastSeen]); not a setting that travels.
  static const _kSeen = 'sync_cloud_seen';

  static const defaultFolder = 'Notation Sync';

  final SettingsRepository _settings;
  final DeviceSyncService _devices;
  final List<CloudProvider> providers;

  /// How often it runs by itself, how long after a change, and how soon after the app comes to the front.
  final Duration every, afterChange, afterWake;

  /// How long a run waits at most for a direct sync to end (one that hangs must not stop the folder from syncing), and how often
  /// it looks again meanwhile.
  final Duration maxWaitForDirect, retryWhileWaiting;

  /// How long what a run saw of the other devices' directories counts: a quick run (the timer, a change here) reads the manifest of a
  /// device only when the stamp of its directory changed, and after this every device is read again whatever the stamps say (a safety
  /// net for a service whose stamps are wrong). What was read of the folder is kept for no longer than this either (see [CachingFolder]).
  final Duration lookEvery;

  /// The waits between tries when the service is busy or the connection drops (see `RetryingFolder`).
  final List<Duration> retryDelays;

  CloudSyncService(
    this._settings,
    this._devices,
    this.providers, {
    Stream<String>? changes,
    this.every = const Duration(minutes: 3),
    this.afterChange = const Duration(seconds: 30),
    this.afterWake = const Duration(minutes: 2),
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 4), Duration(seconds: 10)],
    this.maxWaitForDirect = const Duration(minutes: 2),
    this.retryWhileWaiting = const Duration(seconds: 20),
    this.lookEvery = const Duration(minutes: 10),
  }) {
    for (final p in providers) {
      p.changes.addListener(notifyListeners);
    }
    _devices.addListener(_devicesChanged);
    _changesSub = changes?.listen((id) {
      if (!_devices.library.isApplying(id)) _localChanged();
    });
  }

  /// Signing in to the profile with the cloud folder and a recovery key, instead of a link (see [CloudSignIn]).
  late final CloudSignIn signIn = CloudSignIn(_settings, _devices, this);

  StreamSubscription<String>? _changesSub;
  bool _on = false;
  String? _providerId;
  bool _encrypted = true;
  String _folder = defaultFolder;
  DateTime? _last;
  bool _running = false;
  String? _problem;
  String? _what;
  Timer? _timer, _changeTimer;
  bool _disposed = false;


  /// The folder of the chosen service, when the sync is on and the service has an account on this device.
  CloudFolder? get folderNow {
    final p = provider;
    return _on && p != null && p.available() ? RetryingFolder(p.folderFor(_folder), delays: retryDelays) : null;
  }

  bool get enabled => _on;

  /// The key the files are sealed with (from the secret of the profile).
  Uint8List? get key => _devices.profileSecret?.cloudKey;

  String? get providerId => _providerId;
  bool get encrypted => _encrypted;
  String get folderName => _folder;
  bool get running => _running;
  DateTime? get lastRun => _last;
  String? get problem => _problem;

  /// What the last run did, for the screen.
  String? get what => _what;

  /// Whether the profile has been set up (a cloud folder is for the devices of a profile).
  bool get possible => _devices.isSetUp;

  CloudProvider? get provider => providers.where((p) => p.id == _providerId).firstOrNull;

  /// The services with an account on this device.
  List<CloudProvider> get usable => [for (final p in providers) if (p.available()) p];

  /// Reads the choices (also after a sync with another device may have changed them).
  Future<void> load() async {
    final before = '$_on/$_providerId/$_folder';
    _on = (await _settings.get(kOn)) == '1';
    _providerId = await _settings.get(kProvider);
    _encrypted = (await _settings.get(kMode)) != 'plain';
    final folder = (await _settings.get(kFolder))?.trim();
    _folder = folder == null || folder.isEmpty ? defaultFolder : folder;
    final last = int.tryParse(await _settings.get(_kLast) ?? '');
    _last = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    await signIn.load();
    if (_disposed) return; // (the app closed while the choices were read)
    if ('$_on/$_providerId/$_folder' != before) _firstRunDone = false; // (another device moved the sync somewhere else: a run there soon)
    _schedule();
    notifyListeners();
    _firstRun();
  }

  bool _firstRunDone = false;

  void _devicesChanged() {
    if (_disposed) return;
    notifyListeners();
    _firstRun();
  }

  /// A run soon after the app started (or after the sync was switched on by another device): the profile may be loaded a moment after
  /// the choices are, so this is asked again when the devices change, until it could be made.
  void _firstRun() {
    if (_firstRunDone || !_on || _disposed || _devices.profileSecret == null || _devices.deviceId == null || provider?.available() != true) return;
    _firstRunDone = true;
    unawaited(syncNow());
  }

  // ---- the choices

  /// The runs that tell the other devices, in the place they still use, that a choice changed (they are settings of the profile, and
  /// the folder is where devices that are not online together learn of them): one after the other, each after the run under way.
  /// They go on in the background: a switch or a name changes at once, however slow the service is.
  Future<void> _telling = Future.value();

  void _tell(String? providerId, String folder) {
    final p = providers.where((p) => p.id == providerId).firstOrNull;
    if (p == null || !p.available() || _disposed) return;
    _telling = _telling.then((_) async {
      await _settled();
      if (!_disposed) await _runAt(p, folder);
    });
  }

  /// Waits for the run under way, if any.
  Future<void> _settled() async {
    while (_current != null) {
      await _current;
    }
  }

  /// Done when the runs under way and those that tell of a change are over (for tests, and before the app closes).
  Future<void> get idle async {
    await _telling;
    await _settled();
  }

  Future<void> setEnabled(bool on) async {
    if (on == _on) return;
    if (on) await _devices.ensureProfile();
    await _settings.set(kOn, on ? '1' : '0');
    final (wasProvider, wasFolder) = (_providerId, _folder);
    _on = on;
    if (on && _providerId == null && usable.isNotEmpty) {
      _providerId = usable.first.id;
      await _settings.set(kProvider, _providerId!);
    }
    _schedule();
    notifyListeners();
    if (on) {
      unawaited(syncNow());
    } else {
      _changeTimer?.cancel();
      _tell(wasProvider, wasFolder); // (the others are told it is off, in the folder they are using)
    }
  }

  Future<void> setProvider(String id) async {
    if (id == _providerId) return;
    await _settings.set(kProvider, id);
    final (wasProvider, wasFolder) = (_providerId, _folder);
    _providerId = id;
    notifyListeners();
    if (_on) _moved(wasProvider, wasFolder);
  }

  Future<void> setEncrypted(bool value) async {
    if (value == _encrypted) return;
    _encrypted = value;
    await _settings.set(kMode, value ? 'enc' : 'plain');
    notifyListeners();
    if (_on) unawaited(syncNow());
  }

  Future<void> setFolderName(String name) async {
    final n = name.trim().replaceAll(RegExp(r'[\\/]+'), ' ').trim();
    if (n.isEmpty || n == _folder) return;
    await _settings.set(kFolder, n);
    final (wasProvider, wasFolder) = (_providerId, _folder);
    _folder = n;
    notifyListeners();
    if (_on) _moved(wasProvider, wasFolder);
  }

  /// The sync moved to another place: the others are told in the old one, then everything goes to the new one.
  void _moved(String? wasProvider, String wasFolder) {
    _tell(wasProvider, wasFolder);
    _telling = _telling.then((_) => _disposed || !_on ? null : syncNow());
  }

  // ---- running

  void _schedule() {
    if (!_on) _firstRunDone = false; // (switched on again later: a run soon)
    _timer?.cancel();
    _timer = null;
    if (_on && !_disposed) _timer = Timer.periodic(every, (_) => unawaited(syncNow(quick: true)));
  }

  /// Something changed here while a run was on (it may have gone past that note already): another run follows.
  bool _dirty = false;

  void _localChanged() {
    if (!_on || _disposed) return;
    if (_running) _dirty = true;
    _changeTimer?.cancel();
    _changeTimer = Timer(afterChange, () => unawaited(syncNow(quick: true)));
  }

  /// The app came back to the front: a run if the last one was a while ago.
  void wake() {
    if (_on && (_last == null || DateTime.now().difference(_last!) > afterWake)) unawaited(syncNow(quick: true));
  }

  final Set<String> _refreshing = {};

  /// Since when a run has been waiting for a direct sync to end.
  DateTime? _waitingSince;

  /// A note was opened: a look whether another device put a newer copy of it in the folder, taken in if so (see `FolderSync.pullNote`).
  /// True if the note was replaced. Cheap and quiet: nothing is shown. A full run that is on leaves open notes alone, so the look
  /// waits for it to end (the app just started or came back online: just when another device may have changed the note).
  Future<bool> refreshNote(String noteId, {bool Function()? allow}) async {
    if (_refreshing.contains(noteId)) return false;
    _refreshing.add(noteId);
    try {
      while (_running && !_disposed) {
        await (_current ?? Future<void>.value());
      }
      final secret = _devices.profileSecret, id = _devices.deviceId, p = provider;
      if (!_on || _disposed || secret == null || id == null || p == null || !p.available()) return false;
      return await _folderSync(p, _folder, secret, id).pullNote(noteId, allow: allow);
    } catch (e) {
      debugPrint('[cloud] could not look for a newer copy of $noteId: $e');
      return false;
    } finally {
      _refreshing.remove(noteId);
    }
  }

  /// Takes in what the other devices put in the folder and puts what changed here there. With [quick] (the runs nobody asked for) the
  /// manifest of a device whose directory did not change since the last run is not read again; without it everything is read, as
  /// a person who presses "Sync now" expects.
  Future<void> syncNow({bool quick = false}) async {
    if (_running || !_on || _disposed) return;
    final secret = _devices.profileSecret, id = _devices.deviceId;
    final p = provider;
    if (secret == null || id == null) {
      _problem = tr('This device is not part of a sync profile yet, so there is nothing to sync through the folder.');
      notifyListeners();
      return;
    }
    if (p == null || !p.available()) {
      _problem = tr('No account for the chosen service on this device yet: connect it in the Settings, or let it come from your other device when they sync directly.');
      notifyListeners();
      return;
    }
    if (_devices.activeSyncs > 0) {
      // a direct sync is under way: this one waits for it, but not for ever - one that hangs must not stop the folder from syncing
      _waitingSince ??= DateTime.now();
      if (DateTime.now().difference(_waitingSince!) < maxWaitForDirect) {
        _what = tr('Waiting for the direct sync with your other device to end...');
        notifyListeners();
        _changeTimer?.cancel();
        _changeTimer = Timer(retryWhileWaiting, () => unawaited(syncNow()));
        return;
      }
      debugPrint('[cloud] a direct sync has been under way for ${DateTime.now().difference(_waitingSince!)}: syncing through the folder anyway');
    }
    _waitingSince = null;
    await _runAt(p, _folder, quick: quick);
  }

  /// What was read of each folder, kept from run to run (see [CachingFolder]); the folder under it is opened again each time, as the
  /// account may have changed.
  final Map<String, CachingFolder> _caches = {};

  CachingFolder _cacheFor(CloudProvider p, String folderName) {
    final fresh = RetryingFolder(p.folderFor(folderName), delays: retryDelays);
    return _caches.putIfAbsent('${p.id}/$folderName', () => CachingFolder(fresh, maxAge: lookEvery))..inner = fresh;
  }

  FolderSync _folderSync(CloudProvider p, String folderName, SyncSecret secret, String deviceId) => FolderSync(
        folder: _cacheFor(p, folderName),
        library: _devices.library,
        book: _devices.book,
        settings: _settings,
        deviceId: deviceId,
        deviceName: _devices.deviceName,
        key: secret.cloudKey,
        encrypted: _encrypted,
        place: '${p.id}/$folderName',
      );

  /// The run under way (null when there is none).
  Future<void>? _current;

  /// One run of the sync with the folder [folderName] of [p].
  Future<void> _runAt(CloudProvider p, String folderName, {bool quick = false}) async {
    final secret = _devices.profileSecret, id = _devices.deviceId;
    if (secret == null || id == null || _running || _disposed) return;
    final done = Completer<void>();
    _current = done.future;
    _running = true;
    _problem = null;
    _what = tr('Syncing through {service}...', {'service': p.label});
    notifyListeners();
    try {
      final sync = _folderSync(p, folderName, secret, id);
      if (!quick) _cacheFor(p, folderName).invalidate(); // (a person who asked for the run gets what is up there now)
      if (signIn.enabled) {
        // devices that signed in with the recovery key since the last run join the list first, so that this run reads them too
        try {
          await signIn.admit(sync.folder);
        } catch (e) {
          debugPrint('[cloud] could not look for devices that signed in: $e');
        }
      }
      // what the directories of the other devices look like before anything is read (a change after this shows at the next look)
      final peers = [for (final d in _devices.book.active) if (d.id != id) d.id];
      final stamps = peers.isEmpty ? null : await _stamps(sync.folder);
      final where = '${_encrypted ? 'enc' : 'plain'}@${p.id}/$folderName';
      final now = stamps == null ? null : {for (final peer in peers) peer: _stampOf(sync, stamps, peer)};
      final seen = quick && now != null ? await _lastSeen(where) : null;
      final unchanged = {for (final peer in peers) if (seen != null && seen.dirs[peer] == now![peer]) peer};
      final busyBefore = _devices.library.busy().isNotEmpty;
      final result = await sync.run(unchanged: unchanged);
      // kept only after a run that left nothing for later: with a note open (the run leaves it alone and takes it when it is closed),
      // a problem or a file that was not up there yet, the next run looks at everything
      if (now != null && result.ok && sync.complete && !busyBefore && _devices.library.busy().isEmpty) {
        await _settings.set(_kSeen, jsonEncode({'w': where, 'at': unchanged.isEmpty || seen == null ? DateTime.now().millisecondsSinceEpoch : seen.at, 'dirs': now}));
      } else if (await _settings.get(_kSeen) != null) {
        await _settings.set(_kSeen, '');
      }
      _last = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch); // (as it is kept: read back, it is the same)
      await _settings.set(_kLast, '${_last!.millisecondsSinceEpoch}');
      _problem = result.ok ? null : result.problems.join('\n');
      _what = trCount(result.taken, 'One change taken in', '{n} changes taken in');
      if (result.taken > 0) _devices.onSettingsChanged?.call();
    } catch (e) {
      _problem = '$e'.replaceFirst('Bad state: ', '');
      _what = null;
    } finally {
      _running = false;
      _current = null;
      done.complete();
      if (!_disposed) notifyListeners();
      if (_dirty && _on && !_disposed) {
        _dirty = false;
        _changeTimer?.cancel();
        _changeTimer = Timer(const Duration(seconds: 5), () => unawaited(syncNow(quick: true)));
      }
    }
  }

  // ---- the quick way: ask what changed before reading anything

  /// The stamps of the folder (one request), or null when the service cannot say or the request did not work (the run then tells what
  /// is wrong).
  Future<Map<String, String>?> _stamps(CloudFolder folder) async {
    try {
      return await folder.stamps('');
    } on CloudAccountMissing {
      rethrow;
    } catch (e) {
      debugPrint('[cloud] no stamps: $e');
      return null;
    }
  }

  /// The stamp of what the device [id] published: its directory in either kind of files ('-': there is none).
  String _stampOf(FolderSync sync, Map<String, String> stamps, String id) =>
      '${stamps[sync.dirOf(id, encrypted: true)] ?? '-'}|${stamps[sync.dirOf(id, encrypted: false)] ?? '-'}';

  /// What the last run that went well saw, as long as it was for this folder and still counts.
  Future<({int at, Map<String, String> dirs})?> _lastSeen(String where) async {
    try {
      final text = await _settings.get(_kSeen);
      if (text == null || text.isEmpty) return null;
      final j = jsonDecode(text) as Map;
      final at = j['at'] as int;
      if (j['w'] != where || DateTime.now().millisecondsSinceEpoch - at >= lookEvery.inMilliseconds) return null;
      return (at: at, dirs: {for (final e in (j['dirs'] as Map).entries) e.key as String: e.value as String});
    } catch (_) {
      return null;
    }
  }

  // ---- signing in

  /// The name of the device [id] of the profile, for the screen.
  String nameOfDevice(String id) => _devices.book.find(id)?.name ?? id;

  /// Signs this device in to the profile whose recovery key is [keyText], through the folder [folderName] of [provider] (the account
  /// must be connected on this device): takes over the profile, then makes the usual sync through the folder run. Throws with words
  /// for the person when the folder holds nothing to sign in to or the key is wrong; nothing is changed then.
  Future<void> signInWith(
    CloudProvider provider,
    String folderName,
    String keyText,
  ) async {
    if (_devices.isSetUp) {
      throw StateError(
        tr(
          'This device is part of a profile already. Leave it first to sign in to another.',
        ),
      );
    }
    if (!provider.available()) {
      throw StateError(
        tr('Connect the account of {service} first.', {
          'service': provider.label,
        }),
      );
    }
    final name = folderName.trim().replaceAll(RegExp(r'[\\/]+'), ' ').trim();
    final folderChoice = name.isEmpty ? defaultFolder : name;
    await signIn.signIn(
      RetryingFolder(provider.folderFor(folderChoice), delays: retryDelays),
      keyText,
    );
    final secret = _devices.profileSecret!, id = _devices.deviceId!;
    try {
      // who else is in (and who was taken out), before anything is read from the other devices' files
      await CloudSignIn.learnRemovals(
        _folderSync(provider, folderChoice, secret, id),
        _devices.book,
      );
    } catch (e) {
      debugPrint(
        '[cloud] could not read the lists of devices after signing in: $e',
      );
    }
    await _settings.set(kOn, '1');
    await _settings.set(kProvider, provider.id);
    await _settings.set(kMode, 'enc');
    await _settings.set(kFolder, folderChoice);
    await load(); // (switches the sync on: the first run follows)
    _devices.refreshPeers();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _changeTimer?.cancel();
    _changesSub?.cancel();
    _devices.removeListener(_devicesChanged);
    for (final p in providers) {
      p.changes.removeListener(notifyListeners);
    }
    super.dispose();
  }
}
