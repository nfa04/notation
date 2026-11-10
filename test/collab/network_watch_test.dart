import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/network_watch.dart';

void main() {
  late StreamController<Set<String>> networks;
  late int changes;
  late NetworkWatch watch;

  setUp(() {
    networks = StreamController<Set<String>>();
    changes = 0;
    watch = NetworkWatch(networks.stream, () => changes++, settle: const Duration(milliseconds: 30));
  });
  tearDown(() {
    watch.dispose();
    networks.close();
  });

  Future<void> report(Set<String> n) async {
    networks.add(n);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  test('the first report is how things are, not a change', () async {
    await report({'wifi'});
    expect(changes, 0);
  });

  test('from the mobile network to Wi-Fi, and back: each is a change', () async {
    await report({'mobile'});
    await report({'wifi'});
    expect(changes, 1);
    await report({'mobile'});
    expect(changes, 2);
  });

  test('Wi-Fi coming up beside the mobile network changes nothing; the mobile network going away then does', () async {
    await report({'mobile'});
    await report({'mobile', 'wifi'});
    expect(changes, 0, reason: 'the old way still works');
    await report({'wifi'});
    expect(changes, 1);
  });

  test('no network is no change to act on; the network that comes back is', () async {
    await report({'wifi'});
    await report({'none'});
    expect(changes, 0);
    await report({'wifi'});
    expect(changes, 1, reason: 'back on the same network, the connections from before are gone all the same');
  });

  test('the same report twice, and a hand-over that comes as several reports, count once', () async {
    await report({'wifi'});
    await report({'wifi'});
    expect(changes, 0);
    networks.add({'none'});
    networks.add({'mobile'});
    networks.add({'mobile', 'wifi'});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(changes, 1);
  });

  test('a system that cannot tell (the stream fails) is no news', () async {
    networks.addError(StateError('no network manager'));
    await report({'wifi'});
    expect(changes, 0);
  });

  test('a plugin that fails when it is listened to is not an unhandled error, and a working one is watched', () async {
    // (what connectivity_plus does on Linux without NetworkManager: the error comes from an async onListen, not from the stream)
    Stream<Set<String>> broken() => (StreamController<Set<String>>.broadcast(onListen: () async => throw StateError('no system bus'))).stream;
    final guarded = NetworkWatch.guarded(broken, () {});
    await Future<void>.delayed(const Duration(milliseconds: 30)); // (an unhandled error would fail this test)
    guarded.dispose();

    final working = StreamController<Set<String>>();
    var n = 0;
    final watching = NetworkWatch.guarded(() => working.stream, () => n++, settle: const Duration(milliseconds: 30));
    working.add({'mobile'});
    working.add({'wifi'});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(n, 1);
    watching.dispose();
    await working.close();
  });
}
