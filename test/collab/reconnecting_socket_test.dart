import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/backoff.dart';
import 'package:notes/collab/reconnecting_socket.dart';

/// A server that is told what to do with each connection: answer pings (or stop doing so without closing), and let a test send frames.
class ScriptedServer {
  late HttpServer http;
  final List<WebSocket> sockets = [];
  bool mute = false;
  bool answerPing = true;
  int connections = 0;

  Future<void> start([int port = 0]) async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    http.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      connections++;
      sockets.add(ws);
      ws.listen((data) {
        if (data == 'ping' && answerPing && !mute) ws.add('pong');
      }, onError: (_) {}, onDone: () => sockets.remove(ws));
    });
  }

  int get port => http.port;

  Future<void> stop() async {
    for (final s in List.of(sockets)) {
      await s.close();
    }
    await http.close(force: true);
  }
}

void main() {
  group('Backoff', () {
    test('waits longer after each failure, never longer than the most, always at least half of what it is meant to', () {
      final b = Backoff(base: const Duration(seconds: 1), max: const Duration(seconds: 8), random: Random(1));
      final caps = [1, 2, 4, 8, 8, 8];
      for (final cap in caps) {
        final d = b.next();
        expect(d.inMilliseconds, inInclusiveRange(cap * 500, cap * 1000));
      }
      expect(b.failures, 6);
      b.reset();
      expect(b.next().inMilliseconds, lessThanOrEqualTo(1000));
    });

    test('devices that failed together do not wait the same time', () {
      final waits = {for (var i = 0; i < 20; i++) (Backoff(random: Random(i))..next()).next().inMilliseconds};
      expect(waits.length, greaterThan(10));
    });
  });

  group('ReconnectingSocket', () {
    late ScriptedServer server;
    final made = <ReconnectingSocket>[];

    setUp(() async {
      server = ScriptedServer();
      await server.start();
    });
    tearDown(() async {
      for (final s in made) {
        await s.close();
      }
      made.clear();
      await server.stop();
    });

    ReconnectingSocket socketFor(int port,
        {bool persistent = true, bool handshake = false, void Function(SocketLink, String)? onFrame, void Function()? onUp, void Function(bool)? onDown, Duration pingEvery = const Duration(milliseconds: 50), Duration deadAfter = const Duration(milliseconds: 200)}) {
      final s = ReconnectingSocket(
        address: () async => Uri.parse('ws://127.0.0.1:$port/x'),
        persistent: persistent,
        handshake: handshake,
        refusal: 'refused',
        onFrame: onFrame ?? (_, _) {},
        onUp: onUp,
        onDown: onDown,
        pingEvery: pingEvery,
        deadAfter: deadAfter,
        backoff: Backoff(base: const Duration(milliseconds: 20), max: const Duration(milliseconds: 100), random: Random(1)),
      );
      made.add(s);
      return s;
    }

    Future<void> until(bool Function() ok, {int ms = 3000}) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (!ok() && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(ok(), isTrue, reason: 'did not come about in $ms ms');
    }

    test('frames come in, and what is sent goes out; a ping is not a frame', () async {
      final got = <String>[];
      final s = socketFor(server.port, onFrame: (_, f) => got.add(f));
      await s.connect();
      expect(s.isUp, isTrue);
      expect(s.send('hello'), isTrue);
      server.sockets.single.add('from the server');
      await until(() => got.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300)); // (it pings meanwhile, and the server answers)
      expect(got, ['from the server']);
    });

    test('a connection that the server drops is made again, with the app told', () async {
      var ups = 0;
      final downs = <bool>[];
      final s = socketFor(server.port, onUp: () => ups++, onDown: downs.add);
      await s.connect();
      await server.sockets.single.close();
      await until(() => ups == 2);
      expect(downs, [true]);
      expect(s.isUp, isTrue);
    });

    test('a server that was away is waited for, and found when it is back', () async {
      var ups = 0;
      final s = socketFor(server.port, onUp: () => ups++);
      await s.connect();
      final port = server.port;
      await server.stop();
      await until(() => !s.isUp);
      await Future<void>.delayed(const Duration(milliseconds: 150)); // (it tries, and fails)
      server = ScriptedServer();
      await server.start(port);
      await until(() => ups == 2);
    });

    test('a connection that is not to be made again stays gone, and says so', () async {
      final downs = <bool>[];
      final s = socketFor(server.port, persistent: false, onDown: downs.add);
      await s.connect();
      await server.sockets.single.close();
      await until(() => downs.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(downs, [false]);
      expect(server.connections, 1);
      expect(s.isUp, isFalse);
    });

    test('a connection that went silent without closing is noticed and replaced', () async {
      var ups = 0;
      final s = socketFor(server.port, onUp: () => ups++);
      await s.connect();
      await Future<void>.delayed(const Duration(milliseconds: 200)); // (it is known that the server answers pings)
      server.mute = true; // dead, but nothing says so
      await until(() => ups == 2, ms: 4000);
      expect(server.connections, greaterThanOrEqualTo(2));
    });

    test('a server that never answers a ping is not taken for dead', () async {
      server.answerPing = false;
      var ups = 0;
      final s = socketFor(server.port, onUp: () => ups++);
      await s.connect();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(ups, 1);
    });

    test('coming back to the front makes a fresh connection at once', () async {
      var ups = 0;
      final s = socketFor(server.port, onUp: () => ups++, pingEvery: const Duration(seconds: 20), deadAfter: const Duration(seconds: 45));
      await s.connect();
      s.wake();
      await until(() => ups == 2);
      expect(server.connections, 2);
    });

    test('a connection that is closed by its user is not made again', () async {
      var ups = 0;
      final s = socketFor(server.port, onUp: () => ups++);
      await s.connect();
      await s.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(ups, 1);
      expect(server.connections, 1);
      await expectLater(s.connect(), throwsA(isA<StateError>()));
    });

    test('with a handshake the connection is up when the server has said so, and not before', () async {
      SocketLink? link;
      final s = socketFor(server.port, handshake: true, onFrame: (l, f) {
        link = l;
        if (f == 'ready') l.ready();
      });
      final connecting = s.connect();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(s.isUp, isFalse);
      server.sockets.single.add('challenge');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(link!.isReady, isFalse);
      server.sockets.single.add('ready');
      await connecting;
      expect(s.isUp, isTrue);
      expect(link!.isReady, isTrue);
    });

    test('a server that closes the connection during the handshake refuses the device, and a silent one times out', () async {
      final s = socketFor(server.port, handshake: true);
      final refused = s.connect();
      await until(() => server.sockets.isNotEmpty);
      await server.sockets.single.close();
      await expectLater(refused, throwsA(predicate((e) => '$e'.contains('refused'))));

      final silent = socketFor(server.port, handshake: true);
      await expectLater(silent.connect(timeout: const Duration(milliseconds: 200)), throwsA(isA<TimeoutException>()));
      expect(silent.isUp, isFalse);
    });

    test('a server that cannot be reached fails the first connection, which closes nothing it did not open', () async {
      final port = server.port;
      await server.stop();
      final s = socketFor(port);
      await expectLater(s.connect(timeout: const Duration(milliseconds: 500)), throwsA(anything));
      expect(s.isUp, isFalse);
      server = ScriptedServer();
      await server.start();
    });
  });
}
