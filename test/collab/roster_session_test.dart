import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/roster.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/session_keys.dart';
import 'package:notes/collab/transport.dart';

import 'flaky_network.dart';

Uint8List seed(int n) => Uint8List.fromList(List.generate(32, (i) => (n * 11 + i) & 0xff));

/// A device that speaks the protocol by hand: an older app (no key), or somebody who knows the invite and a site that is in already.
class RawGuest {
  final SecureBox box;
  final PeerChannel channel;
  final inbox = <Map<String, Object?>>[];
  RawGuest(this.box, this.channel) {
    channel.messages.listen((data) async {
      final m = jsonDecode(utf8.decode(await box.open(data))) as Map;
      inbox.add(m.cast<String, Object?>());
    });
  }

  static Future<RawGuest> connect(LoopbackHub hub, SessionInvite invite) async =>
      RawGuest(SecureBox(invite.messageKey), await hub.guest.connect());

  Future<void> send(Map<String, Object?> m) async => channel.send(await box.seal(Uint8List.fromList(utf8.encode(jsonEncode(m)))));

  Map<String, Object?>? first(String t) => inbox.where((m) => m['t'] == t).firstOrNull;
}

void main() {
  late Directory dir;
  late Random random;
  late LoopbackHub hub;
  late SessionInvite invite;
  late Screen hostScreen;
  late CollabSession host;
  late List<Member> members;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('roster_');
    random = Random(5);
    hub = LoopbackHub();
    invite = SessionInvite.create('ws://localhost:1', random: Random(9));
    hostScreen = Screen(dir);
    host = CollabSession.host(invite, hub.host, hostScreen.binding, name: 'Anna', userId: uidOf(0));
    members = [];
  });

  tearDown(() async {
    for (final m in members) {
      m.link
        ..down = true
        ..silent = false;
      await m.session.end();
      m.session.dispose();
    }
    await host.end();
    host.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<Member> join(String name) async {
    final m = Member(name, Link(hub, random), Screen(dir));
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

  test('a guest is given the roster with the welcome: signed by the host, with its own key in it', () async {
    final ben = await join('Ben');
    final r = ben.session.roster;
    expect(r, isNotNull);
    expect(await r!.verify(), isTrue);
    expect(r.hostSite, host.site);
    expect(r.hostKey, host.roster!.hostKey);
    expect(r.epoch, 1);
    expect(r.members.map((m) => m.site), [ben.session.site]);
    expect(r.members.single.key, isNotNull);
    expect(r.succession, isEmpty, reason: 'nobody is named to take over before the others have measured it (see succession_session_test)');
    expect(identical(host.roster, r), isFalse);
    expect(host.roster!.rev, r.rev);
  });

  test('everybody has the same roster after people came: in the order they were let in, the host never in it', () async {
    for (var i = 0; i < 5; i++) {
      await join('G$i');
    }
    await waitUntil(() => members.every((m) => m.session.roster?.rev == host.roster!.rev), () => 'everybody has revision ${host.roster!.rev}: ${members.map((m) => m.session.roster?.rev).toList()}');
    final sites = [for (final m in members) m.session.site];
    for (final r in [host.roster!, for (final m in members) m.session.roster!]) {
      expect(r.members.map((x) => x.site), sites, reason: 'the order of seniority');
      expect(r.succession, isNot(contains(host.site)));
      expect(await r.signedBy(host.roster!.hostKey), isTrue);
    }
    expect(host.roster!.rev, 5, reason: 'one change for each device let in');
  });

  test('a guest that comes back after a drop is on the roster already: nothing changes, and it is not asked about again', () async {
    final ben = await join('Ben');
    final cleo = await join('Cleo');
    await waitUntil(() => ben.session.roster?.rev == 2, 'Ben has both');
    final rev = host.roster!.rev;
    final key = host.roster!.member(ben.session.site)!.key;
    await ben.link.cut();
    ben.session.wake();
    await waitUntil(() => ben.session.state == SessionState.live && host.participants.length == 3, 'Ben is back');
    expect(host.roster!.rev, rev, reason: 'no new roster for a device that was in');
    expect(host.roster!.member(ben.session.site)!.key, key, reason: 'with the key it had');
    expect(host.pending, isEmpty);
    expect(cleo.session.roster!.rev, rev);
  });

  test('a device of an older app (no key) is let in and listed, but is never named to take over', () async {
    final old = await RawGuest.connect(hub, invite);
    await old.send({'t': 'join', 'site': 'oldsite001', 'name': 'Olga', 'nonce': 'n1'});
    await waitUntil(() => host.pending.length == 1, 'the request of the old app');
    await host.approve(host.pending.single.id);
    await waitUntil(() => old.first('welcome') != null, 'its welcome');
    final r = Roster.fromJson(old.first('welcome')!['roster']);
    expect(r, isNotNull);
    expect(r!.member('oldsite001')!.key, isNull);
    expect(r.succession, isEmpty);
    expect(await r.verify(), isTrue);
    await old.channel.close();
  });

  test('a request in the name of a device that is in already is refused when it has no key, another key, or only a copied proof', () async {
    final ben = await join('Ben');
    final benSite = ben.session.site;
    final benKey = host.roster!.member(benSite)!.key!;
    final mallory = await SessionKeys.fromSeed(seed(7));

    Future<void> tryWith(Map<String, Object?> extra, String why) async {
      final evil = await RawGuest.connect(hub, invite);
      await evil.send({'t': 'join', 'site': benSite, 'name': 'Evil', 'nonce': 'x1', ...extra});
      await evil.channel.closed.timeout(const Duration(seconds: 3), onTimeout: () => fail('$why: the link was not closed'));
      expect(host.pending, isEmpty, reason: why);
    }

    await tryWith({}, 'no key');
    final proof = await mallory.signText(SessionKeys.joinProof(benSite, 'x1', mallory.publicKeyText));
    await tryWith({'key': mallory.publicKeyText, 'kp': proof}, 'another key, properly proven');
    await tryWith({'key': benKey, 'kp': proof}, "Ben's key, the proof of another");
    await tryWith({'key': benKey, 'kp': base64Encode(List.filled(64, 1))}, "Ben's key, a made-up proof");

    // Ben is still there, and nothing about him changed
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(host.participants.where((p) => p.site == benSite).length, 1);
    expect(ben.session.state, SessionState.live);
    expect(host.roster!.member(benSite)!.key, benKey);
  });

  test('a new device with a key that does not check is let in as if it had none', () async {
    final mallory = await SessionKeys.fromSeed(seed(8));
    final other = await SessionKeys.fromSeed(seed(9));
    final raw = await RawGuest.connect(hub, invite);
    final badProof = await other.signText(SessionKeys.joinProof('liar00001', 'n9', mallory.publicKeyText));
    await raw.send({'t': 'join', 'site': 'liar00001', 'name': 'Liar', 'nonce': 'n9', 'key': mallory.publicKeyText, 'kp': badProof});
    await waitUntil(() => host.pending.length == 1, 'the request');
    await host.approve(host.pending.single.id);
    await waitUntil(() => raw.first('welcome') != null, 'welcome');
    expect(Roster.fromJson(raw.first('welcome')!['roster'])!.member('liar00001')!.key, isNull, reason: 'a key it cannot prove is no key');
    await raw.channel.close();
  });

  test('a page message that comes late (older than one taken already) does not undo the newer one, and is not passed on', () async {
    final ben = await join('Ben');
    final raw = await RawGuest.connect(hub, invite);
    await raw.send({'t': 'join', 'site': 'pagesite01', 'name': 'Pia', 'nonce': 'n3'});
    await waitUntil(() => host.pending.length == 1, 'the request');
    await host.approve(host.pending.single.id);
    await waitUntil(() => raw.first('welcome') != null && ben.session.participants.length == 3, 'Pia is in');
    await raw.send({'t': 'at', 'site': 'pagesite01', 'page': 2, 'q': 5});
    await waitUntil(() => host.viewing['pagesite01'] == 2 && ben.session.viewing['pagesite01'] == 2, 'page 2 is known everywhere');
    await raw.send({'t': 'at', 'site': 'pagesite01', 'page': 7, 'q': 3}); // (sent earlier, on a slow way)
    await raw.send({'t': 'at', 'site': 'pagesite01', 'page': 4, 'q': 5}); // (the same number again)
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(host.viewing['pagesite01'], 2);
    expect(ben.session.viewing['pagesite01'], 2, reason: 'not passed on either');
    await raw.send({'t': 'at', 'site': 'pagesite01', 'page': 9, 'q': 6});
    await waitUntil(() => ben.session.viewing['pagesite01'] == 9, 'a newer one is taken and passed on');
    // an older app sends no numbers: its messages are taken as they come
    await raw.send({'t': 'at', 'site': 'pagesite01', 'page': 1});
    await waitUntil(() => ben.session.viewing['pagesite01'] == 1, 'a message with no number');
    await raw.channel.close();
  });

  group('what a guest believes', () {
    late Member ben;
    late Roster held;
    late SessionKeys fakeHost;

    setUp(() async {
      ben = await join('Ben');
      held = ben.session.roster!;
      fakeHost = await SessionKeys.fromSeed(seed(21));
    });

    Future<Roster> make(SessionKeys keys, {int epoch = 1, int rev = 99, String? hostSite, List<RosterMember>? members}) => Roster.make(
          keys: keys,
          epoch: epoch,
          rev: rev,
          hostSite: hostSite ?? host.site,
          members: members ?? held.members,
        );

    test('a roster signed by another key than the host\'s is ignored, though it is newer and in itself right', () async {
      await ben.session.acceptRosterForTest(await make(fakeHost));
      expect(ben.session.roster!.rev, held.rev);
      expect(ben.session.roster!.hostKey, held.hostKey);
    });

    test('a roster that is older, that does not list this device as it is, or that is for another host site is ignored', () async {
      final hostKeys = await SessionKeys.fromSeed(seed(22));
      // (signed with a key that is not the pinned one: only here to show the other reasons stand alone, the next check is the key)
      await ben.session.acceptRosterForTest(await make(hostKeys, rev: 0));
      expect(ben.session.roster!.rev, held.rev);
      await ben.session.acceptRosterForTest(await make(fakeHost, members: [const RosterMember('someone-else', null)]));
      expect(ben.session.roster!.rev, held.rev);
      await ben.session.acceptRosterForTest(await make(fakeHost, hostSite: 'not-the-host'));
      expect(ben.session.roster!.rev, held.rev);
      await ben.session.acceptRosterForTest(null);
      expect(ben.session.roster!.rev, held.rev);
    });

    test('a tampered roster of the real host (a swapped key) is ignored', () async {
      final tampered = Roster(
        epoch: held.epoch,
        rev: held.rev + 1,
        hostSite: held.hostSite,
        hostKey: held.hostKey,
        members: [RosterMember(held.members.first.site, held.members.first.key), const RosterMember('evil', 'AAAA')],
        succession: held.succession,
        signature: held.signature,
      );
      await ben.session.acceptRosterForTest(tampered);
      expect(ben.session.roster!.members.length, 1);
    });

    test('a host that came again with another key is taken as the new host only when it is a restart, and is counted', () async {
      final fresh = await make(fakeHost, epoch: 1, rev: 1);
      await ben.session.acceptRosterForTest(fresh);
      expect(ben.session.hostKeyChanges, 0, reason: 'not announced as a restart: refused');
      await ben.session.acceptRosterForTest(fresh, restarted: true);
      expect(ben.session.hostKeyChanges, 1);
      expect(ben.session.roster!.hostKey, fakeHost.publicKeyText);
    });
  });

  test('when the host app is started again the guests carry on: the new host puts them on a new roster, and they count the change', () async {
    final ben = await join('Ben');
    final firstKey = host.roster!.hostKey;
    await hub.cut();
    await host.end();
    host.dispose();
    members.first.link.down = false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    hub.hostPresent = true;
    final again = CollabSession.host(invite, hub.host, Screen(dir).binding, name: 'Anna')..trust = (_) => true;
    host = again;
    ben.session.wake();
    await waitUntil(() => ben.session.state == SessionState.live && again.participants.length == 2, 'Ben is back with the new host', timeout: const Duration(seconds: 15));
    await waitUntil(() => ben.session.hostKeyChanges == 1, 'the guest noticed the host has another key');
    expect(ben.session.roster!.hostKey, again.roster!.hostKey);
    expect(ben.session.roster!.hostKey, isNot(firstKey));
    expect(again.roster!.members.single.site, ben.session.site);
  });
}
