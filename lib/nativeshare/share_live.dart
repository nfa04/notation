import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../collab/invite.dart';
import '../collab/transport.dart';
import '../collab/webrtc_transport.dart' show defaultIceServers;
import '../devicesync/live_notes.dart';
import '../devicesync/peer_linker.dart';
import '../devicesync/sync_devices.dart';
import '../devicesync/sync_keys.dart';
import '../devicesync/sync_library.dart';
import '../devicesync/sync_room.dart';
import '../devicesync/sync_session.dart';
import '../l10n/language.dart';

typedef ShareRoomOpener = Future<SyncRoom> Function(String server, SyncSecret secret);
typedef ShareLinkerFactory = PeerLinker Function(SyncRoom room, String me);

/// Working on one note live with the other people of a share: the same thing the devices of one person do (see
/// `device_sync_live.dart`), with the people who may write in the share in place of the devices of the profile.
///
/// The devices that have a note of the share open meet in a room on the signalling server that is named by a secret of the share (it is in
/// the share's folder, so only people it is shared with can find it); of those, the one with the lowest id hosts a session on the note and
/// the others join it, over a direct connection on which both proved who they are. **Who may take part** is the list of devices in
/// [participants]: the ones that wrote their file in the shared folder - those who may write, with their public keys. A device that is not
/// on it (someone who may only view, who can read the secret too) is turned away by the proof, as a device that is not paired is.
///
/// Only notes that this device has open and that are part of the share are told to the others. A note that has a live session of another
/// kind on this device (one with the person's own devices, or with a link) is left to that one.
class ShareLive {
  static const maxOpenNotes = 12;

  final String shareId;
  final SyncSecret secret;
  final String? Function() serverOf;
  final DeviceIdentity identity;
  final String deviceName;
  final LiveNotes live;
  final SyncLibrary library;

  /// The people who may write in the share, with their keys (read from the shared folder).
  final Future<List<PairedDevice>> Function() participants;

  /// Told when a session this device hosted ended with the others gone, so that what was worked on is saved up (the share is synced).
  final void Function(String noteId)? onPublish;

  final ShareRoomOpener openRoom;
  final ShareLinkerFactory makeLinker;
  final Duration heartbeat, offlineAfter, rollCallWait, refreshBookEvery;

  ShareLive({
    required this.shareId,
    required this.secret,
    required this.serverOf,
    required this.identity,
    required this.deviceName,
    required this.live,
    required this.library,
    required this.participants,
    this.onPublish,
    ShareRoomOpener? openRoom,
    ShareLinkerFactory? makeLinker,
    List<Map<String, Object>> Function()? iceServers,
    this.heartbeat = const Duration(seconds: 45),
    this.offlineAfter = const Duration(seconds: 130),
    this.rollCallWait = const Duration(seconds: 5),
    this.refreshBookEvery = const Duration(minutes: 2),
  })  : openRoom = openRoom ??
            ((server, secret) async {
              final room = ServerSyncRoom(server, secret);
              await room.connect();
              return room;
            }),
        makeLinker = makeLinker ?? ((room, me) => WebRtcLinker(room, me, iceServers: iceServers?.call() ?? defaultIceServers)) {
    live.changes.addListener(_sessionChanged);
    _editorsReady = live.editorsReady.listen((note) {
      if (_open.contains(note)) unawaited(_evaluate());
    });
  }

  /// The people who may write, as the room lets this device know them (in memory only).
  final _store = <String, String>{};
  late final DeviceBook book = DeviceBook((k) async => _store[k], (k, v) async => _store[k] = v);

  final _peers = <String, _Peer>{};
  Set<String> _open = const {};
  SyncRoom? _room;
  PeerLinker? _linker;
  StreamSubscription<Map<String, Object?>>? _roomSub;
  StreamSubscription<PeerChannel>? _incomingSub;
  StreamSubscription<bool>? _connectionSub;
  StreamSubscription<String>? _editorsReady;
  Timer? _beat, _rollCall, _liveRetry, _reopen;
  bool _opening = false, _disposed = false;
  DateTime? _bookRead;

  final _hosts = <String, _ShareHost>{};
  final _joinedHost = <String, String>{};
  final _joining = <String>{};
  final _hostingStarting = <String>{};
  final _failures = <String, int>{};
  final _liveWith = <String, Set<String>>{};
  final _lastStatus = <String, ({bool host, int people, bool ended})>{};

  /// Whether this device is in the room now.
  bool get inRoom => _room?.connected ?? false;

  /// The notes of the share that are open on this device and told to the others.
  Set<String> get announced => {
        for (final n in _open)
          if (!_foreign(n)) n,
      };

  /// The note has a session that this component did not start.
  bool _foreign(String note) =>
      live.hasSession(note) && !_hosts.containsKey(note) && !_joinedHost.containsKey(note) && !_hostingStarting.contains(note) && !_joining.contains(note);

  /// The notes of the share that are open on the screen of this device now: with any, the device is in the room, with none it is not.
  void setOpen(Set<String> notes) {
    if (_disposed || setEquals(notes, _open)) return;
    _open = Set.unmodifiable(notes);
    if (_room != null) _hello(ask: true);
    unawaited(_applyPolicy().then((_) => _evaluate()));
  }

  Future<void> _applyPolicy() async {
    if (_disposed) return;
    if (_open.isEmpty) {
      await _closeRoom();
    } else if (_room == null && !_opening) {
      await _openRoomNow();
    }
  }

  Future<void> _openRoomNow() async {
    final server = serverOf();
    if (server == null || server.isEmpty) return;
    _opening = true;
    try {
      final room = await openRoom(server, secret);
      if (_disposed || _open.isEmpty) {
        await room.close();
        return;
      }
      _room = room;
      _linker = makeLinker(room, identity.id);
      _roomSub = room.messages.listen(_onRoom);
      _incomingSub = _linker!.incoming.listen((c) => unawaited(_meetIncoming(c)));
      var wasUp = true;
      _connectionSub = room.connection.listen((up) {
        if (up) {
          _hello(ask: !wasUp);
          if (!wasUp) {
            _failures.clear();
            live.wake();
            unawaited(_evaluate());
          }
        } else {
          for (final p in _peers.values) {
            p.online = false;
          }
        }
        wasUp = up;
      });
      _hello();
      _beat = Timer.periodic(heartbeat, (_) {
        _hello();
        _expire();
      });
      unawaited(_refreshBook(force: true).then((_) => _evaluate()));
    } catch (e) {
      debugPrint('[sharelive] could not come into the room: $e');
      _reopen?.cancel();
      _reopen = Timer(const Duration(seconds: 30), () => unawaited(_applyPolicy()));
    } finally {
      _opening = false;
    }
  }

  Future<void> _closeRoom() async {
    _beat?.cancel();
    _rollCall?.cancel();
    _reopen?.cancel();
    final room = _room;
    if (room != null && room.connected) {
      try {
        await room.send({'t': 'gone', 'd': identity.id});
      } catch (_) {
        // going away anyway
      }
    }
    _room = null;
    await _roomSub?.cancel();
    await _incomingSub?.cancel();
    await _connectionSub?.cancel();
    await _linker?.close();
    _linker = null;
    await room?.close();
    for (final p in _peers.values) {
      p.online = false;
    }
    // (nothing is worked on live without the room: a session that was hosted or followed here ends with it)
    for (final note in {..._hosts.keys, ..._joinedHost.keys}) {
      await _leave(note);
    }
  }

  // ---- who writes

  /// Reads the list of those who may write again (not more often than [refreshBookEvery], unless [force]).
  Future<void> _refreshBook({bool force = false}) async {
    final last = _bookRead;
    if (!force && last != null && DateTime.now().difference(last) < refreshBookEvery) return;
    _bookRead = DateTime.now();
    try {
      final list = await participants();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final d in list) {
        if (d.id == identity.id) continue;
        final known = book.find(d.id);
        if (known == null || !listEquals(known.publicKey, d.publicKey)) {
          await book.add(PairedDevice(id: d.id, name: d.name, publicKey: d.publicKey, addedAt: now));
        }
      }
      for (final d in book.active) {
        if (!list.any((x) => x.id == d.id)) await book.remove(d.id, now + 1);
      }
    } catch (e) {
      debugPrint('[sharelive] could not read who takes part: $e');
    }
  }

  // ---- the room

  void _hello({bool ask = false}) {
    final open = announced;
    _room?.send({'t': 'here', 'd': identity.id, 'n': deviceName, if (ask) 'q': true, if (open.isNotEmpty) 'o': open.take(maxOpenNotes).toList()});
  }

  void _onRoom(Map<String, Object?> m) {
    switch (m['t']) {
      case 'here':
        final peer = m['d'] as String?;
        if (peer == null || peer == identity.id) return;
        if (!_peers.containsKey(peer) && _peers.length >= 64) return;
        final state = _peers.putIfAbsent(peer, () => _Peer(peer));
        final wasOnline = state.online;
        state.online = true;
        state.seen = DateTime.now();
        final open = m['o'] is List ? {for (final id in (m['o'] as List).take(maxOpenNotes)) if (id is String) id} : <String>{};
        final changed = !setEquals(open, state.open);
        state.open = open;
        if (!wasOnline || m['q'] == true) _hello();
        if (book.find(peer) == null) {
          // (someone new who writes, perhaps: the list is read again)
          unawaited(_refreshBook().then((_) => _evaluate()));
        } else if (changed || !wasOnline || m['q'] == true) {
          unawaited(_evaluate());
        }
      case 'gone':
        final peer = m['d'] as String?;
        if (peer != null && _peers[peer] != null) {
          _peers[peer]!.online = false;
          unawaited(_evaluate());
        }
      case 'left':
        _callRoll();
    }
  }

  /// A device may have gone without a word: everybody is asked to say it is here, and one that does not within [rollCallWait] is gone.
  void _callRoll() {
    if (_rollCall?.isActive ?? false) return;
    final room = _room;
    if (room == null || !room.connected) return;
    final since = DateTime.now();
    _hello(ask: true);
    _rollCall = Timer(rollCallWait, () {
      if (!identical(room, _room) || !room.connected) return;
      var changed = false;
      for (final p in _peers.values) {
        if (p.online && (p.seen == null || p.seen!.isBefore(since))) {
          p.online = false;
          changed = true;
        }
      }
      if (changed) unawaited(_evaluate());
    });
  }

  void _expire() {
    final now = DateTime.now();
    var changed = false;
    for (final p in _peers.values) {
      if (p.online && p.seen != null && now.difference(p.seen!) > offlineAfter) {
        p.online = false;
        changed = true;
      }
    }
    if (changed) unawaited(_evaluate());
  }

  // ---- hosting and joining

  Future<void> _evaluate() async {
    if (_disposed) return;
    final me = identity.id;
    // a note that is closed here is not worked on live any more
    for (final note in {..._hosts.keys, ..._joinedHost.keys}) {
      if (!announced.contains(note) && !_hostingStarting.contains(note) && !_joining.contains(note)) await _leave(note);
    }
    for (final e in _hosts.entries.toList()) {
      if (!live.hasSession(e.key) && !_hostingStarting.contains(e.key)) _hosts.remove(e.key)?.close();
    }
    _joinedHost.removeWhere((note, _) => !live.hasSession(note));
    if (!(_room?.connected ?? false)) return;
    for (final note in announced) {
      final others = [for (final p in _peers.values) if (p.online && p.open.contains(note) && book.find(p.id) != null) p.id];
      if (others.isEmpty) continue; // (alone with it: a session hosted here stays, for whoever opens the note next)
      final host = ([me, ...others]..sort()).first;
      if (host == me) {
        if (_joinedHost.containsKey(note)) await _leave(note);
        await _host(note);
      } else {
        if (_hosts.containsKey(note) || (_joinedHost.containsKey(note) && _joinedHost[note] != host)) await _leave(note);
        unawaited(_join(note, host));
      }
    }
  }

  Future<void> _leave(String note) async {
    _joinedHost.remove(note);
    _hosts.remove(note)?.close();
    await live.end(note);
  }

  Future<void> _host(String note) async {
    if (_hosts.containsKey(note) || live.hasSession(note) || !_hostingStarting.add(note)) return;
    try {
      final host = _ShareHost(SessionInvite.create(serverOf() ?? ''));
      if (await live.host(note, host.invite, host.transport)) {
        _hosts[note] = host;
        _liveWith[note] = {};
      } else {
        host.close();
      }
    } catch (e) {
      debugPrint('[sharelive] could not host $note: $e');
    } finally {
      _hostingStarting.remove(note);
    }
  }

  /// The secret of the session this device hosts on [note], for a device that asks for it (and is on the list).
  Future<Uint8List?> _secretFor(String note, String peer) async {
    if (!announced.contains(note) || book.find(peer) == null) return null;
    final host = _hosts[note];
    if (host == null || !live.hasSession(note)) return null;
    return host.invite.secret;
  }

  SyncSession _session(PeerChannel channel, String roomName, {String? liveNote, bool serving = false}) => SyncSession(
        channel: channel,
        secret: secret,
        roomName: roomName,
        identity: identity,
        deviceName: deviceName,
        book: book,
        profile: _ShareProfile(shareId, deviceName),
        library: library,
        liveNote: liveNote,
        liveSecretFor: serving ? _secretFor : null,
        syncsLibrary: false, // (the libraries are never brought together over this line: only a live session on one note)
      );

  /// A device that connected to this one asks to work on a note live: it is a guest if it proves who it is.
  Future<void> _meetIncoming(PeerChannel channel) async {
    final room = _room;
    if (room == null) {
      await channel.close();
      return;
    }
    final outcome = await _session(channel, room.name, serving: true).run();
    final link = outcome.live;
    if (link == null) return;
    final host = _hosts[link.noteId];
    if (host == null || !live.hasSession(link.noteId)) {
      unawaited(link.channel.close());
      return;
    }
    host.accept(link.channel);
    final with_ = _liveWith.putIfAbsent(link.noteId, () => {})..add(link.peerId);
    unawaited(link.channel.closed.then((_) {
      if (!(live.status(link.noteId)?.ended ?? true)) with_.remove(link.peerId);
    }));
  }

  Future<LiveLink> _connect(String peer, String note) async {
    final linker = _linker, room = _room;
    if (linker == null || room == null || book.find(peer) == null) throw StateError(tr('The other person is not reachable now'));
    final channel = await linker.connect(peer);
    final outcome = await _session(channel, room.name, liveNote: note).run();
    final link = outcome.live;
    if (link == null) throw StateError(outcome.problem ?? tr('The other device did not follow the protocol'));
    return link;
  }

  Future<void> _join(String note, String hostId) async {
    if (live.hasSession(note) || !_joining.add(note)) return;
    try {
      final first = await _connect(hostId, note);
      final transport = _ShareJoin(first, () => _connect(hostId, note));
      final ok = await live.join(note, SessionInvite(serverOf() ?? '', first.secret), transport);
      if (ok) {
        _joinedHost[note] = hostId;
        _liveWith[note] = {hostId};
        _failures.remove(note);
      } else {
        _failed(note);
      }
    } catch (e) {
      debugPrint('[sharelive] could not join $note: $e');
      _failed(note);
    } finally {
      _joining.remove(note);
    }
  }

  void _failed(String note) {
    _room?.check();
    _callRoll();
    final n = _failures[note] = (_failures[note] ?? 0) + 1;
    if (n > 5 || _disposed) return;
    _liveRetry?.cancel();
    _liveRetry = Timer(Duration(seconds: 3 * n), () => unawaited(_evaluate()));
  }

  /// A session changed: when the host is left alone the note is saved and the share is synced (the people who were in it have it
  /// already, the others get it); when it is over for this device, what the people had counts as agreed, so that the copies that follow -
  /// each one saved the note at its own moment - are not taken for changes made on both sides.
  void _sessionChanged() {
    if (_disposed) return;
    for (final note in {..._lastStatus.keys, ..._open, ..._hosts.keys, ..._joinedHost.keys}) {
      final st = live.status(note);
      if (st == null) continue;
      final prev = _lastStatus[note];
      _lastStatus[note] = st;
      final ours = _hosts.containsKey(note) || _joinedHost.containsKey(note) || prev != null;
      if (!ours) continue;
      if (prev != null && prev.host && st.host && prev.people > 1 && (st.people <= 1 || st.ended)) {
        unawaited(live.saveNote(note).then((_) => onPublish?.call(note)).catchError((Object _) {}));
      }
      if (prev != null && !prev.ended && st.ended) {
        unawaited(library.markNoteAgreed(note, _liveWith.remove(note) ?? const {}));
        unawaited(Future<void>.delayed(Duration.zero, _evaluate));
      }
    }
  }

  /// The app is back in front: the connection to the room is made again, and a guest that lost its host tries now.
  void wake() {
    _room?.wake();
    live.wake();
  }

  Future<void> dispose() async {
    _disposed = true;
    live.changes.removeListener(_sessionChanged);
    await _editorsReady?.cancel();
    _liveRetry?.cancel();
    _reopen?.cancel();
    for (final h in _hosts.values) {
      h.close();
    }
    final notes = {..._hosts.keys, ..._joinedHost.keys};
    _hosts.clear();
    _joinedHost.clear();
    for (final n in notes) {
      await live.end(n);
    }
    await _closeRoom();
  }
}

class _Peer {
  final String id;
  bool online = false;
  DateTime? seen;
  Set<String> open = const {};
  _Peer(this.id);
}

class _ShareProfile implements ProfileAccess {
  @override
  final String id;
  @override
  final String name;
  _ShareProfile(this.id, this.name);
}

/// The way the people of the share reach a session this device hosts: each one that proved who it is is handed in.
class _ShareHost implements HostTransport {
  final SessionInvite invite;
  final _incoming = StreamController<PeerChannel>.broadcast();

  _ShareHost(this.invite);

  HostTransport get transport => this;

  void accept(PeerChannel channel) {
    if (_incoming.isClosed) {
      unawaited(channel.close());
    } else {
      _incoming.add(channel);
    }
  }

  @override
  void Function(String event)? onEvent;

  @override
  Stream<PeerChannel> get incoming => _incoming.stream;

  @override
  void wake() {}

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// The way this device reaches the session another person's device hosts: the line made to ask for the secret is the first one; when it
/// is lost it is made again.
class _ShareJoin implements JoinTransport {
  LiveLink? _first;
  final Future<LiveLink> Function() _again;

  _ShareJoin(this._first, this._again);

  @override
  void Function(String stage)? onStage;

  @override
  Future<PeerChannel> connect() async {
    final first = _first;
    if (first != null) {
      _first = null;
      return first.channel;
    }
    onStage?.call(tr('Connecting to the other person...'));
    return (await _again()).channel;
  }
}

/// A participant's file in the shared folder: who they are, and their public key (what the proof of a live session is checked against).
class ParticipantRecord {
  final String id, name;
  final Uint8List? key;
  const ParticipantRecord(this.id, this.name, this.key);

  static Uint8List? keyOf(Object? text) {
    if (text is! String) return null;
    try {
      final bytes = base64.decode(text);
      return bytes.length == 32 ? Uint8List.fromList(bytes) : null;
    } catch (_) {
      return null;
    }
  }
}
