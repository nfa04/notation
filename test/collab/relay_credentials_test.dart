import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/relay_credentials.dart';
import 'package:notes/collab/signaling.dart';
import 'package:notes/collab/signaling_server.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_room.dart';

/// The relay servers that a signalling server hands out: asked for once and kept, and what the server says it has none of is not
/// asked for again at once.
void main() {
  setUp(RelayCredentials.forgetAll);

  const relay = {
    'urls': ['turn:turn.example.org:3478', 'turns:turn.example.org:443'],
    'username': 'u1',
    'credential': 'p1',
  };
  IceReply reply({int ttl = 7200}) => IceReply(servers: const [relay], ttl: Duration(seconds: ttl));

  group('the answer', () {
    test('servers with their time', () {
      final r = IceReply.parse({
        's': 'ice',
        'ttl': 7200,
        'servers': [
          {'urls': ['turn:a:3478'], 'username': 'u', 'credential': 'c'},
          {'urls': 'turn:b:3478'}, // (one address as text, nothing else)
          {'urls': []}, // (nothing to go to: left out)
          'nonsense',
        ],
      })!;
      expect(r.none, isNull);
      expect(r.ttl, const Duration(hours: 2));
      expect(r.servers, [
        {'urls': ['turn:a:3478'], 'username': 'u', 'credential': 'c'},
        {'urls': ['turn:b:3478']},
      ]);
    });

    test('the reason there are none; and an answer with nothing usable counts as "unavailable"', () {
      expect(IceReply.parse({'s': 'ice', 'none': 'limit'})!.none, 'limit');
      expect(IceReply.parse({'s': 'ice', 'servers': []})!.none, 'unavailable');
      expect(IceReply.parse({'s': 'something else'}), isNull);
    });
  });

  group('keeping them', () {
    test('asked for once while they work, and again a little before they end', () async {
      var asks = 0;
      var now = DateTime(2026, 10, 21, 12);
      Future<IceReply?> ask() async {
        asks++;
        return reply();
      }

      expect(await RelayCredentials.forServer('wss://s', ask, now: () => now), [relay]);
      expect(await RelayCredentials.forServer('wss://s', ask, now: () => now), [relay]);
      now = now.add(const Duration(minutes: 100)); // (works for two hours: still good after 100 minutes)
      expect(await RelayCredentials.forServer('wss://s', ask, now: () => now), [relay]);
      expect(asks, 1);
      now = now.add(const Duration(minutes: 10)); // (less than 15 minutes left)
      await RelayCredentials.forServer('wss://s', ask, now: () => now);
      expect(asks, 2);
    });

    test('one that works for a short time is asked for again after half of it', () async {
      var asks = 0;
      var now = DateTime(2026, 10, 21, 12);
      Future<IceReply?> ask() async {
        asks++;
        return reply(ttl: 600);
      }

      await RelayCredentials.forServer('wss://s', ask, now: () => now);
      now = now.add(const Duration(minutes: 4));
      await RelayCredentials.forServer('wss://s', ask, now: () => now);
      expect(asks, 1);
      now = now.add(const Duration(minutes: 2));
      await RelayCredentials.forServer('wss://s', ask, now: () => now);
      expect(asks, 2);
    });

    test('each server has its own', () async {
      var asks = 0;
      Future<IceReply?> ask() async {
        asks++;
        return reply();
      }

      await RelayCredentials.forServer('wss://one', ask);
      await RelayCredentials.forServer('wss://two', ask);
      expect(asks, 2);
    });

    test('many connections at once ask once', () async {
      var asks = 0;
      final answer = Completer<IceReply?>();
      Future<IceReply?> ask() {
        asks++;
        return answer.future;
      }

      final all = [for (var i = 0; i < 5; i++) RelayCredentials.forServer('wss://s', ask)];
      answer.complete(reply());
      for (final servers in await Future.wait(all)) {
        expect(servers, [relay]);
      }
      expect(asks, 1);
    });
  });

  group('when there is none', () {
    Future<List<DateTime>> asksOver(String? none, Duration step, int steps) async {
      final at = <DateTime>[];
      var now = DateTime(2026, 10, 21, 12);
      Future<IceReply?> ask() async {
        at.add(now);
        return none == null ? null : IceReply(none: none);
      }

      for (var i = 0; i < steps; i++) {
        await RelayCredentials.forServer('wss://s', ask, now: () => now);
        now = now.add(step);
      }
      return at;
    }

    test('a server without a relay is not asked again for hours', () async {
      final at = await asksOver('unconfigured', const Duration(minutes: 30), 14); // seven hours
      expect(at, hasLength(2));
      expect(at[1].difference(at[0]), const Duration(hours: 6));
    });

    test('a budget that is used up, or a server that is busy, is tried again in ten minutes', () async {
      for (final why in ['limit', 'unavailable', 'busy']) {
        RelayCredentials.forgetAll();
        final at = await asksOver(why, const Duration(minutes: 5), 5);
        expect(at, hasLength(3), reason: why); // minutes 0, 10, 20
      }
    });

    test('a server that does not answer at all (an old one) is not asked again for half an hour', () async {
      final at = await asksOver(null, const Duration(minutes: 10), 6); // minutes 0 to 50
      expect(at, hasLength(2));
      expect(at[1].difference(at[0]), const Duration(minutes: 30));
    });

    test('a request that fails is not kept: the next connection asks again', () async {
      var asks = 0;
      Future<IceReply?> failing() async {
        asks++;
        throw StateError('no connection');
      }

      expect(await RelayCredentials.forServer('wss://s', failing), isEmpty);
      expect(await RelayCredentials.forServer('wss://s', () async => reply()), [relay]);
      expect(asks, 1);
    });
  });

  group('from a signalling server', () {
    late SignalingServer withRelay, without;
    var budgetLeft = true;
    final random = Random();

    setUp(() async {
      budgetLeft = true;
      withRelay = SignalingServer(
        port: 0,
        relay: () => budgetLeft ? {'servers': [relay], 'ttl': 7200} : {'none': 'limit'},
      );
      without = SignalingServer(port: 0);
      await withRelay.start(address: InternetAddress.loopbackIPv4);
      await without.start(address: InternetAddress.loopbackIPv4);
    });
    tearDown(() async {
      await withRelay.stop();
      await without.stop();
    });

    String url(SignalingServer s) => 'ws://127.0.0.1:${s.boundPort}';

    test('a device in a live session gets the relay servers, the others do not hear of it', () async {
      final invite = SessionInvite.create(url(withRelay), random: random);
      final a = SignalingClient(invite), b = SignalingClient(invite);
      await a.connect();
      await b.connect();
      final heard = <Map<String, Object?>>[];
      b.messages.listen(heard.add);
      final answer = await a.requestIceServers();
      expect(answer!.none, isNull);
      expect(answer.servers, [relay]);
      expect(answer.ttl, const Duration(hours: 2));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(heard, isEmpty);
      // and the sealed messages of the session still get through
      final next = b.messages.first;
      await a.send({'t': 'hello'});
      expect((await next.timeout(const Duration(seconds: 3)))['t'], 'hello');
      await a.close();
      await b.close();
    });

    test('a server without a relay says so at once', () async {
      final invite = SessionInvite.create(url(without), random: random);
      final a = SignalingClient(invite);
      await a.connect();
      final answer = await a.requestIceServers();
      expect(answer!.none, 'unconfigured');
      expect(answer.servers, isEmpty);
      await a.close();
    });

    test('a server that does not answer is given up on after the time that was set', () async {
      // (a server of the old kind: it does not know the question and says nothing)
      final old = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      old.listen((r) async => (await WebSocketTransformer.upgrade(r)).listen((_) {}));
      addTearDown(() => old.close(force: true));
      final a = SignalingClient(SessionInvite.create('ws://127.0.0.1:${old.port}', random: random));
      await a.connect();
      final started = DateTime.now();
      expect(await a.requestIceServers(timeout: const Duration(milliseconds: 300)), isNull);
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)));
      await a.close();
    });

    test('with no connection nothing is asked', () async {
      final a = SignalingClient(SessionInvite.create(url(withRelay), random: random));
      expect(await a.requestIceServers(), isNull);
    });

    test('the profile room hands them to a device that proved itself, and they are kept, so that the server is asked once', () async {
      final secret = SyncSecret.create(Random(3));
      final a = ServerSyncRoom(url(withRelay), secret, persistent: false);
      await a.connect();
      expect(await a.relayServers(), [relay]);
      budgetLeft = false; // (the budget is used up now: what was handed out before is still good)
      expect(await a.relayServers(), [relay]);
      await a.close();
    });

    test('the profile room: no relay, and it is said at once', () async {
      final secret = SyncSecret.create(Random(4));
      final a = ServerSyncRoom(url(without), secret, persistent: false);
      await a.connect();
      final started = DateTime.now();
      expect(await a.relayServers(), isEmpty);
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)));
      await a.close();
    });

    test('a used-up budget gives nothing, and it is tried again later', () async {
      budgetLeft = false;
      final invite = SessionInvite.create(url(withRelay), random: random);
      final a = SignalingClient(invite);
      await a.connect();
      var now = DateTime(2026, 10, 21, 12);
      expect(await RelayCredentials.forServer(invite.server, a.requestIceServers, now: () => now), isEmpty);
      budgetLeft = true;
      expect(await RelayCredentials.forServer(invite.server, a.requestIceServers, now: () => now), isEmpty, reason: 'not asked again yet');
      now = now.add(const Duration(minutes: 11));
      expect(await RelayCredentials.forServer(invite.server, a.requestIceServers, now: () => now), [relay]);
      await a.close();
    });

    test('what the server answers is what a sealed message of the session cannot be taken for', () async {
      // a device cannot make the others take a frame for an answer: the frames are sealed, and {"s":"ice"} is not passed on
      final invite = SessionInvite.create(url(withRelay), random: random);
      final a = SignalingClient(invite), b = SignalingClient(invite);
      await a.connect();
      await b.connect();
      final heard = <Map<String, Object?>>[];
      b.messages.listen(heard.add);
      final asked = b.requestIceServers(timeout: const Duration(milliseconds: 500));
      a.requestIceServers(); // a's question is answered to a, not to b
      expect((await asked)!.servers, [relay]);
      expect(jsonEncode(heard), '[]');
      await a.close();
      await b.close();
    });
  });
}
