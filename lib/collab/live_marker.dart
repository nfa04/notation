import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../sync/caldav_service.dart' show SecretStore;
import 'invite.dart';
import 'secure_box.dart';
import 'share_storage.dart';

/// What the marker file next to a shared copy says: the owner's app is running, and the invite to a live session
/// on the note: the signalling server and the secret of a room. While the owner is only working on the note, the
/// app waits in that room and starts the session as soon as someone knocks (see [Standby]); during a session it
/// is the invite of the session. It is sealed with a key derived from the secret of the copy's link, so only
/// whoever has that link can read it.
class LiveMarker {
  final bool live;

  /// When the owner last wrote it. A marker that is not renewed (the app was closed, the phone died) goes stale.
  final DateTime at;

  /// The invite link of the live session, when [live].
  final String? link;

  /// When the marker stops counting, written by whoever wrote it: a marker is only good until then, so one left
  /// behind by an app that crashed (or lost its connection) stops working by itself. Renewing moves it on.
  final DateTime? until;

  /// The version of the copy next to the marker (when the owner last put a newer state of the note there, in
  /// milliseconds); null if it is the copy as first shared. Read whether or not the owner is there.
  final int? copy;

  const LiveMarker({required this.live, required this.at, this.link, this.until, this.copy});

  /// The time this marker stops counting: what it says, else [freshFor] after it was written.
  DateTime get expires => until ?? at.add(freshFor);

  /// How old a marker may be and still count as "the owner is there": it is renewed every [LiveMarkers.heartbeat].
  static const freshFor = Duration(minutes: 10);

  bool isFresh(DateTime now) => live && link != null && now.isBefore(expires) && now.isBefore(at.add(freshFor * 3));

  static final _aad = utf8.encode('uninotes-live-marker');

  /// The key the marker is sealed with: its own, derived from the secret of the link.
  static Uint8List markerKey(Uint8List linkKey) => deriveKey(linkKey, 'marker');

  Future<Uint8List> seal(Uint8List key) =>
      SecureBox(markerKey(key)).seal(Uint8List.fromList(utf8.encode(jsonEncode({'live': live, 'at': at.millisecondsSinceEpoch, 'until': (until ?? at.add(freshFor)).millisecondsSinceEpoch, if (link != null) 'link': link, if (copy != null) 'copy': copy}))), aad: _aad);

  /// The marker in [sealed], or null if it does not open with [key] or is no marker.
  static Future<LiveMarker?> open(Uint8List key, Uint8List sealed) async {
    try {
      final m = jsonDecode(utf8.decode(await SecureBox(markerKey(key)).open(sealed, aad: _aad))) as Map;
      return LiveMarker(live: m['live'] == true, at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()), link: m['link'] as String?,
          until: m['until'] is num ? DateTime.fromMillisecondsSinceEpoch((m['until'] as num).toInt()) : null,
          copy: m['copy'] is num ? (m['copy'] as num).toInt() : null);
    } catch (_) {
      return null;
    }
  }
}

/// Where the live sessions of this device are, as far as the markers need to know.
abstract class LiveSource implements Listenable {
  /// The invite link of the live session this device hosts on [noteId]; null if there is none running.
  String? hostedLink(String noteId);
}

/// Keeps the marker files of the copies that were shared: while this device hosts a live session on a note, the
/// marker of each of its copies says so (and is renewed now and then); when the session ends it says that too.
/// So whoever opens the link of a copy while the owner is working on the note is offered to join.
class LiveMarkers extends ChangeNotifier {
  final SecretStore _store;
  final List<ShareStorage> _storages;
  final DateTime Function() _now;

  /// How often the markers are renewed (so that one that is not renewed goes stale, [LiveMarker.freshFor]).
  final Duration heartbeat;

  /// The signalling server and the name for the invites that markers carry; set when the app starts.
  String? Function() serverOf = () => null;
  String Function() nameOf = () => '';

  /// When a note was last edited, and the note as a file: to keep the copies up there up to date. Set when the app
  /// starts; without them the copies stay as they were shared.
  Future<DateTime?> Function(String noteId) editedOf = (_) async => null;
  Future<Uint8List?> Function(String noteId) exportOf = (_) async => null;

  LiveMarkers(this._storages, this._store, {DateTime Function()? now, this.heartbeat = const Duration(minutes: 4)}) : _now = now ?? DateTime.now;

  final List<_Entry> _entries = [];

  /// Whether any shared copy has a marker that is to say "not here" when the app goes.
  bool get hasMarkers => _entries.isNotEmpty;
  final Map<String, String?> _published = {}; // note id -> the link last written (null: "not live")
  LiveSource? _source;
  Timer? _timer;
  Future<void> _chain = Future.value();
  bool _loaded = false;

  /// The problem of the last write, for whoever wants to show it.
  String? lastError;

  Future<void> load() async {
    final text = await _store.read();
    try {
      if (text != null) _entries.addAll([for (final e in jsonDecode(text) as List) _Entry.fromJson((e as Map).cast<String, Object?>())]);
    } catch (_) {
      _entries.clear();
    }
    _loaded = true;
  }

  Future<void> _save() => _entries.isEmpty ? _store.delete() : _store.write(jsonEncode([for (final e in _entries) e.toJson()]));

  /// Starts following the sessions of [source].
  void watch(LiveSource source) {
    _source?.removeListener(_changed);
    _source = source..addListener(_changed);
    _changed(); // the markers say the app is there, and the beat starts (it also retries what did not go up)
  }

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _source?.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  /// The invite of the room in which the app waits for someone who opens a copy of [noteId], made on first use
  /// (null if there is no signalling server to make one for).
  SessionInvite? standbyFor(String noteId, {bool create = false}) {
    final link = _entries.where((e) => e.noteId == noteId && e.invite != null).firstOrNull?.invite;
    if (link != null) return SessionInvite.parse(link);
    final server = serverOf();
    if (!create || server == null) return null;
    final name = nameOf();
    return SessionInvite.create(server, from: name.isEmpty ? null : name);
  }

  /// The notes that have copies, with the invite of their room.
  Map<String, SessionInvite> get standbyInvites => {
        for (final e in _entries)
          if (e.invite != null && SessionInvite.parse(e.invite!) != null) e.noteId: SessionInvite.parse(e.invite!)!,
      };

  /// The notes that have copies out.
  Set<String> get noteIds => {for (final e in _entries) e.noteId};

  /// The keys of the copies that were shared of [noteId]: whoever has one of them may come into its session unasked.
  List<Uint8List> keysFor(String noteId) => [for (final e in _entries) if (e.noteId == noteId) e.key];

  /// Notes that the copy sealed with [key] has an inbox at [ref] on [storage].
  Future<void> setInbox(String noteId, Uint8List key, String ref, ShareStorage storage) async {
    final i = _entries.indexWhere((e) => e.noteId == noteId && listEquals(e.key, key));
    if (i < 0) return;
    _entries[i] = _entries[i].withInbox(ref);
    await _save();
    notifyListeners();
  }

  /// The inboxes to look in: the copy's note, the service, where the inbox is, and the key its files are sealed with.
  List<({String noteId, ShareStorage storage, String ref, Uint8List key})> get inboxes => [
        for (final e in _entries)
          if (e.inbox != null)
            if (_storages.where((s) => s.label == e.storage).firstOrNull case final storage?)
              (noteId: e.noteId, storage: storage, ref: e.inbox!, key: e.key),
      ];

  /// Notes that the copy whose marker is [ref] on [storage] belongs to [noteId], sealed with [key]; writes its first
  /// state. Returns when that is done.
  /// [copyRef] is where the copy itself is, and [copyOf] when the note was last edited as of that copy: it is put up
  /// again when the note changes.
  Future<void> add(String noteId, ShareStorage storage, String ref, Uint8List key, {String? copyRef, DateTime? copyOf}) async {
    if (!_loaded) await load();
    final standby = standbyFor(noteId, create: true);
    _entries.add(_Entry(noteId, storage.label, ref, key, _now(), standby?.toLink(), null, copyRef, copyOf));
    await _save();
    if (!_disposed) notifyListeners();
    _published.remove(noteId);
    await publish(noteId);
    _changed(); // a session that is running already needs its marker renewed
  }

  /// Writes the state of the markers of [noteId] if it is not what they say.
  Future<void> publish(String noteId, {bool force = false}) => _enqueue(() async {
      await _forget();
      final newCopy = await _refreshCopies(noteId);
      // the session that is running, else the room where the app waits for someone to open a copy
      final link = _source?.hostedLink(noteId) ?? standbyFor(noteId)?.toLink();
      if (!force && !newCopy && _published.containsKey(noteId) && _published[noteId] == link) return;
      _published[noteId] = link;
      if (_retired) {
        // (the app is in the background: the markers keep saying so, with the copy that went up meanwhile)
        if (newCopy || _behind.contains(noteId)) await _writeAway(noteId);
        return;
      }
      for (final e in _entries.where((e) => e.noteId == noteId)) {
        final storage = _storages.where((s) => s.label == e.storage).firstOrNull;
        if (storage == null || !storage.available) continue;
        try {
          await storage.replace(e.ref, await LiveMarker(live: link != null, at: _now(), link: link, copy: _versionOf(e)).seal(e.key));
          lastError = null;
        } catch (err) {
          lastError = '$err';
          _published.remove(noteId); // tried again at the next change or beat
        }
      }
    });

  /// Runs [work] after the writes before it. One that fails (no network) does not stop the ones after it: what it
  /// did not do is tried again at the next beat ([heartbeat]) or when the app is back.
  Future<void> _enqueue(Future<void> Function() work) => _chain = _chain.then((_) async {
        try {
          await work();
        } catch (err) {
          lastError = '$err';
        }
      });

  int? _versionOf(_Entry e) => e.copyVersion;

  /// Puts the note up again in place of each of its copies that is older than the note; true if one was.
  Future<bool> _refreshCopies(String noteId) async {
    final entries = [for (var i = 0; i < _entries.length; i++) if (_entries[i].noteId == noteId && _entries[i].copyRef != null) i];
    if (entries.isEmpty) return false;
    final edited = await editedOf(noteId);
    if (edited == null) return false;
    Uint8List? bytes;
    var any = false;
    for (final i in entries) {
      final e = _entries[i];
      if (e.copyOf != null && !edited.isAfter(e.copyOf!)) continue;
      final storage = _storages.where((s) => s.label == e.storage).firstOrNull;
      if (storage == null || !storage.available || !storage.canReplace) continue;
      bytes ??= await exportOf(noteId);
      if (bytes == null) return any;
      try {
        await storage.replace(e.copyRef!, await SecureBox(e.key).seal(bytes));
        // the version only ever goes up, even if the clock goes back
        final version = max(_now().millisecondsSinceEpoch, (e.copyVersion ?? 0) + 1);
        _entries[i] = e.withCopy(edited, version);
        any = true;
      } catch (err) {
        lastError = '$err';
      }
    }
    if (any) await _save();
    return any;
  }

  /// Puts the note up again where it has copies, if it changed since they were put up, and says so in the markers.
  Future<void> refreshCopy(String noteId) => publish(noteId);

  bool _retired = false;

  /// The app goes to the background or closes, where it cannot be reached: the markers of notes without a session
  /// say so right away (best effort: if this does not happen, they run out by themselves).
  Future<void> retire() {
    _retired = true;
    return _enqueue(() async {
      for (final noteId in {for (final e in _entries) e.noteId}) {
        // the note as it is goes up first: whoever has a copy gets it while this device is away
        try {
          await _refreshCopies(noteId);
        } catch (_) {
          // (no connection: it goes up when the app is back)
        }
        if (_source?.hostedLink(noteId) != null) continue; // a session carries on
        _published[noteId] = null;
        await _writeAway(noteId);
      }
    });
  }

  /// Notes whose markers could not be written while the app was away (they are tried again at the next beat).
  final Set<String> _behind = {};

  /// Writes "not here" into the markers of [noteId], with the version of its copy.
  Future<void> _writeAway(String noteId) async {
    _behind.remove(noteId);
    for (final e in _entries.where((e) => e.noteId == noteId)) {
      final storage = _storages.where((s) => s.label == e.storage).firstOrNull;
      if (storage == null || !storage.available) continue;
      try {
        await storage.replace(e.ref, await LiveMarker(live: false, at: _now(), until: _now(), copy: _versionOf(e)).seal(e.key));
      } catch (_) {
        _behind.add(noteId); // (no connection: "not here" is true anyway once it runs out; the copy's version is not)
      }
    }
  }

  /// The app is back: the markers say so again.
  Future<void> resume() async {
    _retired = false;
    for (final noteId in {for (final e in _entries) e.noteId}) {
      await publish(noteId, force: true);
    }
  }

  /// Drops the entries whose copy is gone by now.
  Future<void> _forget() async {
    final before = _entries.length;
    _entries.removeWhere((e) {
      final storage = _storages.where((s) => s.label == e.storage).firstOrNull;
      return storage == null || _now().difference(e.at) > storage.keeps;
    });
    if (_entries.length != before) {
      await _save();
      if (!_disposed) notifyListeners();
    }
  }

  void _changed() {
    final source = _source;
    if (source == null || _disposed) return;
    final notes = {for (final e in _entries) e.noteId};
    for (final n in notes) {
      unawaited(publish(n));
    }
    // while there are copies, the markers are renewed: the app is there
    if (notes.isNotEmpty && _timer == null) {
      _timer = Timer.periodic(heartbeat, (_) {
        final current = {for (final e in _entries) e.noteId};
        if (current.isEmpty) {
          _timer?.cancel();
          _timer = null;
        }
        for (final n in current) {
          unawaited(publish(n, force: true));
        }
      });
    } else if (notes.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Waits until the writes that were started are done (for tests).
  Future<void> get settled => _chain;
}

class _Entry {
  final String noteId, storage, ref;
  final Uint8List key;
  final DateTime at;

  /// The link of the invite to the room where the app waits for someone to open this copy.
  final String? invite;

  /// Where the inbox of this copy is on its service.
  final String? inbox;

  /// Where the copy itself is on its service (null for copies shared before copies were kept up to date).
  final String? copyRef;

  /// When the note was last edited as of the copy that is up there, and that copy's version ([LiveMarker.copy]).
  final DateTime? copyOf;
  final int? copyVersion;

  _Entry(this.noteId, this.storage, this.ref, this.key, this.at, [this.invite, this.inbox, this.copyRef, this.copyOf, this.copyVersion]);

  _Entry withInbox(String ref) => _Entry(noteId, storage, this.ref, key, at, invite, ref, copyRef, copyOf, copyVersion);

  _Entry withCopy(DateTime of, int version) => _Entry(noteId, storage, ref, key, at, invite, inbox, copyRef, of, version);

  Map<String, Object?> toJson() => {
        'note': noteId,
        'storage': storage,
        'ref': ref,
        'key': base64Encode(key),
        'at': at.millisecondsSinceEpoch,
        if (invite != null) 'invite': invite,
        if (inbox != null) 'inbox': inbox,
        if (copyRef != null) 'copy': copyRef,
        if (copyOf != null) 'copyOf': copyOf!.millisecondsSinceEpoch,
        if (copyVersion != null) 'copyVersion': copyVersion,
      };

  static _Entry fromJson(Map<String, Object?> m) => _Entry(m['note'] as String, m['storage'] as String, m['ref'] as String, base64Decode(m['key'] as String),
      DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()), m['invite'] as String?, m['inbox'] as String?, m['copy'] as String?,
      m['copyOf'] is num ? DateTime.fromMillisecondsSinceEpoch((m['copyOf'] as num).toInt()) : null, m['copyVersion'] is num ? (m['copyVersion'] as num).toInt() : null);
}
