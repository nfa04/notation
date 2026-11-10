import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/shared_notes.dart' show SharedKind;
import 'package:notes/data/app_database.dart';
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/native_share_service.dart';
import 'package:notes/nativeshare/share_model.dart';
import 'package:notes/nativeshare/shared_folder_sync.dart';

import '../devicesync/harness.dart';
import 'fake_share_provider.dart';

class _Unsupported extends FakeShareProvider {
  _Unsupported(super.hub, super.user);
  @override
  String? get unsupportedReason => 'This account cannot share with people.';
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late Device aliceDev, bobDev;
  late FakeShareHub hub;
  late NativeShareService alice, bob;

  NativeShareService serviceOf(Device d, String user, {NativeShareProvider? provider}) => NativeShareService(
        db: d.db,
        settings: d.settings,
        library: d.library,
        providers: [provider ?? hub.as(user)],
        deviceId: () => d.identity.id,
        deviceName: () => d.name,
        identity: () => d.identity,
        every: const Duration(hours: 1),
        afterChange: const Duration(hours: 1),
        lookEvery: Duration.zero,
        retryDelays: const [],
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nativeshare_service_');
    aliceDev = await Device.create('alice-laptop', root);
    bobDev = await Device.create('bob-laptop', root);
    hub = FakeShareHub();
    alice = serviceOf(aliceDev, 'alice');
    bob = serviceOf(bobDev, 'bob');
    await alice.load();
    await bob.load();
  });
  tearDown(() async {
    alice.dispose();
    bob.dispose();
    await aliceDev.db.close();
    await bobDev.db.close();
    await root.delete(recursive: true);
  });

  const bobP = SharePerson('bob', 'Bob');

  Future<Set<String>> noteIds(Device d) async => {for (final n in await d.repo.listNotes()) n.id};

  test('a note is shared, found by the other person, taken in, and kept in step both ways', () async {
    final id = await aliceDev.note('Optics', 'light is a wave');
    final share = await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    expect(share.outgoing && share.recipients.single.person.id == 'bob', isTrue);
    expect(share.place, startsWith('Notation Shares/Optics (Notation '));
    expect(alice.isShared(ShareKind.note, id), isTrue);
    // the descriptor and the note are up there before anyone is told
    expect(ShareDescriptor.decode(hub.folderOf('alice', share.place).files['share.json'])?.rootId, id);

    expect(bob.pending, isEmpty);
    await bob.refreshIncoming();
    expect(bob.pending.single.share.owner, 'Alice');
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);
    expect(bob.statusOf(inn.id).problem, isNull);
    expect(await bobDev.text(id), 'light is a wave');
    expect(bob.pending, isEmpty);
    expect(bob.isShared(ShareKind.note, id), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await bobDev.edit(id, 'light is a wave and a particle');
    await bob.syncNow();
    await alice.syncNow();
    expect(await aliceDev.text(id), 'light is a wave and a particle');
  });

  test('a folder, shared with two people who have different rights, and the rights changed later', () async {
    final f = await aliceDev.repo.createFolder('Physics');
    final n1 = await aliceDev.note('Waves', 'w');
    await aliceDev.repo.moveNote(n1, f);
    final share = await alice.shareFolder(f, alice.usable.single, bobP, ShareRole.viewer);
    final again = await alice.shareFolder(f, alice.usable.single, const SharePerson('carol', 'Carol'), ShareRole.editor);
    expect(again.id, share.id, reason: 'one share, two people');
    expect(alice.given.single.recipients.map((r) => (r.person.id, r.role)), [('bob', ShareRole.viewer), ('carol', ShareRole.editor)]);

    await bob.refreshIncoming();
    expect(bob.pending.single.share.role, ShareRole.viewer);

    final r = alice.given.single.recipients.firstWhere((x) => x.person.id == 'bob');
    await alice.changeRole(alice.given.single, r, ShareRole.editor);
    expect((await hub.as('alice').sharesOf(share.place)).firstWhere((s) => s.person.id == 'bob').role, ShareRole.editor);
    expect(alice.given.single.recipients.firstWhere((x) => x.person.id == 'bob').role, ShareRole.editor);

    await alice.removePerson(alice.given.single, alice.given.single.recipients.firstWhere((x) => x.person.id == 'carol'));
    expect((await hub.as('alice').sharesOf(share.place)).map((s) => s.person.id), ['bob']);
  });

  test('stopping a share removes it at the service, ends it for the other person, and leaves their notes', () async {
    final id = await aliceDev.note('Optics', 'x');
    final share = await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    await bob.refreshIncoming();
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);

    await alice.stopSharing(share);
    expect(alice.shares, isEmpty);
    expect(hub.folders.containsKey('alice/${share.place}'), isFalse);
    expect(alice.isShared(ShareKind.note, id), isFalse);
    expect(await aliceDev.text(id), 'x');

    await bob.refreshIncoming();
    expect(bob.received.single.state, ShareState.ended);
    expect(await bobDev.text(id), 'x');
    await bob.remove(bob.received.single);
    expect(bob.shares, isEmpty);
  });

  test('leaving a share removes it at the service and keeps the notes', () async {
    final id = await aliceDev.note('Optics', 'x');
    await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    await bob.refreshIncoming();
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);
    await bob.leave(inn);
    expect(bob.shares, isEmpty);
    expect(await hub.as('bob').incoming(), isEmpty);
    expect(await noteIds(bobDev), {id});
  });

  test('a share that has to be accepted at the service is accepted when it is taken in', () async {
    hub.needsAccepting = true;
    final id = await aliceDev.note('Optics', 'x');
    await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    await bob.refreshIncoming();
    expect(bob.pending.single.share.pending, isTrue);
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);
    expect(await bobDev.text(id), 'x');
  });

  test('they are kept for the next start', () async {
    final id = await aliceDev.note('Optics', 'x');
    final share = await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    final again = serviceOf(aliceDev, 'alice');
    await again.load();
    expect(again.given.single.id, share.id);
    expect(again.given.single.recipients.single.person.label, 'Bob');
    expect(again.given.single.place, share.place);
    again.dispose();
  });

  group('what is refused', () {
    test('a service that cannot share with people for this account is said, not hidden, and cannot be used', () async {
      final id = await aliceDev.note('Optics', 'x');
      final odd = serviceOf(aliceDev, 'alice', provider: _Unsupported(hub, 'alice'));
      expect(odd.usable, isEmpty);
      expect(odd.unsupported.single.reason, contains('cannot share'));
      await expectLater(odd.shareNote(id, odd.providers.single, bobP, ShareRole.viewer), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('cannot share'))));
      odd.dispose();
    });

    test('nothing is left behind when the service says no', () async {
      final id = await aliceDev.note('Optics', 'x');
      await expectLater(alice.shareNote(id, alice.usable.single, const SharePerson('nobody', 'Nobody'), ShareRole.viewer), throwsA(isA<NativeShareException>()));
      expect(alice.shares, isEmpty);
      expect(hub.folders.keys.where((k) => k.startsWith('alice/')), isEmpty);
      expect(await aliceDev.db.query('native_shares'), isEmpty);
    });

    test('a share that is not from Notation is not offered, and one without a descriptor is not taken', () async {
      await hub.as('carol').share('Holiday photos', const SharePerson('bob', 'Bob'), ShareRole.viewer); // an ordinary shared folder
      await bob.refreshIncoming();
      expect(bob.pending, isEmpty);
      // a folder with the name of ours but no descriptor
      await hub.as('carol').share('Evil (Notation abcdef)', const SharePerson('bob', 'Bob'), ShareRole.editor);
      await bob.refreshIncoming();
      expect(bob.pending, hasLength(1));
      await expectLater(bob.accept(bob.pending.single), throwsA(isA<NativeShareException>()));
      expect(bob.shares, isEmpty);
    });

    test('a person who left and is invited again takes it in again, with what they have; from someone else it is refused', () async {
      final id = await aliceDev.note('Optics', 'v1');
      await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
      await bob.refreshIncoming();
      final first = await bob.accept(bob.pending.single);
      await bob.syncShare(first.id);
      await bob.leave(first);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await aliceDev.edit(id, 'v2');

      await alice.addPerson(alice.given.single, bobP, ShareRole.editor);
      await alice.syncNow();
      await bob.refreshIncoming();
      final again = await bob.accept(bob.pending.single);
      await bob.syncShare(again.id);
      expect(bob.statusOf(again.id).problem, isNull);
      expect(await bobDev.text(id), 'v2', reason: 'it takes part again');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await bobDev.edit(id, 'v3 by bob');
      await bob.syncNow();
      await alice.syncNow();
      expect(await aliceDev.text(id), 'v3 by bob');

      // the same note id offered by somebody else is not the same share
      await bob.leave(bob.received.single);
      const place = 'Fake (Notation aaaaaa)';
      await hub.as('carol').share(place, bobP, ShareRole.editor);
      hub.folderOf('carol', place).files['share.json'] = ShareDescriptor(ShareKind.note, id, 'Optics').encode();
      await bob.refreshIncoming();
      final fromCarol = bob.pending.where((p) => p.share.owner == 'Carol').single;
      await expectLater(bob.accept(fromCarol), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('not from this share'))));
    });

    test('a share whose note or folder id is one the person has already is not taken in (it would publish their note)', () async {
      final mine = await bobDev.note('Bob private', 'secret');
      const place = 'Evil (Notation abcdef)';
      await hub.as('carol').share(place, const SharePerson('bob', 'Bob'), ShareRole.editor);
      hub.folderOf('carol', place).files['share.json'] = ShareDescriptor(ShareKind.note, mine, 'Evil').encode();
      await bob.refreshIncoming();
      await expectLater(bob.accept(bob.pending.single), throwsA(isA<NativeShareException>().having((e) => e.message, 'm', contains('already'))));
      expect(bob.shares, isEmpty);
      expect(hub.folderOf('carol', place).files.keys.where((k) => k.contains(bobDev.identity.id)), isEmpty);
    });

    test('without a sync profile (no device id) nothing is shared', () async {
      final id = await aliceDev.note('Optics', 'x');
      final bare = NativeShareService(
          db: aliceDev.db, settings: aliceDev.settings, library: aliceDev.library, providers: [hub.as('alice')], deviceId: () => null, deviceName: () => 'x');
      await expectLater(bare.shareNote(id, bare.providers.single, bobP, ShareRole.viewer), throwsA(isA<NativeShareException>()));
      bare.dispose();
    });
  });

  test('taking a share in tells whoever listens (the automations)', () async {
    final id = await aliceDev.note('Optics', 'x');
    await alice.shareNote(id, alice.usable.single, bobP, ShareRole.viewer);
    final heard = <NativeShare>[];
    bob.onReceived = heard.add;
    await bob.refreshIncoming();
    await bob.accept(bob.pending.single);
    expect(heard.single.name, 'Optics');
    expect(heard.single.owner, 'Alice');
  });

  test('the notes and folders that take part in a share are marked, in the direction they go', () async {
    final f = await aliceDev.repo.createFolder('Physics');
    final g = await aliceDev.repo.createFolder('Optics', parentId: f);
    final n1 = await aliceDev.note('Waves', 'w');
    await aliceDev.repo.moveNote(n1, g);
    final other = await aliceDev.note('Diary', 'private');
    expect(alice.noteKind(n1), SharedKind.none);
    await alice.shareFolder(f, alice.usable.single, bobP, ShareRole.editor);
    expect((alice.folderKind(f), alice.folderKind(g), alice.noteKind(n1), alice.noteKind(other)), (SharedKind.byMe, SharedKind.byMe, SharedKind.byMe, SharedKind.none));
    var told = 0;
    bob.addListener(() => told++);
    await bob.refreshIncoming();
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);
    expect((bob.folderKind(f), bob.folderKind(g), bob.noteKind(n1), bob.noteFrom(n1)), (SharedKind.withMe, SharedKind.withMe, SharedKind.withMe, 'Alice'));
    expect(told, greaterThan(0));
    // and it is gone with the share
    await bob.leave(bob.received.single);
    expect((bob.folderKind(f), bob.noteKind(n1)), (SharedKind.none, SharedKind.none));
  });

  test('opening a note looks for a newer copy in its share, and takes it in when the person has not started changing it', () async {
    final id = await aliceDev.note('Optics', 'v1');
    await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    await bob.refreshIncoming();
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);
    expect(await bob.refreshNote(id), isFalse, reason: 'nothing newer');
    expect(await bob.refreshNote('not-in-a-share'), isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await aliceDev.edit(id, 'v2');
    await alice.syncNow();
    expect(await bob.refreshNote(id, allow: () => false), isFalse, reason: 'the person started to change it');
    expect(await bobDev.text(id), 'v1');
    expect(await bob.refreshNote(id), isTrue);
    expect(await bobDev.text(id), 'v2');
  });

  test('a share made before there was live editing gets its secret: the owner makes it, the other person reads it from the folder', () async {
    final id = await aliceDev.note('Optics', 'x');
    final share = await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    // as an older version left it: no secret in the share, none in the descriptor
    final old = NativeShare(
        id: share.id, providerId: share.providerId, direction: share.direction, kind: share.kind, rootId: share.rootId, name: share.name, place: share.place, recipients: share.recipients, createdAt: share.createdAt);
    await aliceDev.db.update('native_shares', {'data': jsonEncode(old.dataJson())}, where: 'id = ?', whereArgs: [share.id]);
    hub.folderOf('alice', share.place).files['share.json'] = ShareDescriptor(ShareKind.note, id, 'Optics').encode();
    await aliceDev.settings.remove('native_shares'); // (the copy that travels to the other devices knows it too)
    final again = serviceOf(aliceDev, 'alice');
    await again.load();
    expect(again.given.single.liveSecret, isNull);
    await again.syncShare(share.id);
    final secret = again.given.single.liveSecret;
    expect(secret, isNotNull);
    expect(ShareDescriptor.decode(hub.folderOf('alice', share.place).files['share.json'])?.live, secret, reason: 'put in the folder for the others');
    again.dispose();

    await bob.refreshIncoming();
    final inn = await bob.accept(bob.pending.single);
    expect(bob.received.single.liveSecret, secret);
    expect(inn.liveSecret, secret);
  });

  test('every person who may write says in the folder who they are and with what key; one who may only view does not', () async {
    final id = await aliceDev.note('Optics', 'x');
    final share = await alice.shareNote(id, alice.usable.single, bobP, ShareRole.viewer);
    await bob.refreshIncoming();
    final inn = await bob.accept(bob.pending.single);
    await bob.syncShare(inn.id);
    final files = hub.folderOf('alice', share.place).files.keys.where((k) => k.startsWith('p/')).toList();
    expect(files, ['p/${aliceDev.identity.id}']);
    final record = jsonDecode(utf8.decode(hub.folderOf('alice', share.place).files[files.single]!)) as Map;
    expect(base64.decode(record['k'] as String), aliceDev.identity.publicKey);
  });

  test('coming back to the front syncs the shares when the last run was a while ago, and not when it was just now', () async {
    final id = await aliceDev.note('Optics', 'x');
    await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    await alice.syncNow();
    await alice.idle;
    final runs = hub.folderOf('alice', alice.given.single.place).calls;
    alice.wake();
    await alice.idle;
    expect(hub.folderOf('alice', alice.given.single.place).calls, runs, reason: 'it ran a moment ago');
    // the last run was long ago
    final old = alice.given.single.copyWith(lastSync: DateTime.now().subtract(const Duration(minutes: 10)).millisecondsSinceEpoch);
    await aliceDev.db.update('native_shares', {'data': jsonEncode(old.dataJson())}, where: 'id = ?', whereArgs: [old.id]);
    final fresh = serviceOf(aliceDev, 'alice');
    await fresh.load();
    fresh.wake();
    await fresh.idle;
    expect(hub.folderOf('alice', old.place).calls, greaterThan(runs));
    fresh.dispose();
  });

  test('a service that is down is a problem to show, not a crash', () async {
    final id = await aliceDev.note('Optics', 'x');
    final share = await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
    hub.down = true;
    await alice.syncNow();
    expect(alice.statusOf(share.id).problem, isNotNull);
    hub.down = false;
    await alice.syncNow();
    expect(alice.statusOf(share.id).problem, isNull);
  });

  group('the devices of one person', () {
    late Device alice2Dev, bob2Dev;
    late NativeShareService alice2, bob2;

    setUp(() async {
      alice2Dev = await Device.create('alice-tablet', root);
      bob2Dev = await Device.create('bob-tablet', root);
      alice2 = serviceOf(alice2Dev, 'alice');
      bob2 = serviceOf(bob2Dev, 'bob');
      await alice2.load();
      await bob2.load();
    });
    tearDown(() async {
      alice2.dispose();
      bob2.dispose();
      await alice2Dev.db.close();
      await bob2Dev.db.close();
    });

    /// What the sync of the profile does with the setting: the newer one is taken, and the service reads it again.
    Future<void> carry(Device from, Device to, NativeShareService toService) async {
      final text = await from.settings.get('native_shares');
      if (text != null) await to.settings.setFromSync('native_shares', text, DateTime.now().millisecondsSinceEpoch + 1000);
      await toService.load();
    }

    /// The note, as the sync of the profile would have put it on the other device.
    Future<void> copyNote(Device from, Device to, String id) async {
      await to.files.importBytes((await from.library.noteBytes(id))!, id: id);
    }

    test('a share given on one device is known on the other, which takes part in it too', () async {
      final id = await aliceDev.note('Optics', 'v1');
      final share = await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
      await copyNote(aliceDev, alice2Dev, id);
      expect(alice2.shares, isEmpty);
      await carry(aliceDev, alice2Dev, alice2);
      expect(alice2.given.single.id, share.id);
      expect(alice2.given.single.recipients.single.person.id, 'bob');
      expect(alice2.noteKind(id), SharedKind.byMe);

      await bob.refreshIncoming();
      final inn = await bob.accept(bob.pending.single);
      await bob.syncShare(inn.id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await alice2Dev.edit(id, 'v2 from the tablet');
      await alice2.syncNow();
      expect(alice2.statusOf(share.id).problem, isNull);
      await bob.syncNow();
      expect(await bobDev.text(id), 'v2 from the tablet');
    });

    test('a share taken in on one device is known on the other without being taken in again', () async {
      final id = await aliceDev.note('Optics', 'v1');
      await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
      await bob.refreshIncoming();
      final inn = await bob.accept(bob.pending.single);
      await bob.syncShare(inn.id);
      await copyNote(bobDev, bob2Dev, id);
      await carry(bobDev, bob2Dev, bob2);
      expect(bob2.received.single.id, inn.id, reason: 'one id for a share on every device');
      await bob2.refreshIncoming();
      expect(bob2.pending, isEmpty, reason: 'it is in the list already');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await aliceDev.edit(id, 'v2');
      await alice.syncNow();
      await bob2.syncNow();
      expect(bob2.statusOf(inn.id).problem, isNull);
      expect(await bob2Dev.text(id), 'v2');
    });

    test('leaving or stopping on one device ends it on the other, and the notes stay', () async {
      final id = await aliceDev.note('Optics', 'v1');
      await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
      await bob.refreshIncoming();
      final inn = await bob.accept(bob.pending.single);
      await bob.syncShare(inn.id);
      await copyNote(bobDev, bob2Dev, id);
      await carry(bobDev, bob2Dev, bob2);
      expect(bob2.received, hasLength(1));
      await bob.leave(bob.received.single);
      await carry(bobDev, bob2Dev, bob2);
      expect(bob2.shares, isEmpty);
      expect(await bob2Dev.text(id), 'v1');
      expect(bob2.noteKind(id), SharedKind.none);
    });

    test('a share made on one device while the other made another are both kept', () async {
      final a = await aliceDev.note('One', '1');
      final b = await alice2Dev.note('Two', '2');
      final s1 = await alice.shareNote(a, alice.usable.single, bobP, ShareRole.viewer);
      final s2 = await alice2.shareNote(b, alice2.usable.single, bobP, ShareRole.viewer);
      await carry(aliceDev, alice2Dev, alice2); // (the first one is overwritten by the other's setting)
      expect({for (final s in alice2.given) s.id}, {s1.id, s2.id});
      await carry(alice2Dev, aliceDev, alice);
      expect({for (final s in alice.given) s.id}, {s1.id, s2.id});
    });

    test('a share that is made again after it was ended is not ended by the old note of it', () async {
      final id = await aliceDev.note('Optics', 'v1');
      await alice.shareNote(id, alice.usable.single, bobP, ShareRole.editor);
      await bob.refreshIncoming();
      var inn = await bob.accept(bob.pending.single);
      await bob.leave(inn);
      await carry(bobDev, bob2Dev, bob2);
      await alice.addPerson(alice.given.single, bobP, ShareRole.editor);
      await alice.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await bob.refreshIncoming();
      inn = await bob.accept(bob.pending.single);
      await carry(bobDev, bob2Dev, bob2);
      expect(bob2.received.single.id, inn.id, reason: 'same id as before, newer than the note of its end');
    });
  });
}
