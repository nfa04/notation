import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/relay_credentials.dart';
import 'package:notes/collab/signaling_server.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/collab/webrtc_transport.dart';

import '../devicesync/fake_rtc.dart';

/// The host and the guest of a live session, on the real signalling client and a real (in-process) signalling server, with WebRTC
/// replaced by the in-memory one.
void main() {
  late SignalingServer server;
  late String url;
  late FakeRtcNet net;
  late SessionInvite invite;
  final cleanup = <Future<void> Function()>[];

  setUp(() async {
    RelayCredentials.forgetAll();
    server = SignalingServer(port: 0);
    await server.start(address: InternetAddress.loopbackIPv4);
    url = 'ws://127.0.0.1:${server.boundPort}';
    net = FakeRtcNet();
    invite = SessionInvite.create(url, random: Random(5));
  });
  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
    await server.stop();
  });

  Future<WebRtcHost> startHost() async {
    final host = WebRtcHost(invite, create: net.create);
    await host.start();
    cleanup.add(host.close);
    return host;
  }

  Future<List<int>> next(PeerChannel c) async => (await c.messages.first.timeout(const Duration(seconds: 2))).toList();

  test('a guest finds the host through the server, and the two have a line that carries messages both ways', () async {
    final host = await startHost();
    final events = <String>[];
    host.onEvent = events.add;
    final atHost = Completer<PeerChannel>();
    host.incoming.listen(atHost.complete);

    final stages = <String>[];
    final join = WebRtcJoin(invite, create: net.create)..onStage = stages.add;
    final guest = await join.connect().timeout(const Duration(seconds: 5));
    final hostSide = await atHost.future.timeout(const Duration(seconds: 2));

    final got = next(hostSide);
    await guest.send(Uint8List.fromList([1, 2, 3]));
    expect(await got, [1, 2, 3]);
    final back = next(guest);
    await hostSide.send(Uint8List.fromList([9]));
    expect(await back, [9]);
    expect(events.where((e) => e.contains('connected')), isNotEmpty);
    expect(stages.last, contains('Connected'));
    await guest.close();
    await hostSide.close();
  });

  test('a guest asks for as long as it takes, and one connection is made however often it asks', () async {
    final host = await startHost();
    var arrivals = 0;
    host.incoming.listen((_) => arrivals++);
    final join = WebRtcJoin(invite, create: net.create);
    final guest = await join.connect().timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(arrivals, 1);
    expect(net.made.length, 2, reason: 'one connection at each end');
    await guest.close();
  });

  test('nobody hosting is told after a short while, not after the whole time to connect', () async {
    final join = WebRtcJoin(invite, create: net.create, hostSilence: const Duration(milliseconds: 300), timeout: const Duration(seconds: 20));
    final started = DateTime.now();
    await expectLater(join.connect(), throwsA(predicate((e) => '$e'.contains('did not answer'))));
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)));
  });

  test('an unreachable signalling server fails the guest at once and leaves nothing open', () async {
    await server.stop();
    final join = WebRtcJoin(invite, create: net.create);
    await expectLater(join.connect(), throwsA(anything));
    expect(net.made, isEmpty);
  });

  test('the connections of a host are closed with it, and the guests notice', () async {
    final host = await startHost();
    final join = WebRtcJoin(invite, create: net.create);
    final guest = await join.connect().timeout(const Duration(seconds: 5));
    await host.close();
    cleanup.remove(host.close);
    await guest.closed.timeout(const Duration(seconds: 2)); // (the guest notices)
    expect(net.made.first.closed, isTrue, reason: 'the connection of the host is closed with it');
    await guest.close();
  });
}
