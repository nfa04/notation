import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable, ValueNotifier;
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/devicesync/live_notes.dart';
import 'package:notes/devicesync/sync_room.dart';

/// A signalling server in memory: the rooms, and the devices in them.
class FakeServer {
  final Map<String, List<FakeRoom>> rooms = {};
  final Map<String, FakeLinker> linkers = {};
  int connects = 0;

  /// Rooms that were joined, by the secret they were opened with.
  final List<String> joined = [];

  /// Every message sent in a room, as the devices in it read it.
  final List<Map<String, Object?>> sent = [];

  /// Every room that was opened, in order.
  final List<FakeRoom> opened = [];
}

class FakeRoom implements SyncRoom {
  final FakeServer server;
  @override
  final String name;
  final _in = StreamController<Map<String, Object?>>.broadcast();
  final _conn = StreamController<bool>.broadcast();
  bool _up = true;

  FakeRoom(this.server, this.name) {
    server.rooms.putIfAbsent(name, () => []).add(this);
    server.joined.add(name);
    server.opened.add(this);
  }

  @override
  Stream<Map<String, Object?>> get messages => _in.stream;

  @override
  Future<List<Map<String, Object>>> relayServers() async => const [];

  @override
  bool get connected => _up;

  @override
  Stream<bool> get connection => _conn.stream;

  int tries = 0;

  @override
  Future<void> send(Map<String, Object?> message) async {
    tries++;
    if (!_up) return;
    server.sent.add(Map.of(message));
    for (final other in List.of(server.rooms[name] ?? const <FakeRoom>[])) {
      if (!identical(other, this) && other._up) {
        scheduleMicrotask(() {
          if (!other._in.isClosed) other._in.add(Map.of(message));
        });
      }
    }
  }

  @override
  void wake() {}

  int checks = 0;

  @override
  void check() => checks++;

  /// The connection to the server breaks (the phone is locked, the network changes): nothing goes in or out until [restore].
  void drop() {
    _up = false;
    _conn.add(false);
  }

  void restore() {
    _up = true;
    _conn.add(true);
  }

  /// The app is killed (or its network vanishes): it says nothing more, not even that it goes; the server tells the others that a
  /// connection closed, not whose.
  void crash() {
    _up = false;
    server.rooms[name]?.remove(this);
    for (final other in List.of(server.rooms[name] ?? const <FakeRoom>[])) {
      scheduleMicrotask(() {
        if (!other._in.isClosed && other._up) other._in.add(const {'t': 'left'});
      });
    }
  }

  @override
  Future<void> close() async {
    _up = false;
    server.rooms[name]?.remove(this);
    await _in.close();
    await _conn.close();
  }
}

/// Direct connections in memory.
class FakeLinker implements PeerLinker {
  final FakeServer server;
  final String room, me;
  final _incoming = StreamController<PeerChannel>.broadcast();

  FakeLinker(this.server, this.room, this.me) {
    server.linkers['$room/$me'] = this;
  }

  @override
  Stream<PeerChannel> get incoming => _incoming.stream;

  @override
  Future<PeerChannel> connect(String peerId, {Duration timeout = const Duration(seconds: 30)}) async {
    final other = server.linkers['$room/$peerId'];
    if (other == null) throw StateError('nobody there');
    final hub = LoopbackHub();
    final inc = hub.host.incoming.first;
    final a = await hub.guest.connect();
    final b = await inc;
    scheduleMicrotask(() => other._incoming.add(b));
    return a;
  }

  @override
  Future<void> close() async {
    server.linkers.remove('$room/$me');
    await _incoming.close();
  }
}

Uint8List bytesOf(List<int> l) => Uint8List.fromList(l);

/// The live sessions of a device, as the sync sees them: what it hosts and joins, without editors or connections.
class FakeLive implements LiveNotes {
  final Set<String> sessions = {};
  final Set<String> own = {};
  final Map<String, ({SessionInvite invite, HostTransport transport})> hosted = {};
  final Map<String, SessionInvite> joined = {};
  final List<PeerChannel> guestChannels = [];
  final List<PeerChannel> hostChannels = [];
  final List<String> ended = [];

  @override
  bool hasSession(String noteId) => sessions.contains(noteId);

  @override
  Set<String> get ownNotes => Set.of(own);

  /// What was done, in order (`host <key>`, `join <key>`, `end`), the keys cut short.
  final List<String> log = [];

  @override
  Future<bool> host(String noteId, SessionInvite invite, HostTransport transport) async {
    log.add('host ${invite.secret.take(2).join('.')}');
    hosted[noteId] = (invite: invite, transport: transport);
    transport.incoming.listen(hostChannels.add);
    sessions.add(noteId);
    own.add(noteId);
    return true;
  }

  @override
  Future<bool> join(String noteId, SessionInvite invite, JoinTransport transport) async {
    log.add('join ${invite.secret.take(2).join('.')}');
    guestChannels.add(await transport.connect());
    joined[noteId] = invite;
    sessions.add(noteId);
    own.add(noteId);
    return true;
  }

  /// The news that the editor of an open note has loaded it (a session cannot start before).
  final StreamController<String> ready = StreamController<String>.broadcast();

  @override
  Stream<String> get editorsReady => ready.stream;

  final Map<String, ({bool host, int people, bool ended})> states = {};
  final List<String> saved = [];
  final ValueNotifier<int> _changes = ValueNotifier(0);

  void setState(String note, ({bool host, int people, bool ended}) state) {
    states[note] = state;
    _changes.value++;
  }

  @override
  SessionInvite? hostedInvite(String noteId) => hosted[noteId]?.invite;

  @override
  ({bool host, int people, bool ended})? status(String noteId) => states[noteId];

  @override
  Future<void> saveNote(String noteId) async => saved.add(noteId);

  @override
  Listenable get changes => _changes;

  int wakes = 0;

  @override
  void wake() => wakes++;

  @override
  Future<void> end(String noteId) async {
    log.add('end');
    sessions.remove(noteId);
    own.remove(noteId);
    ended.add(noteId);
    if (states[noteId] != null) setState(noteId, (host: states[noteId]!.host, people: 0, ended: true));
  }
}
