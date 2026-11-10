import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_link.dart';

void main() {
  test('every device of a profile makes the same room from the secret; another secret makes another room', () async {
    final s = SyncSecret.create(Random(1));
    expect((await s.roomKeys()).room, (await SyncSecret(Uint8List.fromList(s.bytes)).roomKeys()).room);
    expect((await s.roomKeys()).room, isNot((await SyncSecret.create(Random(2)).roomKeys()).room));
    expect((await s.roomKeys()).room, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('the proof for the server: a signature of its challenge, checked against the key the room is named after', () async {
    final keys = await SyncSecret.create(Random(1)).roomKeys();
    final other = await SyncSecret.create(Random(2)).roomKeys();
    final sig = await keys.answer('abc123');
    expect(await RoomKeys.verify(keys.publicKey, keys.room, 'abc123', sig), isTrue);
    expect(await RoomKeys.verify(keys.publicKey, keys.room, 'another challenge', sig), isFalse);
    expect(await RoomKeys.verify(other.publicKey, keys.room, 'abc123', await other.answer('abc123')), isFalse); // a key that does not name the room
  });

  test('the link carries the server, the name and the secret after the #, and reads back', () {
    final link = SyncLink('wss://sync.example.org', SyncSecret.create(Random(4)), from: 'Anna');
    final text = link.toLink();
    expect(text, startsWith('notation://sync?'));
    expect(text.split('#').first, isNot(contains(link.secret.toText()))); // never in the part a server could see
    final back = SyncLink.parse('Add my device: $text please')!;
    expect([back.server, back.from], ['wss://sync.example.org', 'Anna']);
    expect(back.secret.bytes, link.secret.bytes);
    expect(SyncLink.parse('notation://join?s=wss://x#abc'), isNull);
    expect(SyncLink.parse('notation://sync?s=https://x#abc'), isNull);
  });

  test('the six digits are the same on both devices, and differ for a device in the middle', () async {
    final s = SyncSecret.create(Random(5));
    final a = await DeviceIdentity.create(random: Random(1)), b = await DeviceIdentity.create(random: Random(2)), m = await DeviceIdentity.create(random: Random(3));
    final onA = s.pairingCode(nonceA: 'na', nonceB: 'nb', publicKeyA: a.publicKey, publicKeyB: b.publicKey);
    final onB = s.pairingCode(nonceA: 'nb', nonceB: 'na', publicKeyA: b.publicKey, publicKeyB: a.publicKey);
    expect(onA, onB);
    // A talks to the middle device, which talks to B: they see different keys
    expect(s.pairingCode(nonceA: 'na', nonceB: 'nm', publicKeyA: a.publicKey, publicKeyB: m.publicKey), isNot(onB));
  });

  test('a device signs a meeting; the signature fails for another meeting and for another signer', () async {
    final a = await DeviceIdentity.create(random: Random(1)), b = await DeviceIdentity.create(random: Random(2));
    List<int> meeting(String signer, {String nonceB = 'nb'}) => DeviceIdentity.meeting(room: 'r', signerId: signer, idA: a.id, nonceA: 'na', idB: b.id, nonceB: nonceB);
    final sig = await a.sign(meeting(a.id));
    expect(await DeviceIdentity.verify(a.publicKey, meeting(a.id), sig), isTrue);
    expect(await DeviceIdentity.verify(a.publicKey, meeting(a.id, nonceB: 'other'), sig), isFalse);
    expect(await DeviceIdentity.verify(a.publicKey, meeting(b.id), sig), isFalse); // not reflected back at its maker
    expect(await DeviceIdentity.verify(b.publicKey, meeting(a.id), sig), isFalse);
  });

  test('the list of devices: a removal that is later than the addition counts, a known id keeps its key', () async {
    final store = <String, String>{};
    final book = DeviceBook((k) async => store[k], (k, v) async => store[k] = v);
    final key = Uint8List.fromList(List.filled(32, 1));
    await book.add(PairedDevice(id: 'd1', name: 'One', publicKey: key, addedAt: 10));
    expect(book.find('d1'), isNotNull);
    await book.merge([PairedDevice(id: 'd1', name: 'One', publicKey: key, addedAt: 10, removedAt: 20)]);
    expect(book.find('d1'), isNull);
    await book.merge([PairedDevice(id: 'd1', name: 'One', publicKey: Uint8List.fromList(List.filled(32, 9)), addedAt: 99)]); // another key under the id
    expect(book.find('d1'), isNull);
    await book.merge([PairedDevice(id: 'd1', name: 'One', publicKey: key, addedAt: 30)]); // put back later
    expect(book.find('d1'), isNotNull);

    final again = DeviceBook((k) async => store[k], (k, v) async => store[k] = v);
    await again.load();
    expect(again.find('d1')!.addedAt, 30);
  });

  test('the room changes every day, so the server cannot tell that a profile came back; all devices agree on which day it is', () async {
    final s = SyncSecret.create(Random(1));
    final today = (await s.roomKeys(epoch: 20000)).room, tomorrow = (await s.roomKeys(epoch: 20001)).room;
    expect(today, isNot(tomorrow));
    expect((await s.roomKeys(epoch: 20000)).room, today);
    expect(SyncSecret.epochNow(DateTime.utc(2026, 10, 20, 23, 59)), SyncSecret.epochNow(DateTime.utc(2026, 10, 20, 0, 1)));
    expect(SyncSecret.epochNow(DateTime.utc(2026, 10, 21, 0, 1)), SyncSecret.epochNow(DateTime.utc(2026, 10, 20)) + 1);
    expect(SyncSecret.untilNextEpoch(DateTime.utc(2026, 10, 20, 23, 0)), const Duration(hours: 1));
  });

  test('messages are padded to one size, so their length says nothing of what they are', () {
    final small = padMessage('{"t":"here"}'), medium = padMessage('{"t":"offer","sdp":"${'x' * 2500}"}');
    expect(small.length, 4096);
    expect(medium.length, 4096);
    expect(padMessage('y' * 5000).length, 8192);
    expect(jsonDecode(utf8.decode(small)), {'t': 'here'}); // trailing spaces do not matter to the reader
  });
}
