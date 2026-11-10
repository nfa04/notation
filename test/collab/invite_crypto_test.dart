import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/framing.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/secure_box.dart';

void main() {
  group('the invite link', () {
    final invite = SessionInvite.create('wss://signal.example.org/live', from: 'Anna K.', random: Random(1));

    test('is a link that opens the app, with the secret after the #', () {
      final link = invite.toLink();
      expect(link, startsWith('notation://join?'));
      expect(link.split('#').first, isNot(contains(RegExp(r'[A-Za-z0-9_-]{40}'))));
      expect(link, contains('#'));
      final back = SessionInvite.parse(link)!;
      expect(back.server, 'wss://signal.example.org/live');
      expect(back.from, 'Anna K.');
      expect(back.secret, invite.secret);
    });

    test('is found in a message around it, and in a web address with the same parts', () {
      final link = invite.toLink();
      expect(SessionInvite.parse('Join me!\n$link\nsee you')!.secret, invite.secret);
      final web = 'https://example.org/join?s=wss%3A%2F%2Fsignal.example.org%2Flive#${link.split('#').last}';
      expect(SessionInvite.parse(web)!.server, 'wss://signal.example.org/live');
    });

    test('anything else is not an invite', () {
      for (final bad in [
        '',
        'hello',
        'notation://join?s=wss://x',
        'notation://join?s=wss://x#short',
        'notation://open?s=wss://x#AAAA',
        'notation://join?s=http://x#${'A' * 43}',
        'https://example.org/page#abc',
      ]) {
        expect(SessionInvite.parse(bad), isNull, reason: bad);
      }
    });

    test('the room name, the key and the code come from the secret and do not give it away', () {
      expect(invite.room.length, 32);
      expect(invite.room, SessionInvite(invite.server, invite.secret).room);
      expect(invite.messageKey.length, 32);
      expect(invite.room, isNot(invite.messageKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, 32)));
      final other = SessionInvite.create(invite.server, random: Random(2));
      expect(other.room, isNot(invite.room));
      expect(other.messageKey, isNot(invite.messageKey));
    });

    test('the verification code is the same on both sides, different each time, and needs the secret', () {
      final code = invite.verificationCode('nonce-host', 'nonce-join');
      expect(code, matches(RegExp(r'^\d{3} \d{3}$')));
      expect(SessionInvite(invite.server, invite.secret).verificationCode('nonce-host', 'nonce-join'), code);
      expect(invite.verificationCode('nonce-host', 'another'), isNot(code));
      expect(SessionInvite.create(invite.server, random: Random(3)).verificationCode('nonce-host', 'nonce-join'), isNot(code));
    });
  });

  group('sealed messages', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final box = SecureBox(key);

    test('open with the key, and are not readable without it', () async {
      final plain = Uint8List.fromList('a note about secrets'.codeUnits);
      final sealed = await box.seal(plain);
      expect(sealed.length, plain.length + 24 + 16);
      expect(String.fromCharCodes(sealed), isNot(contains('secrets')));
      expect(await box.open(sealed), plain);
      expect(await box.seal(plain), isNot(sealed)); // a nonce of its own each time
      await expectLater(SecureBox(Uint8List(32)).open(sealed), throwsA(isA<SecretBoxAuthenticationError>()));
    });

    test('a big file is sealed and opened apart from the screen, with the same result as in place', () async {
      final big = Uint8List.fromList(List.generate(sealApartFrom + 1000, (i) => i % 251));
      final sealed = await sealApart(key, big);
      expect(sealed.length, big.length + 24 + 16);
      expect(await box.open(sealed), big, reason: 'opens in place');
      expect(await openApart(key, sealed), big);
      expect(await openApart(key, await box.seal(Uint8List.fromList([1, 2, 3]))), [1, 2, 3], reason: 'small ones too');
      sealed[100] ^= 1;
      await expectLater(openApart(key, sealed), throwsA(anything));
    });

    test('a message that was changed does not open', () async {
      final sealed = await box.seal(Uint8List.fromList([1, 2, 3, 4, 5]));
      sealed[30] ^= 1;
      await expectLater(box.open(sealed), throwsA(isA<SecretBoxAuthenticationError>()));
    });
  });

  group('frames', () {
    Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (i) => i % 251));

    test('a big message is cut up and put together again, a small one is one frame', () {
      final framer = Framer(maxPayload: 1000);
      final big = bytes(3500);
      final frames = framer.split(big);
      expect(frames.length, 4);
      expect(frames.every((f) => f.length <= 1008), isTrue);
      final re = Reassembler();
      Uint8List? out;
      for (final f in frames) {
        out = re.add(f) ?? out;
      }
      expect(out, big);
      expect(framer.split(bytes(10)).length, 1);
      expect(Reassembler().add(framer.split(bytes(10)).single), bytes(10));
      expect(Reassembler().add(framer.split(Uint8List(0)).single), isEmpty);
    });

    test('messages that are interleaved are not mixed, and nonsense is ignored', () {
      final framer = Framer(maxPayload: 100);
      final a = bytes(250), b = Uint8List.fromList(List.filled(250, 7));
      final fa = framer.split(a), fb = framer.split(b);
      final re = Reassembler();
      final done = <Uint8List>[];
      for (final f in [fa[0], fb[0], fa[1], fb[1], fb[2], fa[2]]) {
        final m = re.add(f);
        if (m != null) done.add(m);
      }
      expect(done, [b, a]);
      expect(re.add(Uint8List.fromList([1, 2, 3])), isNull);
      expect(re.add(Uint8List(8)), isNull); // zero frames in the message
    });

    test('a sender that begins many messages and finishes none holds on to a few, not to all of them', () {
      final framer = Framer(maxPayload: 100);
      final re = Reassembler(maxPartial: 3);
      for (var i = 0; i < 1000; i++) {
        expect(re.add(framer.split(bytes(250))[0]), isNull);
      }
      // the last ones begun are still finished; the first ones were given up
      final late = [for (var i = 0; i < 3; i++) framer.split(bytes(250))];
      for (final f in late) {
        re.add(f[0]);
      }
      Uint8List? out;
      for (final f in late.last.skip(1)) {
        out = re.add(f) ?? out;
      }
      expect(out, bytes(250));
    });

    test('a message that claims to be bigger than allowed is ignored', () {
      final framer = Framer(maxPayload: 100);
      final re = Reassembler(maxMessageBytes: 1000);
      expect(re.add(framer.split(bytes(5000))[0]), isNull);
      expect(re.add(framer.split(bytes(5000))[1]), isNull);
      final ok = framer.split(bytes(900));
      Uint8List? out;
      for (final f in ok) {
        out = re.add(f) ?? out;
      }
      expect(out, bytes(900));
    });
  });
}
