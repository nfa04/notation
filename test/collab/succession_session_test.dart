import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/link_stats.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/session_keys.dart';
import 'package:notes/collab/succession.dart';
import 'package:notes/collab/transport.dart';

import 'flaky_network.dart';

/// Who the host names to take over, from what everybody measured, and the links the guests keep to those it named. With questions every
/// 100 ms and a list that may change every 300 ms (in the app: 10 s and 10 minutes).
void main() {
  late Directory dir;
  late Random random;
  late LoopbackHub hub;
  late LoopbackWarmNet net;
  late SessionInvite invite;
  late CollabSession host;
  late List<Member> members;
  final saved = (every: CollabSession.heartbeatEvery, dead: CollabSession.heartbeatDeadAfter, hold: Succession.hold, retry: CollabSession.warmRetryAfter);
  final closeLater = <Future<void> Function()>[];

  setUp(() {
    LinkStats.timing = LinkTiming.lenient;
    CollabSession.heartbeatEvery = const Duration(milliseconds: 100);
    CollabSession.heartbeatDeadAfter = const Duration(milliseconds: 600);
    CollabSession.warmRetryAfter = const Duration(milliseconds: 200);
    Succession.hold = const Duration(milliseconds: 300);
    dir = Directory.systemTemp.createTempSync('succession_');
    random = Random(3);
    hub = LoopbackHub();
    net = LoopbackWarmNet();
    invite = SessionInvite.create('ws://localhost:1', random: Random(9));
    host = CollabSession.host(invite, SlowHost(hub.host, random), Screen(dir).binding, name: 'Anna', userId: uidOf(0));
    members = [];
  });

  tearDown(() async {
    for (final c in closeLater) {
      await c();
    }
    closeLater.clear();
    for (final m in members) {
      m.link
        ..down = true
        ..silent = false;
      await m.session.end();
      m.session.dispose();
    }
    await host.end();
    host.dispose();
    LinkStats.timing = const LinkTiming();
    CollabSession.heartbeatEvery = saved.every;
    CollabSession.heartbeatDeadAfter = saved.dead;
    CollabSession.warmRetryAfter = saved.retry;
    Succession.hold = saved.hold;
    dir.deleteSync(recursive: true);
  });

  Future<Member> join(String name, {bool relayed = false, bool web = false, ValueNotifier<String?>? budget}) async {
    final m = Member(name, Link(hub, random)..relayed = relayed, Screen(dir));
    final welcomed = Completer<Welcome>();
    m.session = await CollabSession.join(invite, m.link,
        name: name, userId: uidOf(members.length + 1), onWelcome: welcomed.complete, imageSaver: m.screen.binding.saveImage, warmNet: net, web: web, budget: budget);
    await waitUntil(() => host.pending.length == 1, 'the request of $name');
    await host.approve(host.pending.single.id);
    await welcomed.future.timeout(const Duration(seconds: 5));
    members.add(m);
    await waitUntil(() => m.session.state == SessionState.live && host.participants.any((p) => p.site == m.session.site), '$name is in');
    return m;
  }

  String names(Iterable<String> sites) => [for (final s in sites) members.where((m) => m.session.site == s).firstOrNull?.name ?? s].join(', ');
  String siteOf(Member m) => m.session.site;
  bool everybodyHas(List<String> list) => members.every((m) => m.session.state != SessionState.live || _same(m.session.succession, list));

  test('the first two named are reached by every other guest; they measure them and tell the host, who judges by the median', () async {
    final g = [for (var i = 1; i <= 4; i++) await join('G$i')];
    final expected = [for (final m in g.take(3)) siteOf(m)];
    await waitUntil(() => _same(host.succession, expected) && everybodyHas(expected), () => 'the three oldest, everywhere: ${names(host.succession)}');
    final first = siteOf(g[0]), second = siteOf(g[1]);
    await waitUntil(
      () =>
          g[0].session.listensAsSuccessor &&
          g[1].session.listensAsSuccessor &&
          !g[2].session.listensAsSuccessor &&
          _same(g[0].session.warmLinks.toList(), [second]) &&
          _same(g[1].session.warmLinks.toList(), [first]) &&
          _sameSet(g[2].session.warmLinks, {first, second}) &&
          _sameSet(g[3].session.warmLinks, {first, second}) &&
          g[0].session.warmIncoming == 3 &&
          g[1].session.warmIncoming == 3,
      () => 'links: ${[for (final m in g) '${m.name} -> ${names(m.session.warmLinks)} (${m.session.warmIncoming} in)'].join('; ')}',
    );
    await waitUntil(() => (g[3].session.warmStatsOf(first)?.samples ?? 0) >= 3, 'G4 measured G1');
    expect(net.listens(siteOf(g[2])), isFalse, reason: 'the third is named, but nobody keeps a link to it');
    await waitUntil(() => host.scoreOf(first).band == LinkBand.good && host.scoreOf(second).band == LinkBand.good, 'the host has a score for both');
  });

  test('direct ones first, then the one reached through a relay; a web page not at all while there are two others', () async {
    final web = await join('Web', web: true);
    final far = await join('Far', relayed: true);
    final b = await join('B');
    final c = await join('C');
    expect(host.roster!.member(siteOf(web))!.web, isTrue);
    expect(host.roster!.member(siteOf(b))!.web, isFalse);
    final expected = [siteOf(b), siteOf(c), siteOf(far)];
    await waitUntil(() => _same(host.succession, expected) && everybodyHas(expected), () => 'B, C, Far: ${names(host.succession)}');
    // and it stays so
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(names(host.succession), names(expected));
  });

  test('a guest that leaves is replaced at once, and the links follow', () async {
    final g = [for (var i = 1; i <= 4; i++) await join('G$i')];
    await waitUntil(() => _same(host.succession, [for (final m in g.take(3)) siteOf(m)]), 'the three oldest');
    await waitUntil(() => g[3].session.warmLinks.length == 2, 'G4 reaches the first two');
    await g[0].session.end();
    final expected = [for (final m in g.skip(1)) siteOf(m)];
    await waitUntil(() => _same(host.succession, expected), () => 'G2, G3, G4: ${names(host.succession)}');
    await waitUntil(
      () =>
          !net.listens(siteOf(g[0])) &&
          g[2].session.listensAsSuccessor &&
          _sameSet(g[3].session.warmLinks, {siteOf(g[1]), siteOf(g[2])}) &&
          _same(g[1].session.warmLinks.toList(), [siteOf(g[2])]),
      () => 'links: ${[for (final m in g.skip(1)) '${m.name} -> ${names(m.session.warmLinks)}'].join('; ')}',
    );
  });

  test('a guest whose battery runs low (or that is on a metered network) rules itself out, at once, and back in later', () async {
    final low = ValueNotifier<String?>('metered');
    final b1 = ValueNotifier<String?>(null);
    final g1 = await join('G1', budget: b1);
    final m = await join('M', budget: low);
    final g = [g1, for (var i = 2; i <= 3; i++) await join('G$i')];
    expect(host.vetoOf(siteOf(m)), 'metered', reason: 'said in the request to join');
    await waitUntil(() => _same(host.succession, [for (final x in g) siteOf(x)]), () => 'G1, G2, G3, not M: ${names(host.succession)}');
    // G1's battery runs low: off the list at once, and M (still metered) does not take the place
    b1.value = 'battery';
    final without = [siteOf(g[1]), siteOf(g[2])];
    await waitUntil(() => _same(host.succession, without) && everybodyHas(without), () => 'G2, G3: ${names(host.succession)}');
    expect(host.vetoOf(siteOf(g1)), 'battery');
    await waitUntil(() => !g1.session.listensAsSuccessor && !net.listens(siteOf(g1)), 'G1 no longer waits for links');
    // M is on Wi-Fi now: it fills the place (as the older of the three, first), but only once it has not said "metered" for a while
    low.value = null;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.succession, isNot(contains(siteOf(m))), reason: 'it said so a moment ago');
    await waitUntil(() => _same(host.succession, [siteOf(m), ...without]), () => 'M, G2, G3: ${names(host.succession)}');
    // G1 is charging: back in its place, as the oldest, when the list may change
    b1.value = null;
    await waitUntil(() => _same(host.succession, [siteOf(g1), siteOf(m), siteOf(g[1])]), () => 'G1, M, G2: ${names(host.succession)}');
    expect(host.vetoOf(siteOf(g1)), isNull);
  });

  test('a member that says it is good, does not answer, and says the others are poor: not named, and the others stay', () async {
    final liar = await _Liar.join(hub, invite, host);
    closeLater.add(liar.close);
    final g = [for (var i = 1; i <= 3; i++) await join('G$i')];
    final expected = [for (final m in g) siteOf(m)];
    await waitUntil(() => _same(host.succession, expected), () => 'G1, G2, G3: ${names(host.succession)}');
    // (the honest guests' links to the first two measure before the lies start: with only the host's measurement and a lie, the worse of
    // the two would count - in the app the list holds 10 minutes meanwhile, here a moment)
    await waitUntil(() => g[2].session.warmLinks.length == 2 && [for (final m in g.take(2)) (g[2].session.warmStatsOf(siteOf(m))?.samples ?? 0) >= 3].every((x) => x),
        'G3 measured the first two');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // it tells the host the best of itself and the worst of the first two, over and over
    for (var i = 0; i < 20; i++) {
      await liar.send({
        't': 'obs',
        'o': {
          liar.site: {'b': 'good'},
          for (final m in g.take(2)) siteOf(m): {'b': 'poor'},
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(names(host.succession), names(expected), reason: 'three honest measurements against one lie');
    expect(host.scoreOf(siteOf(g[0])).band, LinkBand.good);
    expect(host.succession, isNot(contains(liar.site)));
    expect(host.scoreOf(liar.site).band, isNot(LinkBand.good), reason: 'what it says of itself does not count');
  });

  test('somebody else that answers in the place of a successor cannot show its key: nothing is measured on that link', () async {
    final g = [for (var i = 1; i <= 3; i++) await join('G$i')];
    await waitUntil(() => _same(host.succession, [for (final m in g) siteOf(m)]), 'the three oldest');
    final first = siteOf(g[0]);
    // a member of the session (it knows the invite) waits in the first successor's place
    final mallory = await SessionKeys.fromSeed(Uint8List.fromList(List.filled(32, 7)));
    final box = SecureBox(invite.messageKey);
    var asked = 0;
    final sub = net.takeOver(first).listen((channel) {
      channel.messages.listen((data) async {
        final m = jsonDecode(utf8.decode(await box.open(data))) as Map;
        if (m['t'] != 'warm') return;
        asked++;
        // the right words, the right link: signed with a key that is not G1's
        final sig = await mallory.signText(SessionKeys.linkProof(first, m['site'] as String, m['n'] as String, await channel.binding()));
        await channel.send(await box.seal(Uint8List.fromList(utf8.encode(jsonEncode({'t': 'warmok', 'sig': sig})))));
      });
    });
    closeLater.add(sub.cancel);
    final late = await join('G4');
    await waitUntil(() => asked >= 2, 'G4 tried the impostor, and again later');
    await waitUntil(() => late.session.warmLinks.contains(siteOf(g[1])), 'G4 reaches the second, who is real');
    expect(late.session.warmLinks, isNot(contains(first)));
    expect(late.session.warmStatsOf(first), isNull, reason: 'nothing measured on the impostor\'s link');
  });
}

bool _same(List<String> a, List<String> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

/// A member with a key that speaks the protocol by hand: it never answers the host's questions, and says what it likes.
class _Liar {
  final SecureBox box;
  final PeerChannel channel;
  final String site = 'liar000001';
  _Liar(this.box, this.channel);

  static Future<_Liar> join(LoopbackHub hub, SessionInvite invite, CollabSession host) async {
    final l = _Liar(SecureBox(invite.messageKey), await hub.guest.connect());
    final welcomed = Completer<void>();
    l.channel.messages.listen((data) async {
      final m = jsonDecode(utf8.decode(await l.box.open(data))) as Map;
      if (m['t'] == 'welcome' && !welcomed.isCompleted) welcomed.complete();
    });
    final keys = await SessionKeys.fromSeed(Uint8List.fromList(List.filled(32, 3)));
    await l.send({'t': 'join', 'site': l.site, 'name': 'Liar', 'nonce': 'n1', 'key': keys.publicKeyText, 'kp': await keys.signText(SessionKeys.joinProof(l.site, 'n1', keys.publicKeyText))});
    await waitUntil(() => host.pending.length == 1, 'the request of the liar');
    await host.approve(host.pending.single.id);
    await welcomed.future.timeout(const Duration(seconds: 5));
    return l;
  }

  Future<void> send(Map<String, Object?> m) async => channel.send(await box.seal(Uint8List.fromList(utf8.encode(jsonEncode(m)))));

  Future<void> close() => channel.close();
}
