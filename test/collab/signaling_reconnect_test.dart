import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/signaling.dart';
import 'package:notes/collab/signaling_server.dart';

void main() {
  test('a persistent signalling connection comes back by itself and when woken, and keeps its stream', () async {
    var server = SignalingServer(port: 0);
    await server.start(address: InternetAddress.loopbackIPv4);
    final port = server.boundPort;
    final invite = SessionInvite.create('ws://127.0.0.1:$port', random: Random(3));
    final host = SignalingClient(invite, persistent: true);
    final guest = SignalingClient(invite);
    await host.connect();
    await guest.connect();
    final got = <String>[];
    host.messages.listen((m) => got.add(m['t'] as String));

    await guest.send({'t': 'one'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(got, ['one']);

    // the server goes away (the phone lost its network) and comes back on the same address
    await server.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server = SignalingServer(port: port);
    await server.start(address: InternetAddress.loopbackIPv4);
    final guest2 = SignalingClient(invite);
    await guest2.connect();

    host.wake(); // the app came back to the front
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await guest2.send({'t': 'two'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(got, ['one', 'two']);

    await host.close();
    await guest.close();
    await guest2.close();
    await server.stop();
  });
}
