import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_room.dart';

/// What the signalling server sees of the messages in a room, and how the room keeps its connection: a server that lets the device
/// in, keeps every frame it is sent, and answers pings - until it is told to go silent (the connection died without closing).
void main() {
  late HttpServer http;
  late List<String> frames;
  late String url;
  late int connections;
  var answersPings = true;
  // the connections that died without closing: the server hears nothing from them, and they nothing from it
  final dead = <WebSocket>{};
  late WebSocket latest;
  void silenceLatest() => dead.add(latest);

  setUp(() async {
    frames = [];
    connections = 0;
    answersPings = true;
    dead.clear();
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'ws://127.0.0.1:${http.port}';
    http.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      connections++;
      latest = socket;
      socket.add(jsonEncode({'s': 'challenge', 'n': 'nonce'}));
      socket.listen((data) {
        if (data is! String || dead.contains(socket)) return;
        if (data == 'ping') {
          if (answersPings) socket.add('pong');
          return;
        }
        if ((jsonDecode(data) as Map)['s'] == 'auth') {
          socket.add(jsonEncode({'s': 'ready'}));
        } else {
          frames.add(data);
        }
      });
    });
  });
  tearDown(() => http.close(force: true));

  Future<ServerSyncRoom> room() async {
    final r = ServerSyncRoom(url, SyncSecret.create(Random(1)), persistent: false);
    await r.connect();
    return r;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 200));

  test('the open notes cannot be read, the same note opened twice looks different, and how many are open does not show', () async {
    final r = await room();
    const note = '3f2a9c1e-7b4d-4e8a-9f00-1234567890ab';
    Map<String, Object?> here(List<String> open) => {'t': 'here', 'd': 'a1b2c3d4e5f60718', 'n': 'Laptop', 'o': open};
    await r.send(here([note]));
    await r.send(here([note]));
    await r.send(here([for (var i = 0; i < 12; i++) '$note-$i']));
    await r.send({'t': 'here', 'd': 'a1b2c3d4e5f60718', 'n': 'Laptop'});
    await settle();
    expect(frames, hasLength(4));
    for (final f in frames) {
      expect(f, isNot(contains(note)));
      expect(f, isNot(contains('3f2a9c1e')));
      expect(f, isNot(contains('a1b2c3d4e5f60718')), reason: 'the id of the device');
      expect(f, isNot(contains('Laptop')));
      expect((jsonDecode(f) as Map).keys, ['p'], reason: 'nothing but the sealed message');
    }
    expect(frames[0], isNot(frames[1]), reason: 'the same note opened again must not look the same');
    expect({for (final f in frames) f.length}, hasLength(1), reason: 'one note, twelve or none: all the same size');
    await r.close();
  });

  test('the name of the room changes every day: the room of one day says nothing of the next', () async {
    final secret = SyncSecret.create(Random(2));
    final today = await secret.roomKeys();
    final tomorrow = await secret.roomKeys(epoch: SyncSecret.epochNow() + 1);
    expect(today.room, isNot(tomorrow.room));
  });

  test('a connection that goes silent without closing (a change of network) is noticed, and a new one is made', () async {
    final r = ServerSyncRoom(url, SyncSecret.create(Random(3)), pingEvery: const Duration(milliseconds: 50), deadAfter: const Duration(milliseconds: 250));
    await r.connect();
    await Future<void>.delayed(const Duration(milliseconds: 200)); // (the server answered a ping: it is one that does)
    expect(connections, 1);
    final drops = <bool>[];
    r.connection.listen(drops.add);
    silenceLatest(); // the old connection is dead from here on; a new one works
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!(connections >= 2 && r.connected) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(connections, greaterThanOrEqualTo(2), reason: 'no new connection was made');
    expect(drops, contains(false), reason: 'the dead connection was not given up');
    expect(r.connected, isTrue);
    await r.close();
  });

  test('a server that never answers a ping (an old one) is not taken for dead', () async {
    answersPings = false;
    final r = ServerSyncRoom(url, SyncSecret.create(Random(4)), pingEvery: const Duration(milliseconds: 50), deadAfter: const Duration(milliseconds: 150));
    await r.connect();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(connections, 1);
    expect(r.connected, isTrue);
    await r.close();
  });

  test('asked to check, a connection that does not answer within a moment is made again', () async {
    final r = ServerSyncRoom(url, SyncSecret.create(Random(5)), pingEvery: const Duration(milliseconds: 100), deadAfter: const Duration(seconds: 60));
    await r.connect();
    await Future<void>.delayed(const Duration(milliseconds: 250)); // (a ping was answered)
    silenceLatest();
    r.check();
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (connections < 2 && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(connections, 2, reason: 'the check did not lead to a new connection');
    await r.close();
  });
}
