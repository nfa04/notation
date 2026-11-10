import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/roster.dart';
import 'package:notes/collab/session_keys.dart';

Uint8List seed(int n) => Uint8List.fromList(List.generate(32, (i) => (n * 7 + i) & 0xff));

void main() {
  late SessionKeys host, ben, mallory;

  setUpAll(() async {
    host = await SessionKeys.fromSeed(seed(1));
    ben = await SessionKeys.fromSeed(seed(2));
    mallory = await SessionKeys.fromSeed(seed(3));
  });

  group('keys', () {
    test('the same seed is the same key, another seed another key', () async {
      expect((await SessionKeys.fromSeed(seed(1))).publicKeyText, host.publicKeyText);
      expect(ben.publicKeyText, isNot(host.publicKeyText));
      expect(host.publicKey.length, 32);
    });

    test('a signature checks with the key that made it, and with no other, and not for another message', () async {
      final sig = await host.sign(utf8.encode('hello'));
      expect(await SessionKeys.verify(host.publicKey, utf8.encode('hello'), sig), isTrue);
      expect(await SessionKeys.verify(ben.publicKey, utf8.encode('hello'), sig), isFalse);
      expect(await SessionKeys.verify(host.publicKey, utf8.encode('hellO'), sig), isFalse);
      final bent = Uint8List.fromList(sig)..[10] ^= 1;
      expect(await SessionKeys.verify(host.publicKey, utf8.encode('hello'), bent), isFalse);
    });

    test('what is not a key or a signature is false, not an error', () async {
      expect(await SessionKeys.verify(Uint8List(5), [1], Uint8List(64)), isFalse);
      expect(await SessionKeys.verify(host.publicKey, [1], Uint8List(3)), isFalse);
      expect(await SessionKeys.verifyText(null, [1], 'x'), isFalse);
      expect(await SessionKeys.verifyText(host.publicKeyText, [1], null), isFalse);
      expect(await SessionKeys.verifyText('%%%not base64', [1], 'also not'), isFalse);
    });

    test('the proof of a join is for that site, that request and that key only', () async {
      final proof = await ben.sign(SessionKeys.joinProof('site-b', 'nonce1', ben.publicKeyText));
      expect(await SessionKeys.verify(ben.publicKey, SessionKeys.joinProof('site-b', 'nonce1', ben.publicKeyText), proof), isTrue);
      expect(await SessionKeys.verify(ben.publicKey, SessionKeys.joinProof('site-x', 'nonce1', ben.publicKeyText), proof), isFalse, reason: 'another site');
      expect(await SessionKeys.verify(ben.publicKey, SessionKeys.joinProof('site-b', 'nonce2', ben.publicKeyText), proof), isFalse, reason: 'another request');
      expect(await SessionKeys.verify(ben.publicKey, SessionKeys.joinProof('site-b', 'nonce1', mallory.publicKeyText), proof), isFalse, reason: 'another key');
    });
  });

  group('roster', () {
    Future<Roster> make({int epoch = 1, int rev = 0, List<RosterMember>? members}) => Roster.make(
          keys: host,
          epoch: epoch,
          rev: rev,
          hostSite: 'H',
          members: members ?? [RosterMember('b', ben.publicKeyText)],
        );

    test('a roster the host made checks, also after it went through JSON', () async {
      final r = await make();
      expect(await r.verify(), isTrue);
      expect(await r.signedBy(host.publicKeyText), isTrue);
      final back = Roster.fromJson(jsonDecode(jsonEncode(r.toJson())));
      expect(back, isNotNull);
      expect(await back!.signedBy(host.publicKeyText), isTrue);
      expect(back.members.single.site, 'b');
      expect(back.succession, ['b']);
    });

    test('a roster signed by somebody else is not the host\'s, even if it says it is', () async {
      final forged = await Roster.make(keys: mallory, epoch: 1, rev: 0, hostSite: 'H', members: [RosterMember('m', mallory.publicKeyText)]);
      expect(await forged.verify(), isTrue, reason: 'it is consistent in itself...');
      expect(await forged.signedBy(host.publicKeyText), isFalse, reason: '...but not signed by the host key that is trusted');
      // and the host's key put on mallory's signature does not check
      final stolen = Roster(epoch: 1, rev: 0, hostSite: 'H', hostKey: host.publicKeyText, members: forged.members, succession: forged.succession, signature: forged.signature);
      expect(await stolen.verify(), isFalse);
    });

    test('every part is signed: changing any one of them breaks it', () async {
      final r = await make(members: [RosterMember('b', ben.publicKeyText), RosterMember('c', null)]);
      Roster with_({int? epoch, int? rev, String? hostSite, List<RosterMember>? members, List<String>? succession}) => Roster(
            epoch: epoch ?? r.epoch,
            rev: rev ?? r.rev,
            hostSite: hostSite ?? r.hostSite,
            hostKey: r.hostKey,
            members: members ?? r.members,
            succession: succession ?? r.succession,
            signature: r.signature,
          );
      expect(await with_().verify(), isTrue);
      expect(await with_(epoch: 2).verify(), isFalse);
      expect(await with_(rev: 1).verify(), isFalse);
      expect(await with_(hostSite: 'X').verify(), isFalse);
      expect(await with_(members: [RosterMember('b', mallory.publicKeyText), const RosterMember('c', null)]).verify(), isFalse, reason: 'a key swapped');
      expect(await with_(members: [r.members.last, r.members.first]).verify(), isFalse, reason: 'the order is the seniority');
      expect(await with_(succession: const []).verify(), isFalse);
      expect(await with_(members: [RosterMember('b', ben.publicKeyText, web: true), const RosterMember('c', null)]).verify(), isFalse,
          reason: 'whether a device is a web page is signed too');
    });

    test('a member that is a web page stays one through JSON; an older roster (no mark) reads as not', () async {
      final r = await make(members: [RosterMember('b', ben.publicKeyText, web: true), const RosterMember('c', null)]);
      final back = Roster.fromJson(jsonDecode(jsonEncode(r.toJson())))!;
      expect(back.member('b')!.web, isTrue);
      expect(back.member('c')!.web, isFalse);
      expect(await back.signedBy(host.publicKeyText), isTrue);
      expect(RosterMember.fromJson(['x', null, 2]), isNull, reason: 'only 1 marks a web page');
      expect(RosterMember.fromJson(['x', null, 1, 1]), isNull);
    });

    test('succession: the oldest devices with a key, at most three, never the host or one without a key', () {
      final members = [
        const RosterMember('old-app', null),
        RosterMember('a', ben.publicKeyText),
        RosterMember('b', ben.publicKeyText),
        RosterMember('H', host.publicKeyText),
        RosterMember('c', ben.publicKeyText),
        RosterMember('d', ben.publicKeyText),
      ];
      expect(Roster.successionOf(members, except: 'H'), ['a', 'b', 'c']);
      expect(Roster.successionOf(const [RosterMember('x', null)]), isEmpty);
      expect(Roster.successionOf(const []), isEmpty);
    });

    test('the later roster is the newer one: a later host first, then more changes', () async {
      final a = await make(epoch: 1, rev: 5), b = await make(epoch: 1, rev: 6), c = await make(epoch: 2, rev: 0);
      expect(b.newerThan(a), isTrue);
      expect(a.newerThan(b), isFalse);
      expect(c.newerThan(b), isTrue, reason: 'a later host, whatever the changes of the one before');
      expect(a.newerThan(a), isFalse);
    });

    test('what is not a roster is null: wrong shapes, too many, twice the same, a successor who is not there or has no key', () async {
      final good = (await make(members: [RosterMember('b', ben.publicKeyText), const RosterMember('c', null)])).toJson();
      expect(Roster.fromJson(good), isNotNull);
      Object? changed(void Function(Map<String, Object?>) f) {
        final j = jsonDecode(jsonEncode(good)) as Map<String, Object?>;
        f(j);
        return j;
      }

      expect(Roster.fromJson(null), isNull);
      expect(Roster.fromJson('x'), isNull);
      expect(Roster.fromJson(changed((j) => j['e'] = 0)), isNull);
      expect(Roster.fromJson(changed((j) => j['e'] = '1')), isNull);
      expect(Roster.fromJson(changed((j) => j.remove('sig'))), isNull);
      expect(Roster.fromJson(changed((j) => j['m'] = [for (var i = 0; i < Roster.maxMembers + 1; i++) ['s$i', null]])), isNull);
      expect(Roster.fromJson(changed((j) => j['m'] = [['b', null], ['b', null]])), isNull);
      expect(Roster.fromJson(changed((j) => j['m'] = [['H', null]])), isNull, reason: 'the host is not its own member');
      expect(Roster.fromJson(changed((j) => j['s'] = ['nobody'])), isNull);
      expect(Roster.fromJson(changed((j) => j['s'] = ['c'])), isNull, reason: 'no key: cannot take over');
      expect(Roster.fromJson(changed((j) => j['s'] = ['b', 'b'])), isNull);
      expect(Roster.fromJson(changed((j) => j['m'] = [['b', 5]])), isNull);
    });

    test('members can be looked up by site', () async {
      final r = await make(members: [RosterMember('b', ben.publicKeyText), const RosterMember('c', null)]);
      expect(r.member('b')!.key, ben.publicKeyText);
      expect(r.member('c')!.key, isNull);
      expect(r.member('zzz'), isNull);
    });
  });
}
