import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_folder.dart' show CloudFolderException;
import 'package:notes/cloudsync/cloud_sign_in.dart';
import 'package:notes/cloudsync/cloud_sync_service.dart';
import 'package:notes/cloudsync/folder_sync.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/devicesync/device_sync_service.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_keys.dart';
import 'package:notes/devicesync/sync_library.dart';

import '../devicesync/fakes.dart';
import '../devicesync/harness.dart';
import 'memory_cloud_folder.dart';

/// Signing in with the cloud folder and a recovery key (see CloudSignIn): the formats, and the flow of two devices that never meet.
void main() {
  setUpAll(AppDatabase.initFfi);

  group('the recovery key', () {
    test('is made of 25 characters in five groups and read back whatever the case or the separators', () {
      final key = RecoveryKey.create();
      expect(RegExp(r'^([2-9A-HJKMNP-Z]{5}-){4}[2-9A-HJKMNP-Z]{5}$').hasMatch(key.text), isTrue, reason: key.text);
      expect(RecoveryKey.parse(key.text)!.text, key.text);
      expect(RecoveryKey.parse(key.text.toLowerCase().replaceAll('-', ' '))!.text, key.text);
      expect(RecoveryKey.parse('  ${key.text}\n')!.text, key.text);
    });

    test('is refused when it is too short, too long or has characters that are never in a key', () {
      final key = RecoveryKey.create();
      expect(RecoveryKey.parse(''), isNull);
      expect(RecoveryKey.parse(key.text.substring(0, 20)), isNull);
      expect(RecoveryKey.parse('${key.text}A'), isNull);
      expect(RecoveryKey.parse('${key.text.substring(0, 23)}0O'), isNull);
    });

    test('two keys differ, and the same key always makes the same public key', () async {
      final a = RecoveryKey.create(), b = RecoveryKey.create();
      expect(a.text, isNot(b.text));
      expect(await a.verifier(), await RecoveryKey.parse(a.text)!.verifier());
      expect(await a.verifier(), isNot(await b.verifier()));
    });
  });

  group('the bootstrap file', () {
    test('gives the profile back to the key that made it, and to no other', () async {
      final key = RecoveryKey.create();
      final secret = SyncSecret.create();
      final file = await SignInFile.build(key, secret, 'abcdef0123456789', 'Noel');
      final opened = await SignInFile.open(file, key);
      expect(opened.secret.bytes, secret.bytes);
      expect(opened.profileId, 'abcdef0123456789');
      expect(opened.profileName, 'Noel');
      expect(opened.verifier, await key.verifier());
      await expectLater(SignInFile.open(file, RecoveryKey.create()), throwsA(isA<WrongRecoveryKey>()));
    });

    test('does not show the secret to someone who reads the folder', () async {
      final key = RecoveryKey.create();
      final secret = SyncSecret.create();
      final file = await SignInFile.build(key, secret, 'abcdef0123456789', 'Noel');
      final text = String.fromCharCodes(file);
      expect(text.contains(secret.toText()), isFalse);
      expect(text.contains('Noel'), isFalse);
    });

    test('is refused when the service swaps the public key for another one', () async {
      final key = RecoveryKey.create();
      final file = await SignInFile.build(key, SyncSecret.create(), 'abcdef0123456789', 'Noel');
      final other = await RecoveryKey.create().verifier();
      final text = String.fromCharCodes(file);
      final verify = RegExp(r'"verify":"([^"]*)"').firstMatch(text)!.group(1)!;
      final swapped = Uint8List.fromList(text.replaceFirst(verify, base64.encode(other)).codeUnits);
      await expectLater(SignInFile.open(swapped, key), throwsA(isA<WrongRecoveryKey>()));
    });

    test('says so in words when it is not a sign-in file', () async {
      await expectLater(SignInFile.open(Uint8List.fromList([1, 2, 3]), RecoveryKey.create()), throwsA(isA<StateError>()));
    });
  });

  group('an endorsement', () {
    final device = PairedDevice(id: '0011223344556677', name: 'Phone', publicKey: Uint8List.fromList(List.filled(32, 7)), addedAt: 1000);

    test('checks out against the public key of the recovery key that signed it only', () async {
      final key = RecoveryKey.create();
      final e = await Endorsement.make(key, device);
      expect(await e.verify(await key.verifier()), isTrue);
      expect(await e.verify(await RecoveryKey.create().verifier()), isFalse);
      final again = Endorsement.fromBytes(e.toBytes())!;
      expect(await again.verify(await key.verifier()), isTrue);
      expect(again.device.id, device.id);
      expect(again.device.addedAt, 1000);
    });

    test('does not check out when the key, the name or the time was changed', () async {
      final key = RecoveryKey.create();
      final e = await Endorsement.make(key, device);
      final v = await key.verifier();
      expect(await Endorsement(e.id, e.name, Uint8List.fromList(List.filled(32, 9)), e.at, e.signature).verify(v), isFalse);
      expect(await Endorsement(e.id, 'Somebody', e.publicKey, e.at, e.signature).verify(v), isFalse);
      expect(await Endorsement(e.id, e.name, e.publicKey, e.at + 1, e.signature).verify(v), isFalse);
    });
  });

  group('edges of the files', () {
    test('an endorsement with the wrong lengths, and bytes that are none, are refused without an error', () async {
      final key = RecoveryKey.create();
      final v = await key.verifier();
      final device = PairedDevice(id: '0011223344556677', name: 'Phone', publicKey: Uint8List.fromList(List.filled(32, 7)), addedAt: 1000);
      final e = await Endorsement.make(key, device);
      expect(await Endorsement(e.id, e.name, Uint8List(31), e.at, e.signature).verify(v), isFalse);
      expect(await Endorsement(e.id, e.name, e.publicKey, e.at, Uint8List(63)).verify(v), isFalse);
      expect(await e.verify(Uint8List(31)), isFalse);
      for (final junk in [Uint8List(0), Uint8List.fromList([1, 2, 3]), Uint8List.fromList(utf8.encode('{}')), Uint8List.fromList(utf8.encode('[1]')),
        Uint8List.fromList(utf8.encode('{"id":1,"name":"x","key":"","at":1,"sig":""}'))]) {
        expect(Endorsement.fromBytes(junk), isNull);
      }
    });

    test('a name with odd characters is signed as it is', () async {
      final key = RecoveryKey.create();
      for (final name in ['', 'Noel\'s "phone"', 'Tablet | 2', 'Gerät Ü ✓', 'a' * 500]) {
        final d = PairedDevice(id: '0011223344556677', name: name, publicKey: Uint8List.fromList(List.filled(32, 3)), addedAt: 5);
        final e = Endorsement.fromBytes((await Endorsement.make(key, d)).toBytes())!;
        expect(await e.verify(await key.verifier()), isTrue, reason: name);
        expect(e.name, name);
      }
    });

    test('a sign-in file of a newer version, one with a damaged box, and ones that are no JSON are told apart', () async {
      final key = RecoveryKey.create();
      final file = await SignInFile.build(key, SyncSecret.create(), 'abcdef0123456789', 'Noel');
      final text = utf8.decode(file);
      await expectLater(SignInFile.open(Uint8List.fromList(utf8.encode(text.replaceFirst('"v":1', '"v":2'))), key), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('newer version'))));
      final box = RegExp(r'"box":"([^"]*)"').firstMatch(text)!.group(1)!;
      final damaged = '${box.substring(0, box.length - 8)}AAAAAAAA';
      await expectLater(SignInFile.open(Uint8List.fromList(utf8.encode(text.replaceFirst(box, damaged))), key), throwsA(isA<WrongRecoveryKey>()));
      for (final junk in ['', 'null', '[]', '{"v":1}', '{"v":1,"verify":5,"box":"x"}', '{"v":1,"verify":"!!!","box":"x"}']) {
        await expectLater(SignInFile.open(Uint8List.fromList(utf8.encode(junk)), key), throwsA(isA<StateError>()), reason: junk);
      }
    });

    test('the same recovery key makes the same wrap key and nothing else shares it with the signing key', () async {
      final key = RecoveryKey.create();
      expect(key.wrapKey, RecoveryKey.parse(key.text)!.wrapKey);
      expect(key.wrapKey, isNot(await key.verifier()));
      expect(key.wrapKey.length, 32);
    });

    test('where an endorsement is kept depends on the secret, the device and the time', () {
      final a = SyncSecret.create(), b = SyncSecret.create();
      final path = CloudSignIn.endorsementPath(a, 'dev1', 10);
      expect(path, startsWith('_profile/j-'));
      expect(CloudSignIn.endorsementPath(a, 'dev1', 10), path);
      expect(CloudSignIn.endorsementPath(a, 'dev1', 11), isNot(path));
      expect(CloudSignIn.endorsementPath(a, 'dev2', 10), isNot(path));
      expect(CloudSignIn.endorsementPath(b, 'dev1', 10), isNot(path));
      expect(path.contains('dev1'), isFalse, reason: 'the name says nothing');
    });

    test('a recovery key can be told by typing it with look-alike separators, and 100 made keys are all different', () {
      final keys = {for (var i = 0; i < 100; i++) RecoveryKey.create().text};
      expect(keys, hasLength(100));
      final k = RecoveryKey.create();
      expect(RecoveryKey.parse(k.text.replaceAll('-', '_'))!.text, k.text);
      expect(RecoveryKey.parse(k.text.replaceAll('-', '.'))!.text, k.text);
      expect(RecoveryKey.parse(k.text.replaceAll('-', ''))!.text, k.text);
    });
  });

  test('the sign-in file carries the signalling server, and an older file without one still opens', () async {
    final key = RecoveryKey.create();
    final secret = SyncSecret.create();
    final withServer = await SignInFile.open(await SignInFile.build(key, secret, 'abcdef0123456789', 'Noel', server: 'wss://own.example'), key);
    expect(withServer.server, 'wss://own.example');
    final without = await SignInFile.open(await SignInFile.build(key, secret, 'abcdef0123456789', 'Noel'), key);
    expect(without.server, '');
  });

  group('two devices that never meet', () {
    late Directory root;
    late FakeServer server;
    late Device a, b;
    late DeviceSyncService sa, sb;
    late CloudSyncService ca, cb;
    late ValueNotifier<bool> accountA, accountB;
    final folders = <String, MemoryCloudFolder>{};
    MemoryCloudFolder folder(String name) => folders.putIfAbsent(name, MemoryCloudFolder.new);

    DeviceSyncService serviceFor(Device d, void Function() settingsChanged) => DeviceSyncService(
          settings: d.settings,
          keys: MemorySyncKeys(),
          library: d.library,
          profile: d.profile,
          serverOf: () => 'wss://signal.example',
          changes: d.repo.changes,
          onSettingsChanged: settingsChanged,
          openRoom: (srv, secret) async => FakeRoom(server, (await secret.roomKeys()).room),
          makeLinker: (room, me) => FakeLinker(server, (room as FakeRoom).name, me),
        );

    CloudSyncService cloudFor(Device d, DeviceSyncService s, ValueNotifier<bool> account) => CloudSyncService(
          d.settings,
          s,
          [CloudProvider(id: 'memory', label: 'Memory', available: () => account.value, folderFor: folder, changes: account)],
          changes: d.repo.changes,
          afterChange: const Duration(milliseconds: 200),
          retryDelays: const [],
        );

    CloudProvider providerOf(CloudSyncService c) => c.providers.single;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('signin_');
      server = FakeServer();
      folders.clear();
      accountA = ValueNotifier(true);
      accountB = ValueNotifier(false); // (the tablet has no account yet: it is new)
      a = await Device.create('Laptop', root, profileId: 'aaaaaaaaaaaaaaaa');
      b = await Device.create('Tablet', root, profileId: 'bbbbbbbbbbbbbbbb');
      sa = serviceFor(a, () => unawaited(ca.load()));
      sb = serviceFor(b, () => unawaited(cb.load()));
      ca = cloudFor(a, sa, accountA);
      cb = cloudFor(b, sb, accountB);
      sa.cloud = ca;
      sb.cloud = cb;
      await sa.load();
      await sb.load();
      await ca.load();
      await cb.load();
    });

    tearDown(() async {
      ca.dispose();
      cb.dispose();
      sa.dispose();
      sb.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await a.db.close();
      await b.db.close();
      await root.delete(recursive: true);
    });

    Future<RecoveryKey> laptopTurnsItOn() async {
      await ca.setEnabled(true);
      await ca.idle;
      final key = await ca.signIn.enable();
      return key;
    }

    test('a new device signs in with the key and gets the notes, the profile and the list of devices', () async {
      final id = await a.note('From the laptop', 'hello');
      final key = await laptopTurnsItOn();
      await ca.syncNow();
      await ca.idle;
      expect(ca.problem, isNull);

      accountB.value = true;
      expect(sb.isSetUp, isFalse);
      await cb.signInWith(providerOf(cb), 'Notation Sync', key.text);
      await cb.idle;

      expect(sb.isSetUp, isTrue);
      expect(sb.profileSecret!.bytes, sa.profileSecret!.bytes);
      expect(b.profile.id, 'aaaaaaaaaaaaaaaa');
      expect(b.profile.name, 'Laptop');
      expect(sb.book.find(sa.deviceId!), isNotNull);
      expect(sb.book.find(sb.deviceId!), isNotNull);
      expect(cb.enabled, isTrue);
      expect(cb.providerId, 'memory');
      expect(cb.signIn.enabled, isTrue);
      expect(cb.problem, isNull);
      expect(await b.text(id), 'hello');
    });

    test('the new device meets the others on the signalling server of the profile, which the sign-in file carries', () async {
      final key = await laptopTurnsItOn();
      accountB.value = true;
      expect(sb.server, isNull, reason: 'it was never linked, so it has no server of its own');
      await cb.signInWith(providerOf(cb), 'Notation Sync', key.text);
      await cb.idle;
      expect(sb.server, 'wss://signal.example');
      expect(sb.signalServer, 'wss://signal.example');
    });

    test('the laptop sees the tablet come, lists it as signed in with the key, and then takes in its notes', () async {
      final key = await laptopTurnsItOn();
      accountB.value = true;
      await cb.signInWith(providerOf(cb), 'Notation Sync', key.text);
      await cb.idle;
      final fromTablet = await b.note('From the tablet', 'written there');
      await cb.syncNow();
      await cb.idle;

      expect(sa.book.find(sb.deviceId!), isNull, reason: 'not before the laptop looked');
      await ca.syncNow();
      await ca.idle;
      expect(sa.book.find(sb.deviceId!), isNotNull);
      expect(ca.signIn.signedIn.keys, contains(sb.deviceId));
      expect(sa.peers.map((p) => p.id), contains(sb.deviceId));
      expect(await a.text(fromTablet), 'written there');
    });

    test('a wrong key changes nothing on the new device', () async {
      await laptopTurnsItOn();
      accountB.value = true;
      await expectLater(cb.signInWith(providerOf(cb), 'Notation Sync', RecoveryKey.create().text), throwsA(isA<WrongRecoveryKey>()));
      expect(sb.isSetUp, isFalse);
      expect(cb.enabled, isFalse);
      expect(b.profile.id, 'bbbbbbbbbbbbbbbb');
    });

    test('a key that is not one, or a folder with nothing to sign in to, is told in words', () async {
      accountB.value = true;
      await expectLater(cb.signInWith(providerOf(cb), 'Notation Sync', 'nonsense'), throwsA(isA<StateError>()));
      await expectLater(cb.signInWith(providerOf(cb), 'Empty', RecoveryKey.create().text), throwsA(isA<StateError>()));
      expect(sb.isSetUp, isFalse);
    });

    test('a device that was taken out cannot put itself back with the secret alone', () async {
      final key = await laptopTurnsItOn();
      accountB.value = true;
      await cb.signInWith(providerOf(cb), 'Notation Sync', key.text);
      await cb.idle;
      await ca.syncNow();
      await ca.idle;
      final tablet = sb.deviceId!;
      await sa.removeDevice(tablet);
      expect(sa.book.find(tablet), isNull);

      // the tablet still knows the secret: it writes an endorsement of itself, signed with a key of its own (it has not got the recovery key)
      final impostor = RecoveryKey.create();
      final self = PairedDevice(id: tablet, name: 'Tablet', publicKey: sb.identity!.publicKey, addedAt: DateTime.now().millisecondsSinceEpoch + 10000);
      final forged = await Endorsement.make(impostor, self);
      final path = CloudSignIn.endorsementPath(sb.profileSecret!, tablet, forged.at);
      await folder('Notation Sync').write(path, await sealApart(sb.profileSecret!.cloudKey, forged.toBytes(), aad: CloudSignIn.placeOf(path)));
      await ca.syncNow();
      await ca.idle;
      expect(sa.book.find(tablet), isNull, reason: 'the removal stands: the endorsement is not signed with the recovery key');
    });

    test('a device that signs in again after it was taken out is let back in', () async {
      final key = await laptopTurnsItOn();
      accountB.value = true;
      await cb.signInWith(providerOf(cb), 'Notation Sync', key.text);
      await cb.idle;
      await ca.syncNow();
      await ca.idle;
      final tablet = sb.deviceId!;
      await sa.removeDevice(tablet);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sb.leave();
      await cb.signIn.load();
      await cb.signInWith(providerOf(cb), 'Notation Sync', key.text);
      await cb.idle;
      await ca.syncNow();
      await ca.idle;
      // (leaving makes the device a new one, with a new id and key: it comes back as that, and the old entry stays taken out)
      expect(sb.deviceId, isNot(tablet));
      expect(sa.book.find(sb.deviceId!), isNotNull);
      expect(sa.book.find(tablet), isNull);
    });

    test('a third device that signs in after another was taken out ends up with the right list of devices', () async {
      final key = await laptopTurnsItOn();
      accountB.value = true;
      await cb.signInWith(providerOf(cb), 'Notation Sync', key.text);
      await cb.idle;
      await ca.syncNow();
      await ca.idle;
      await sa.removeDevice(sb.deviceId!);
      await ca.syncNow(); // (the laptop publishes its list, with the removal in it)
      await ca.idle;

      // the endorsement of the tablet is still in the folder; a third device that signs in now must not take it for a device that is in
      final c = await Device.create('Phone', root, profileId: 'cccccccccccccccc');
      final sc = serviceFor(c, () {});
      final cc = cloudFor(c, sc, ValueNotifier(true));
      sc.cloud = cc;
      await sc.load();
      await cc.load();
      await cc.signInWith(providerOf(cc), 'Notation Sync', key.text);
      await cc.idle;
      expect(sc.book.find(sa.deviceId!), isNotNull);
      expect(sc.book.find(sb.deviceId!), isNull);
      expect(sc.peers.map((p) => p.id), isNot(contains(sb.deviceId)));
      cc.dispose();
      sc.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.db.close();
    });

    test('before it reads anyone else, a device that signed in learns from the others\' lists who was taken out', () async {
      final key = await laptopTurnsItOn();
      accountB.value = true;
      await cb.signInWith(providerOf(cb), 'Notation Sync', key.text);
      await cb.idle;
      await ca.syncNow();
      await ca.idle;
      await sa.removeDevice(sb.deviceId!);
      await ca.syncNow();
      await ca.idle;

      // a third device, at the moment it has the endorsements and nothing else
      final c = await Device.create('Phone', root, profileId: 'cccccccccccccccc');
      final sc = serviceFor(c, () {});
      await sc.load();
      final me = await sc.joinWithSecret(sa.profileSecret!, 'aaaaaaaaaaaaaaaa', 'Laptop');
      await sc.book.merge([sa.book.find(sa.deviceId!)!, sb.book.find(sb.deviceId!)!]);
      expect(sc.book.find(sb.deviceId!), isNotNull, reason: 'the endorsement of the tablet is still in the folder');

      final sync = FolderSync(
        folder: folder('Notation Sync'),
        library: c.library,
        book: sc.book,
        settings: c.settings,
        deviceId: me.id,
        deviceName: 'Phone',
        key: sa.profileSecret!.cloudKey,
        encrypted: true,
      );
      await CloudSignIn.learnRemovals(sync, sc.book);
      expect(sc.book.find(sa.deviceId!), isNotNull);
      expect(sc.book.find(sb.deviceId!), isNull, reason: 'the laptop\'s list says it was taken out');
      sc.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.db.close();
    });

    test('a new key stops the old one, and a device signed in with the new one comes in', () async {
      final old = await laptopTurnsItOn();
      final fresh = await ca.signIn.regenerate();
      expect(fresh.text, isNot(old.text));
      accountB.value = true;
      await expectLater(cb.signInWith(providerOf(cb), 'Notation Sync', old.text), throwsA(isA<WrongRecoveryKey>()));
      await cb.signInWith(providerOf(cb), 'Notation Sync', fresh.text);
      await cb.idle;
      await ca.syncNow();
      await ca.idle;
      expect(sa.book.find(sb.deviceId!), isNotNull);
    });

    test('turning it off takes the files out of the folder and the other devices stop looking', () async {
      final key = await laptopTurnsItOn();
      final f = folder('Notation Sync');
      expect(f.files.keys.where((k) => k.startsWith('_profile/')).length, greaterThanOrEqualTo(2));
      await ca.signIn.disable();
      expect(f.files.keys.where((k) => k.startsWith('_profile/')), isEmpty);
      expect(ca.signIn.enabled, isFalse);
      accountB.value = true;
      await expectLater(cb.signInWith(providerOf(cb), 'Notation Sync', key.text), throwsA(isA<StateError>()));
    });

    test('turning it off with no account connected here fails and leaves it on (the recovery key would still open the folder)', () async {
      final key = await laptopTurnsItOn();
      final f = folder('Notation Sync');
      final before = f.files.keys.where((k) => k.startsWith('_profile/')).toSet();
      accountA.value = false;
      await expectLater(ca.signIn.disable(), throwsA(isA<StateError>()));
      expect(ca.signIn.enabled, isTrue, reason: 'it did not take the files out, so it must not say it is off');
      expect(f.files.keys.where((k) => k.startsWith('_profile/')).toSet(), before);
      expect(await a.settings.get(CloudSignIn.kVerifier), isNotEmpty);

      // the account comes back: it can be turned off after all, and then the old key is of no use
      accountA.value = true;
      await ca.signIn.disable();
      expect(ca.signIn.enabled, isFalse);
      expect(f.files.keys.where((k) => k.startsWith('_profile/')), isEmpty);
      accountB.value = true;
      await expectLater(cb.signInWith(providerOf(cb), 'Notation Sync', key.text), throwsA(isA<StateError>()));
    });

    test('turning it off when the folder fails half way leaves it on, and doing it again finishes the job', () async {
      await laptopTurnsItOn();
      final f = folder('Notation Sync');
      f.failDeletePrefix = '_profile/j-';
      await expectLater(ca.signIn.disable(), throwsA(isA<CloudFolderException>()));
      expect(ca.signIn.enabled, isTrue);
      expect(f.files.containsKey(CloudSignIn.bootstrapPath), isFalse, reason: 'the file with the secret went first');
      f.failDeletePrefix = null;
      await ca.signIn.disable();
      expect(ca.signIn.enabled, isFalse);
      expect(f.files.keys.where((k) => k.startsWith('_profile/')), isEmpty);
    });

    test('what turns it on is a setting of the profile, so it reaches the other devices with the rest', () async {
      await laptopTurnsItOn();
      expect(syncedSetting(CloudSignIn.kVerifier), isTrue);
      expect(await a.settings.get(CloudSignIn.kVerifier), isNotEmpty);
    });
  });
}

