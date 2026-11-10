import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/link_stats.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';

import 'flaky_network.dart';

/// What the session measures on its links, and what it does with a link that says nothing: with the questions every 100 ms and a link
/// given up after half a second (in the app: 10 s and 35 s).
void main() {
  late Directory dir;
  late Random random;
  late LoopbackHub hub;
  late SessionInvite invite;
  late Screen hostScreen;
  late CollabSession host;
  late List<Member> members;
  final savedEvery = CollabSession.heartbeatEvery, savedDead = CollabSession.heartbeatDeadAfter;

  setUp(() {
    // (what is tested is what is done with the bands, not how fast this machine is: only losses, drops and relays decide here; the times
    // are tested in link_stats_test with a clock of their own)
    LinkStats.timing = LinkTiming.lenient;
    CollabSession.heartbeatEvery = const Duration(milliseconds: 100);
    CollabSession.heartbeatDeadAfter = const Duration(milliseconds: 500);
    dir = Directory.systemTemp.createTempSync('health_');
    random = Random(7);
    hub = LoopbackHub();
    invite = SessionInvite.create('ws://localhost:1', random: Random(9));
    hostScreen = Screen(dir);
    host = CollabSession.host(invite, SlowHost(hub.host, random), hostScreen.binding, name: 'Anna', userId: uidOf(0));
    members = [];
  });

  tearDown(() async {
    LinkStats.timing = const LinkTiming();
    CollabSession.heartbeatEvery = savedEvery;
    CollabSession.heartbeatDeadAfter = savedDead;
    for (final m in members) {
      m.link
        ..down = true
        ..silent = false
        ..deaf = false
        ..mute = false;
      await m.session.end();
      m.session.dispose();
    }
    await host.end();
    host.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<Member> join(String name, {bool relayed = false, bool watched = false}) async {
    final m = Member(name, Link(hub, random)..relayed = relayed..watched = watched, Screen(dir));
    final welcomed = Completer<Welcome>();
    m.session = await CollabSession.join(invite, m.link, name: name, userId: uidOf(members.length + 1), onWelcome: welcomed.complete, imageSaver: m.screen.binding.saveImage);
    await waitUntil(() => host.pending.length == 1, 'the request of $name');
    await host.approve(host.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 5));
    m.screen.note
      ..title = w.note.title
      ..strokes = w.note.strokes;
    m.session.attach(m.screen.binding);
    members.add(m);
    await waitUntil(() => m.session.state == SessionState.live && host.participants.length == members.length + 1, '$name is in');
    return m;
  }

  LinkStats hostSees(Member m) => host.guestLinks[m.session.site]!;

  test('both ends measure the link, and the host tells the others how each guest is doing', () async {
    final ben = await join('Ben');
    final cleo = await join('Cleo');
    await waitUntil(() => hostSees(ben).samples >= 3 && hostSees(cleo).samples >= 3 && ben.session.hostLink.samples >= 3, 'a few answers');
    expect(hostSees(ben).median, isNotNull);
    expect(hostSees(ben).band(DateTime.now()), LinkBand.good);
    expect(host.bandOf(ben.session.site), LinkBand.good);
    expect(ben.session.bandOf(ben.session.site), LinkBand.good, reason: 'its own link');
    expect(ben.session.bandOf(host.site), LinkBand.good, reason: 'the same link');
    await waitUntil(() => ben.session.bandOf(cleo.session.site) == LinkBand.good, 'Ben is told how Cleo is doing (by the host)');
    await waitUntil(() => cleo.session.bandOf(ben.session.site) == LinkBand.good, 'and Cleo how Ben is');
  });

  test('a link that goes quiet in both directions is given up by both ends, and the guest comes back by itself', () async {
    final ben = await join('Ben');
    await waitUntil(() => hostSees(ben).samples >= 3, 'a few answers first (the other end is known to answer)');
    ben.link.silent = true;
    await waitUntil(() => host.participants.length == 1, 'the host gives the quiet link up');
    await waitUntil(() => ben.session.state == SessionState.reconnecting, 'and so does the guest');
    expect(hostSees(ben).dropsTotal, 1);
    expect(ben.session.hostLink.dropsTotal, 1);
    ben.link.silent = false; // (the network is back; nobody calls wake())
    await waitUntil(() => ben.session.state == SessionState.live && host.participants.length == 2, 'the guest is back', timeout: const Duration(seconds: 15));
    expect(host.pending, isEmpty);
  });

  test('a guest that cannot be heard (its messages are lost, it hears the host) is found out by the host', () async {
    final ben = await join('Ben');
    await waitUntil(() => hostSees(ben).samples >= 3, 'a few answers');
    ben.link.mute = true;
    await waitUntil(() => host.participants.length == 1, 'the host stops waiting for it');
  });

  test('a guest that hears nothing (the host is silent to it) finds out by itself', () async {
    final ben = await join('Ben');
    await waitUntil(() => ben.session.hostLink.samples >= 3, 'a few answers');
    ben.link.deaf = true;
    await waitUntil(() => ben.session.state == SessionState.reconnecting, 'the guest gives the link up');
    ben.link.deaf = false;
    await waitUntil(() => ben.session.state == SessionState.live, 'and is back', timeout: const Duration(seconds: 15));
  });

  test('broken links are counted and make the band worse; leaving is not a drop', () async {
    final ben = await join('Ben');
    final cleo = await join('Cleo');
    await waitUntil(() => hostSees(ben).samples >= 5, 'answers');
    await ben.link.cut();
    ben.session.wake();
    await waitUntil(() => ben.session.state == SessionState.live && host.participants.length == 3 && hostSees(ben).dropsTotal == 1, 'Ben is back after one drop');
    await waitUntil(() => hostSees(ben).samples >= 3, 'answers again');
    expect(hostSees(ben).band(DateTime.now()), LinkBand.fair, reason: 'broke lately: not good');
    await waitUntil(() => cleo.session.bandOf(ben.session.site) == LinkBand.fair, 'the others are told');

    await cleo.session.end();
    await waitUntil(() => host.participants.length == 2, 'Cleo has left');
    expect(hostSees(cleo).dropsTotal, 0, reason: 'a goodbye is no drop');
  });

  test('a guest whose link goes through a relay is shown as such, never as good, and the others are told', () async {
    final ben = await join('Ben', relayed: true);
    final cleo = await join('Cleo');
    await waitUntil(() => hostSees(ben).samples >= 4 && hostSees(cleo).samples >= 4, 'answers');
    await waitUntil(() => hostSees(ben).relayed, 'the route is found');
    expect(host.relayedVia(ben.session.site), isTrue);
    expect(host.relayedVia(cleo.session.site), isFalse);
    expect(host.bandOf(ben.session.site), LinkBand.fair, reason: 'answers fast, but costs the relay');
    expect(host.bandOf(cleo.session.site), LinkBand.good);
    await waitUntil(() => ben.session.relayedVia(ben.session.site), 'Ben knows his own link is relayed');
    await waitUntil(() => cleo.session.relayedVia(ben.session.site) && cleo.session.bandOf(ben.session.site) == LinkBand.fair, 'Cleo is told about Ben');
    expect(cleo.session.relayedVia(cleo.session.site), isFalse);
  });

  test('what a device shows of its own situation: a guest its link, the host the worst of its guests', () async {
    final ben = await join('Ben');
    expect(ben.session.hostSite, host.site);
    expect(host.hostSite, host.site);
    expect(host.linkBand, LinkBand.unknown, reason: 'nothing measured yet');
    await waitUntil(() => hostSees(ben).samples >= 3 && ben.session.hostLink.samples >= 3, 'answers');
    expect(ben.session.linkBand, LinkBand.good);
    expect(host.linkBand, LinkBand.good);

    final cleo = await join('Cleo', relayed: true);
    await waitUntil(() => hostSees(cleo).samples >= 4 && hostSees(cleo).relayed, 'Cleo is measured, relayed');
    expect(host.linkBand, LinkBand.fair, reason: 'one that is not good drags it down');
    expect(cleo.session.linkBand, LinkBand.fair);
    expect(ben.session.linkBand, LinkBand.good, reason: 'Ben\'s own link is fine');

    ben.link.down = true; // (and stays away)
    await ben.link.cut();
    await waitUntil(() => host.participants.length == 2, 'Ben is gone');
    expect(ben.session.linkBand, isNot(LinkBand.good));
  });

  group('a link that watches itself (as a WebRTC connection does)', () {
    test('is not asked anything by the session: what the link measured is used, and nothing more is sent', () async {
      final ben = await join('Ben', watched: true);
      await waitUntil(() => hostSees(ben).samples >= 3 && ben.session.hostLink.samples >= 3, 'what the link measured arrives at both ends');
      expect(host.bandOf(ben.session.site), LinkBand.good);
      expect(ben.session.bandOf(ben.session.site), LinkBand.good);
      await Future<void>.delayed(const Duration(milliseconds: 300)); // (the band was told; then all is quiet)
      final before = hub.sent;
      await Future<void>.delayed(const Duration(milliseconds: 600)); // (six times the session's own question would have gone out)
      expect(hub.sent, before, reason: 'no questions of the session on a link that watches itself');
      expect(hostSees(ben).samples, greaterThan(5), reason: 'and it is still measured');
    });

    test('is given up when the link gives it up, not by the session', () async {
      CollabSession.heartbeatDeadAfter = const Duration(hours: 1); // (the session would never give up: the link must)
      final ben = await join('Ben', watched: true);
      await waitUntil(() => hostSees(ben).samples >= 3, 'answers');
      ben.link.silent = true;
      await waitUntil(() => host.participants.length == 1 && ben.session.state == SessionState.reconnecting, 'both ends gave the link up');
      expect(hostSees(ben).loss, greaterThan(0), reason: 'the unanswered questions count');
      ben.link.silent = false;
      await waitUntil(() => ben.session.state == SessionState.live && host.participants.length == 2, 'back by itself', timeout: const Duration(seconds: 15));
      await waitUntil(() => hostSees(ben).dropsTotal == 1, 'one drop');
    });

    test('a relayed one is still shown as relayed', () async {
      final ben = await join('Ben', watched: true, relayed: true);
      await waitUntil(() => hostSees(ben).samples >= 3 && hostSees(ben).relayed, 'measured, relayed');
      expect(host.bandOf(ben.session.site), LinkBand.fair);
    });
  });

  test('a session of 8 keeps measuring, and nobody is wrongly given up while all is well', () async {
    for (var i = 0; i < 8; i++) {
      await join('G$i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500)); // (three times the time a quiet link is given up after)
    expect(host.participants.length, 9);
    for (final m in members) {
      expect(m.session.state, SessionState.live);
      expect(hostSees(m).dropsTotal, 0);
      expect(hostSees(m).band(DateTime.now()), LinkBand.good);
    }
  });
}
