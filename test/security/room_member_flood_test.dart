// A device that knows the secret of a profile but is not one of its devices (a removed device, a leaked link) can still send into the
// room. It cannot read anything, but it must not be able to make the other devices hold on to memory without end.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/devicesync/peer_linker.dart';

import '../devicesync/fake_rtc.dart';

class _Room implements SignalChannel {
  final in_ = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get messages => in_.stream;
  @override
  Future<void> send(Map<String, Object?> message) async {}
  @override
  Future<List<Map<String, Object>>> relayServers() async => const [];
}

void main() {
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('offers from many made-up devices are answered only up to a limit', () async {
    final room = _Room();
    final net = FakeRtcNet();
    final linker = WebRtcLinker(room, 'me', create: net.create);
    addTearDown(() async {
      await linker.close();
      await room.in_.close();
    });
    // (offers that are real, as a device that knows the secret can make them)
    final others = FakeRtcNet();
    for (var i = 0; i < 200; i++) {
      final offer = await (await others.create({})).createOffer();
      room.in_.add({'t': 'offer', 'from': 'fake$i', 'to': 'me', 'c#': 'c', 'sdp': offer.sdp, 'type': offer.type});
    }
    await settle();
    expect(linker.connectionCount, lessThanOrEqualTo(32));
    expect(net.made.length, lessThanOrEqualTo(32));
  });

  test('a description of connection or an id that is huge is dropped', () async {
    final room = _Room();
    final net = FakeRtcNet();
    final linker = WebRtcLinker(room, 'me', create: net.create);
    addTearDown(() async {
      await linker.close();
      await room.in_.close();
    });
    room.in_.add({'t': 'offer', 'from': 'x', 'to': 'me', 'c#': 'c', 'sdp': 'a' * (200 * 1024), 'type': 'offer'});
    room.in_.add({'t': 'offer', 'from': 'y' * 1000, 'to': 'me', 'c#': 'c', 'sdp': 'v=0', 'type': 'offer'});
    room.in_.add({'t': 'offer', 'from': 'z', 'to': 'me', 'c#': 'c' * 1000, 'sdp': 'v=0', 'type': 'offer'});
    await settle();
    expect(net.made, isEmpty);
  });

  test('candidates for offers that never come do not pile up', () async {
    final room = _Room();
    final linker = WebRtcLinker(room, 'me', create: FakeRtcNet().create);
    addTearDown(() async {
      await linker.close();
      await room.in_.close();
    });
    for (var i = 0; i < 5000; i++) {
      room.in_.add({'t': 'ice', 'from': 'fake$i', 'to': 'me', 'c#': 'c', 'c': 'candidate:$i', 'mid': '0', 'idx': 0});
    }
    await settle();
    expect(linker.connectionCount, 0);
    expect(linker.earlyCandidateKeys, lessThanOrEqualTo(32));
  });
}
