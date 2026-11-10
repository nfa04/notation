import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCSessionDescription;
import 'package:notes/collab/transport.dart';
import 'package:notes/devicesync/peer_linker.dart';

import 'fake_rtc.dart';
import 'fakes.dart';

/// The linker on WebRTC (in memory): the connections it makes between two devices, through the messages of the room.
void main() {
  late FakeServer server;
  late FakeRtcNet net;
  late WebRtcLinker laptop, tablet;
  late List<PeerChannel> atTablet;
  final inboxes = <PeerChannel, List<List<int>>>{};

  setUp(() {
    inboxes.clear();
    server = FakeServer();
    net = FakeRtcNet();
    laptop = WebRtcLinker(FakeRoom(server, 'room'), 'aaaa', create: net.create);
    tablet = WebRtcLinker(FakeRoom(server, 'room'), 'bbbb', create: net.create);
    atTablet = [];
    tablet.incoming.listen(atTablet.add);
  });
  tearDown(() async {
    await laptop.close();
    await tablet.close();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  // (what each line received; a line's messages can be listened to once)
  List<List<int>> inbox(PeerChannel c) => inboxes.putIfAbsent(c, () {
        final got = <List<int>>[];
        c.messages.listen((m) => got.add(m.toList()));
        return got;
      });

  Future<List<int>> roundTrip(PeerChannel mine, PeerChannel theirs, List<int> bytes) async {
    final got = inbox(theirs);
    final before = got.length;
    await mine.send(Uint8List.fromList(bytes));
    final end = DateTime.now().add(const Duration(seconds: 2));
    while (got.length == before && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return got.length > before ? got.last : const [];
  }

  test('a connection is made, and carries messages both ways', () async {
    final line = await laptop.connect('bbbb');
    await settle();
    expect(atTablet, hasLength(1));
    expect(await roundTrip(line, atTablet.single, [1, 2, 3]), [1, 2, 3]);
    expect(await roundTrip(atTablet.single, line, [4]), [4]);
  });

  test('a second connection to the same device leaves the first alone (a sync while a note is worked on live)', () async {
    final live = await laptop.connect('bbbb');
    await settle();
    final sync = await laptop.connect('bbbb');
    await settle();
    expect(atTablet, hasLength(2));
    expect(net.open, 4, reason: 'a connection was closed: ${net.made.map((p) => '${p.id}:${p.closed}')}');
    // each line reaches its own end
    expect(await roundTrip(live, atTablet[0], [1]), [1]);
    expect(await roundTrip(sync, atTablet[1], [2]), [2]);
    // the sync ends; the live line goes on
    await sync.close();
    await settle();
    expect(await roundTrip(live, atTablet[0], [3]), [3]);
    expect(laptop.connectionCount, 1, reason: 'a closed connection is forgotten');
  });

  test('both devices connect to each other at the same time: two connections, both work', () async {
    final atLaptop = <PeerChannel>[];
    laptop.incoming.listen(atLaptop.add);
    final both = await Future.wait([laptop.connect('bbbb'), tablet.connect('aaaa')]);
    await settle();
    expect(atTablet, hasLength(1));
    expect(atLaptop, hasLength(1));
    expect(await roundTrip(both[0], atTablet.single, [5]), [5]);
    expect(await roundTrip(both[1], atLaptop.single, [6]), [6]);
  });

  test('messages of an older app, which has no connection ids, still make a connection', () async {
    final old = <Map<String, Object?>>[];
    // what an older app does: it reads the offer, answers without the id
    final oldRoom = FakeRoom(server, 'room2');
    final newRoom = FakeRoom(server, 'room2');
    final linker = WebRtcLinker(newRoom, 'cccc', create: net.create);
    addTearDown(linker.close);
    oldRoom.messages.listen((m) async {
      old.add(m);
      if (m['t'] == 'offer') {
        final pc = await net.create({});
        await pc.setRemoteDescription(RTCSessionDescription(m['sdp'] as String, m['type'] as String));
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        await oldRoom.send({'t': 'answer', 'from': 'dddd', 'to': 'cccc', 'sdp': answer.sdp, 'type': answer.type});
      }
    });
    final line = await linker.connect('dddd', timeout: const Duration(seconds: 2));
    expect(line, isNotNull);
    expect(old.first['c#'], isA<String>());
  });

  group('on a signalling channel that loses messages', () {
    late FakeRoom laptopRoom, tabletRoom;
    late WebRtcLinker quickLaptop, quickTablet;
    late List<PeerChannel> atQuickTablet;

    setUp(() {
      laptopRoom = FakeRoom(server, 'lossy');
      tabletRoom = FakeRoom(server, 'lossy');
      const quick = Duration(milliseconds: 40);
      quickLaptop = WebRtcLinker(laptopRoom, 'eeee', create: net.create, resendEvery: quick, setupTimeout: const Duration(milliseconds: 300));
      quickTablet = WebRtcLinker(tabletRoom, 'ffff', create: net.create, resendEvery: quick, setupTimeout: const Duration(milliseconds: 300));
      atQuickTablet = [];
      quickTablet.incoming.listen(atQuickTablet.add);
    });
    tearDown(() async {
      await quickLaptop.close();
      await quickTablet.close();
    });

    test('an offer that was lost on the way is sent again, and the connection comes up', () async {
      tabletRoom.drop(); // the other device is not in the room for a moment
      final connecting = quickLaptop.connect('ffff', timeout: const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(atQuickTablet, isEmpty);
      tabletRoom.restore();
      final line = await connecting;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(atQuickTablet, hasLength(1));
      expect(await roundTrip(line, atQuickTablet.single, [7]), [7]);
    });

    test('an answer that was lost is made again for the offer that comes again, without starting over', () async {
      // the offer gets through, and the laptop's connection to the server breaks before the answer comes
      tabletRoom.messages.listen((m) {
        if (m['t'] == 'offer' && !laptopRoom.connected) return;
        if (m['t'] == 'offer') laptopRoom.drop();
      });
      final connecting = quickLaptop.connect('ffff', timeout: const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(laptopRoom.connected, isFalse);
      expect(atQuickTablet, isEmpty);
      laptopRoom.restore();
      final line = await connecting;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(atQuickTablet, hasLength(1), reason: 'one connection, not one for each time the offer came');
      expect(net.made.length, 2, reason: 'one connection at each end; the offer that came again did not make another');
      expect(await roundTrip(line, atQuickTablet.single, [8]), [8]);
    });

    test('an offer that comes twice makes one connection', () async {
      final ghostPc = await net.create({}) as FakePeerConnection;
      final offer = {'t': 'offer', 'from': 'gggg', 'to': 'ffff', 'c#': '01', 'sdp': '${ghostPc.id}\na=fingerprint:sha-256 x', 'type': 'offer'};
      final ghost = FakeRoom(server, 'lossy');
      for (var i = 0; i < 3; i++) {
        await ghost.send(offer);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(quickTablet.connectionCount, 1);
      expect(net.made.length, 2, reason: 'the ghost and one answerer');
    });

    test('a connection that is offered but never opened is closed, not kept for ever', () async {
      final ghostPc = await net.create({}) as FakePeerConnection;
      final ghost = FakeRoom(server, 'lossy');
      await ghost.send({'t': 'offer', 'from': 'gggg', 'to': 'ffff', 'c#': '02', 'sdp': '${ghostPc.id}\na=fingerprint:sha-256 x', 'type': 'offer'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(quickTablet.connectionCount, 1);
      expect(net.made.last.closed, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(quickTablet.connectionCount, 0);
      expect(net.made.last.closed, isTrue);
    });

    test('a connection that cannot be made is closed when the time is up, and says so', () async {
      await expectLater(quickLaptop.connect('nobody', timeout: const Duration(milliseconds: 200)), throwsA(isA<StateError>()));
      expect(quickLaptop.connectionCount, 0);
      expect(net.made.every((p) => p.closed), isTrue);
    });
  });
}
