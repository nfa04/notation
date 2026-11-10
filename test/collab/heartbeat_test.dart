import 'dart:async';
import 'dart:io' show sleep;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/framing.dart';
import 'package:notes/collab/keep_alive.dart';
import 'package:notes/collab/rtc_channel.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/collab/webrtc_linker.dart';

import '../devicesync/fake_rtc.dart';
import '../devicesync/fakes.dart';

/// Whether a link that is silent is noticed - also when nothing says that it broke - and a link that is only quiet, or on a device that
/// does not know the question, is left alone.
void main() {
  group('the questions', () {
    test('a question and its answer are frames that carry no message, and a reader of messages skips them', () {
      for (final c in FrameControl.values) {
        expect(FrameControl.of(c.frame), c);
        expect(Reassembler().add(c.frame), isNull, reason: 'an older app ignores them');
      }
      expect(FrameControl.of(Framer().split(Uint8List(0)).single), isNull, reason: 'an empty message is a message');
      expect(FrameControl.of(Uint8List(3)), isNull);
    });
  });

  group('on a link', () {
    late FakeServer server;
    late FakeRtcNet net;
    late WebRtcLinker laptop, tablet;
    late List<PeerChannel> atTablet;
    final before = RtcChannel.heartbeat;

    setUp(() {
      RtcChannel.heartbeat = const Heartbeat(every: Duration(milliseconds: 40), deadAfter: Duration(milliseconds: 250));
      server = FakeServer();
      net = FakeRtcNet();
      laptop = WebRtcLinker(FakeRoom(server, 'r'), 'aaaa', create: net.create);
      tablet = WebRtcLinker(FakeRoom(server, 'r'), 'bbbb', create: net.create);
      atTablet = [];
      tablet.incoming.listen(atTablet.add);
    });
    tearDown(() async {
      RtcChannel.heartbeat = before;
      await laptop.close();
      await tablet.close();
    });

    Future<(PeerChannel, PeerChannel)> linked() async {
      final mine = await laptop.connect('bbbb');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return (mine, atTablet.single);
    }

    test('the questions are measured and handed on: the time of each answer, and a question that was not answered', () async {
      final (mine, theirs) = await linked();
      expect((mine as WatchedChannel).watching, isTrue);
      final trips = <Duration?>[];
      final sub = (mine as WatchedChannel).roundTrips.listen(trips.add);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(trips.whereType<Duration>().length, greaterThanOrEqualTo(2), reason: 'answered questions');
      expect(trips.whereType<Duration>().every((d) => d >= Duration.zero && d < const Duration(milliseconds: 40)), isTrue);
      net.blackhole = true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(trips.where((d) => d == null), isNotEmpty, reason: 'questions that got no answer');
      await sub.cancel();
      expect((theirs as WatchedChannel).watching, isTrue);
    });

    test('a link with the questions turned off says it does not watch itself', () async {
      RtcChannel.heartbeat = null;
      final (mine, _) = await linked();
      expect((mine as WatchedChannel).watching, isFalse);
    });

    test('a link that goes quiet on both ends is given up by both, though nothing says it broke', () async {
      final (mine, theirs) = await linked();
      await Future<void>.delayed(const Duration(milliseconds: 150)); // (the questions have been answered: it is known that they are)
      net.blackhole = true;
      await mine.closed.timeout(const Duration(seconds: 2));
      await theirs.closed.timeout(const Duration(seconds: 2));
    });

    test('a link with nothing to say stays open, for many times the time it would be given up after', () async {
      final (mine, theirs) = await linked();
      var closed = false;
      unawaited(mine.closed.then((_) => closed = true));
      unawaited(theirs.closed.then((_) => closed = true));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(closed, isFalse);
      final got = theirs.messages.first;
      await mine.send(Uint8List.fromList([4, 2]));
      expect((await got.timeout(const Duration(seconds: 1))).toList(), [4, 2], reason: 'and the questions did not get in the way of messages');
    });

    test('a device that does not know the questions is never taken for dead', () async {
      net.dropControl = true;
      final (mine, theirs) = await linked();
      var closed = false;
      unawaited(mine.closed.then((_) => closed = true));
      unawaited(theirs.closed.then((_) => closed = true));
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(closed, isFalse);
    });
  });

  group('after a long silence of this side', () {
    test('a connection is asked, not given up for what was not heard while the app did not run', () async {
      var pings = 0, dead = 0;
      var answers = false; // (the connection answers once it is asked after the silence)
      late final KeepAlive alive;
      alive = KeepAlive(
        every: const Duration(milliseconds: 40),
        deadAfter: const Duration(milliseconds: 100),
        grace: const Duration(milliseconds: 300),
        ping: () {
          pings++;
          if (answers) alive.heard(pong: true);
        },
        dead: () => dead++,
      )..start();
      alive.heard(pong: true);
      sleep(const Duration(milliseconds: 400)); // (the whole isolate stands still, as an app in the background does)
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(dead, 0, reason: 'what was not heard meanwhile is no reason');
      expect(pings, greaterThan(0));
      answers = true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(dead, 0);
      alive.stop();
    });

    test('and is given up when it does not answer within the grace', () async {
      var dead = 0;
      final alive = KeepAlive(
        every: const Duration(milliseconds: 40),
        deadAfter: const Duration(milliseconds: 100),
        grace: const Duration(milliseconds: 150),
        ping: () {},
        dead: () => dead++,
      )..start();
      alive.heard(pong: true);
      sleep(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(dead, 1);
    });
  });
}
