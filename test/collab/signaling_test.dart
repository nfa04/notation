import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/signaling.dart';
import 'package:notes/collab/signaling_server.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_room.dart';

/// The conformance tests of the signalling protocol (tool/signaling/README.md). Run against the Dart
/// server by default; set SIGNALING_URL (e.g. ws://127.0.0.1:8787) to run them against any other
/// implementation: the Node one, the Cloudflare Worker (`wrangler dev`), or a deployed one.
void main() {
  final external = Platform.environment['SIGNALING_URL'];
  late String base;
  SignalingServer? server;
  final random = Random();

  setUpAll(() async {
    if (external != null) {
      base = external.replaceAll(RegExp(r'/$'), '');
    } else {
      server = SignalingServer(port: 0);
      await server!.start(address: InternetAddress.loopbackIPv4);
      base = 'ws://127.0.0.1:${server!.boundPort}';
    }
  });
  tearDownAll(() async => server?.stop());

  String newRoom() => List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  Future<WebSocket> open(String room) => WebSocket.connect('$base/live/$room');
  Future<void> pause([int ms = 150]) => Future<void>.delayed(Duration(milliseconds: ms));

  /// What a socket receives, as a list that fills up.
  List<Object?> listen(WebSocket s) {
    final got = <Object?>[];
    s.listen(got.add, onError: (_) {}, onDone: () {});
    return got;
  }

  test('in a live room too, ping is answered with pong to the sender and not passed on', () async {
    final room = newRoom();
    final a = await open(room), b = await open(room);
    final gotA = listen(a), gotB = listen(b);
    await pause();
    a.add('ping');
    await pause(300);
    expect(gotA, ['pong']);
    expect(gotB, isEmpty);
    await a.close();
    await b.close();
  });

  group('asking for a relay', () {
    // (a server that has a relay answers with its servers, one that has none says so: both are right, and either is at once)
    Map<String, Object?> asked(Object? frame) => (jsonDecode(frame as String) as Map).cast<String, Object?>();

    test('the frame {"s":"ice"} is answered to the device that sent it, and not passed on', () async {
      final room = newRoom();
      final a = await open(room), b = await open(room);
      final gotA = listen(a), gotB = listen(b);
      await pause();
      a.add('{"s":"ice"}');
      await pause(400);
      expect(gotA, hasLength(1));
      final answer = asked(gotA.single);
      expect(answer['s'], 'ice');
      expect(answer['servers'] is List || answer['none'] is String, isTrue, reason: 'either the servers of a relay or why there are none');
      expect(gotB, isEmpty);
      a.add('{"p":"after"}'); // and the room still works
      await pause();
      expect(gotB, ['{"p":"after"}']);
      await a.close();
      await b.close();
    });

    test('a device of a profile that has proven itself can ask too', () async {
      final secret = SyncSecret.create(Random(8));
      final a = ServerSyncRoom(base, secret, persistent: false), b = ServerSyncRoom(base, secret, persistent: false);
      await a.connect();
      await b.connect();
      final heard = <Map<String, Object?>>[];
      b.messages.listen(heard.add);
      final servers = await a.relayServers().timeout(const Duration(seconds: 5));
      expect(servers, isA<List<Map<String, Object>>>());
      await pause();
      expect(heard, isEmpty, reason: 'the question is not for the others');
      await a.close();
      await b.close();
    });
  });

  group('relaying', () {
    test('a text frame goes to every other device in the room, unchanged and in order, not back to its sender', () async {
      final room = newRoom();
      final a = await open(room), b = await open(room), c = await open(room);
      final gotA = listen(a), gotB = listen(b), gotC = listen(c);
      await pause();
      for (var i = 0; i < 20; i++) {
        a.add('frame $i ünïcode ✓');
      }
      await pause(400);
      final expected = [for (var i = 0; i < 20; i++) 'frame $i ünïcode ✓'];
      expect(gotB, expected);
      expect(gotC, expected);
      expect(gotA, isEmpty);
      await Future.wait([a.close(), b.close(), c.close()]);
    });

    test('another room hears nothing', () async {
      final a = await open(newRoom()), b = await open(newRoom());
      final gotB = listen(b);
      await pause();
      a.add('only for room a');
      await pause(300);
      expect(gotB, isEmpty);
      await a.close();
      await b.close();
    });

    test('the sealed client of the app works through it, and cannot be read in between', () async {
      final invite = SessionInvite.create(base, random: Random(11));
      final a = SignalingClient(invite), b = SignalingClient(invite);
      await a.connect();
      await b.connect();
      final spy = await open(invite.room);
      final seen = listen(spy);
      final heard = b.messages.first;
      await pause();
      await a.send({'t': 'offer', 'from': 'a', 'sdp': 'v=0 a very secret session description'});
      expect((await heard.timeout(const Duration(seconds: 3)))['from'], 'a');
      await pause();
      expect(seen.single as String, isNot(contains('secret')));
      expect(seen.single as String, isNot(contains('offer')));
      await spy.close();
      await a.close();
      await b.close();
    });

    test('a device with another key in the same room hears frames it cannot open, and drops them', () async {
      final invite = SessionInvite.create(base, random: Random(21));
      final stranger = SessionInvite(base, Uint8List.fromList(List.filled(32, 9)));
      final a = SignalingClient(invite);
      await a.connect();
      final raw = await open(invite.room); // same room name, another key
      final heard = listen(raw);
      await pause();
      await a.send({'t': 'secret'});
      await pause(300);
      expect(heard.length, 1); // it arrived: the server relays everything in the room
      expect(stranger.room, isNot(invite.room));
      await raw.close();
      await a.close();
    });
  });

  group('limits', () {
    test('a room holds eight devices; the ninth is turned away, and a place frees up when one leaves', () async {
      final room = newRoom();
      final peers = [for (var i = 0; i < 8; i++) await open(room)];
      await expectLater(open(room), throwsA(predicate((e) => '$e'.contains('429'))));
      await peers.first.close();
      await pause(300);
      final again = await open(room);
      await again.close();
      for (final p in peers.skip(1)) {
        await p.close();
      }
    });

    test('a frame over 64 KB closes that device, with 1008', () async {
      final room = newRoom();
      final a = await open(room), b = await open(room);
      final gotB = listen(b);
      final closed = Completer<int?>();
      a.listen((_) {}, onDone: () => closed.complete(a.closeCode));
      await pause();
      a.add('x' * (64 * 1024 + 1));
      expect(await closed.future.timeout(const Duration(seconds: 3)), 1008);
      await pause();
      expect(gotB, isEmpty); // not relayed
      a.close();
      await b.close();
    });

    test('a frame of exactly 64 KB is fine', () async {
      final room = newRoom();
      final a = await open(room), b = await open(room);
      final gotB = listen(b);
      await pause();
      a.add('y' * (64 * 1024));
      await pause(500);
      expect(gotB.length, 1);
      await a.close();
      await b.close();
    });

    test('a binary frame closes that device, with 1008', () async {
      final room = newRoom();
      final a = await open(room);
      final closed = Completer<int?>();
      a.listen((_) {}, onDone: () => closed.complete(a.closeCode));
      await pause();
      a.add(Uint8List.fromList([1, 2, 3]));
      expect(await closed.future.timeout(const Duration(seconds: 3)), 1008);
    });

    test('more than 60 frames in a second closes that device, and only that one', () async {
      final room = newRoom();
      final noisy = await open(room), quiet = await open(room);
      final closed = Completer<int?>();
      noisy.listen((_) {}, onDone: () => closed.complete(noisy.closeCode));
      final gotQuiet = listen(quiet);
      await pause();
      for (var i = 0; i < 130; i++) {
        // (more than twice the limit: some second of the burst has more than 60 of them)
        noisy.add('$i');
      }
      expect(await closed.future.timeout(const Duration(seconds: 3)), 1008);
      quiet.add('still here');
      await pause(200);
      expect(gotQuiet.length, greaterThan(0));
      expect(quiet.closeCode, isNull);
      await quiet.close();
    });
  });

  group('what is not a signalling connection', () {
    Future<int> status(String path, {bool upgrade = false}) async {
      final http = HttpClient();
      final uri = Uri.parse(base.replaceFirst('ws', 'http') + path);
      final request = await http.getUrl(uri);
      final response = await request.close();
      await response.drain<void>();
      http.close();
      return response.statusCode;
    }

    test('other paths, and the right path without an upgrade, are 404', () async {
      expect(await status('/'), 404);
      expect(await status('/other'), 404);
      expect(await status('/live/${newRoom()}'), 404);
      expect(await status('/live/${newRoom()}/extra'), 404);
    });

    test('a room name that is not 32 lowercase hex digits is refused', () async {
      for (final bad in ['not-a-room', newRoom().toUpperCase(), '${newRoom()}0', newRoom().substring(1)]) {
        await expectLater(open(bad), throwsA(anything), reason: bad);
      }
    });
  });

  group('profile sync rooms (/sync/<room>): the server checks that a device knows the secret', () {
    final secret = SyncSecret.create(Random(5));

    /// A raw socket in the sync room of [keys]; [frames] fills with what the server says.
    Future<(WebSocket, List<String>)> openSync(String room) async {
      final socket = await WebSocket.connect('$base/sync/$room');
      final frames = <String>[];
      socket.listen((d) => frames.add('$d'), onError: (_) {}, onDone: () {});
      return (socket, frames);
    }

    String nonceIn(List<String> frames) => (jsonDecode(frames.firstWhere((f) => f.contains('challenge'))) as Map)['n'] as String;

    test('a device with the proof is let in and its sealed messages reach the others', () async {
      final a = ServerSyncRoom(base, secret, persistent: false), b = ServerSyncRoom(base, secret, persistent: false);
      await a.connect();
      await b.connect();
      final heard = b.messages.first;
      await a.send({'t': 'here', 'd': 'one'});
      expect((await heard.timeout(const Duration(seconds: 3)))['d'], 'one');
      await a.close();
      await b.close();
    });

    test('a device that knows another secret is refused, and so is a proof for another room or an old challenge', () async {
      final keys = await secret.roomKeys();
      final other = await SyncSecret.create(Random(6)).roomKeys();

      // another secret, in this secret's room: the key does not name the room
      var (socket, frames) = await openSync(keys.room);
      await pause();
      var nonce = nonceIn(frames);
      socket.add(jsonEncode({'s': 'auth', 'k': base64.encode(other.publicKey), 'g': base64.encode(await other.answer(nonce))}));
      await pause();
      expect(frames.any((f) => f.contains('ready')), isFalse);
      expect(socket.closeCode, 1008);

      // the right key but a signature of a challenge from another connection
      final old = await openSync(keys.room);
      await pause();
      final oldNonce = nonceIn(old.$2);
      await old.$1.close();
      (socket, frames) = await openSync(keys.room);
      await pause();
      socket.add(jsonEncode({'s': 'auth', 'k': base64.encode(keys.publicKey), 'g': base64.encode(await keys.answer(oldNonce))}));
      await pause();
      expect(frames.any((f) => f.contains('ready')), isFalse);
      expect(socket.closeCode, 1008);

      // not even a proof
      (socket, frames) = await openSync(keys.room);
      await pause();
      socket.add('hello?');
      await pause();
      expect(socket.closeCode, 1008);
    });

    test('a device that has not proven itself hears nothing and is not heard', () async {
      final keys = await secret.roomKeys();
      final member = ServerSyncRoom(base, secret, persistent: false);
      await member.connect();
      final heard = <Map<String, Object?>>[];
      member.messages.listen(heard.add);
      final (stranger, strangerFrames) = await openSync(keys.room);
      await pause();
      stranger.add('{"p":"not allowed"}');
      await member.send({'t': 'secret talk'});
      await pause(300);
      expect(strangerFrames.where((f) => f.contains('"p"')), isEmpty);
      expect(heard, isEmpty);
      await stranger.close();
      await member.close();
    });

    test('when a device leaves, the others are told that one left (not which), and a device that has not proven itself is not', () async {
      final keys = await secret.roomKeys();
      final a = ServerSyncRoom(base, secret, persistent: false), b = ServerSyncRoom(base, secret, persistent: false);
      await a.connect();
      await b.connect();
      final heard = <Map<String, Object?>>[];
      b.messages.listen(heard.add);
      final (stranger, strangerFrames) = await openSync(keys.room);
      await pause();
      await a.close();
      await pause(300);
      expect(heard, [
        {'t': 'left'}
      ]);
      expect(strangerFrames.where((f) => f.contains('left')), isEmpty);
      // a stranger going away is no news to the devices
      await stranger.close();
      await pause(300);
      expect(heard, hasLength(1));
      await b.close();
    });

    test('a device silent for too long (its network vanished, no close comes) is closed, and the others are told', () async {
      if (external != null) return; // (it takes 70 seconds there)
      final quick = SignalingServer(port: 0, silentFor: const Duration(milliseconds: 300));
      await quick.start(address: InternetAddress.loopbackIPv4);
      addTearDown(quick.stop);
      final url = 'ws://127.0.0.1:${quick.boundPort}';
      final keys = await secret.roomKeys();
      final silent = await WebSocket.connect('$url/sync/${keys.room}');
      final silentFrames = <String>[];
      silent.listen((d) => silentFrames.add('$d'), onError: (_) {}, onDone: () {});
      await pause();
      silent.add(jsonEncode({'s': 'auth', 'k': base64.encode(keys.publicKey), 'g': base64.encode(await keys.answer(nonceIn(silentFrames)))}));
      final b = ServerSyncRoom(url, secret, persistent: false, pingEvery: const Duration(milliseconds: 100));
      await b.connect();
      final heard = <Map<String, Object?>>[];
      b.messages.listen(heard.add);
      await pause(800); // (b pings; the other says nothing at all)
      expect(heard, anyElement(equals({'t': 'left'})));
      expect(silent.closeCode, isNotNull);
      await b.close();
    });

    test('ping is answered with pong and not passed on', () async {
      final keys = await secret.roomKeys();
      final a = await openSync(keys.room), b = ServerSyncRoom(base, secret, persistent: false);
      await pause();
      a.$1.add(jsonEncode({'s': 'auth', 'k': base64.encode(keys.publicKey), 'g': base64.encode(await keys.answer(nonceIn(a.$2)))}));
      await pause();
      await b.connect();
      final heard = <Map<String, Object?>>[];
      b.messages.listen(heard.add);
      a.$1.add('ping');
      await pause(300);
      expect(a.$2, contains('pong'));
      expect(heard, isEmpty);
      await a.$1.close();
      await b.close();
    });
  });
}
